package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"

	xterm "github.com/charmbracelet/x/term"

	"serpx/installer/internal/app"
	"serpx/installer/internal/config"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/preflight"
	"serpx/installer/internal/resolve"
	irun "serpx/installer/internal/run"
	"serpx/installer/internal/tui"
	"serpx/installer/internal/xlog"
)

// runCtx is what a sub-command needs.
type runCtx struct {
	o      *options
	rest   []string
	mode   string
	set    *manifest.Set
	cat    *i18n.Catalog
	lang   string
	t      func(string, ...string) string
	stdout io.Writer
	stderr io.Writer
	getenv func(string) string
	log    *xlog.Logger
}

// Seams for tests: nothing here runs in the real system during `go test`.
var (
	// testConfig lets tests replace the system-facing parts of the service.
	testConfig func(*app.Config)
	// stdin is the answer source of the line-by-line mode.
	stdin io.Reader = os.Stdin
	// isTTY says whether a stream is a terminal.
	isTTY = func(v any) bool {
		f, ok := v.(*os.File)
		return ok && xterm.IsTerminal(f.Fd())
	}
	// finishHook performs the final action (reboot / start Hyprland).
	finishHook = realFinish
)

func (c *runCtx) service(mode string) (*app.Service, error) {
	cfg := app.Config{Home: c.getenv("HOME"), Getenv: c.getenv, Version: version, Commit: commit,
		Payload: c.o.payload, Lang: c.lang, Glyphs: c.o.glyphs}
	cfg.Exe, _ = os.Executable()
	cfg.Cwd, _ = os.Getwd()
	// repair / uninstall do not need the network to be healthy
	cfg.SkipNet = mode == "repair" || mode == "uninstall" || mode == "reconcile"
	if testConfig != nil {
		testConfig(&cfg)
	}
	return app.New(cfg)
}

// pickModules turns --preset/--modules into an explicit list.
func (c *runCtx) pickModules(tags []string) ([]string, int) {
	o := c.o
	r := resolve.New(c.set)
	var explicit []string
	preset := o.preset
	if c.mode == "modules" && !o.presetSet {
		// "modules" without --preset means exactly the listed modules
		preset = resolve.PresetCustom
	}
	switch preset {
	case resolve.PresetCustom:
		explicit = resolve.ParseList(o.modules)
		if len(explicit) == 0 {
			fmt.Fprintln(c.stderr, c.t("err.need_modules"))
			return nil, exitUsage
		}
	case resolve.PresetFull, resolve.PresetMinimal:
		var err error
		explicit, err = r.Preset(o.preset, resolve.Detect{Tags: tags})
		if err != nil {
			fmt.Fprintln(c.stderr, err)
			return nil, exitUsage
		}
		explicit = append(explicit, resolve.ParseList(o.modules)...)
	default:
		fmt.Fprintln(c.stderr, c.t("err.unknown_preset", "name", o.preset))
		return nil, exitUsage
	}
	if _, err := r.Resolve(explicit); err != nil {
		var ue *resolve.UnknownError
		var ce *resolve.ConflictError
		switch {
		case errors.As(err, &ue):
			fmt.Fprintln(c.stderr, c.t("err.unknown_module", "id", ue.ID))
		case errors.As(err, &ce):
			fmt.Fprintln(c.stderr, c.t("err.conflict", "a", ce.A, "b", ce.B))
		default:
			fmt.Fprintln(c.stderr, err)
		}
		return nil, exitUsage
	}
	return explicit, exitOK
}

func (c *runCtx) interactive() bool {
	if c.o.plain || c.o.yes || c.o.config != "" || c.mode == "reconcile" {
		return false
	}
	if t := c.getenv("TERM"); t == "" || t == "dumb" {
		return false
	}
	return isTTY(c.stdout) && isTTY(stdin)
}

func cmdRun(c *runCtx) int {
	svc, err := c.service(c.mode)
	if err != nil {
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	needInstalled := c.mode == "repair" || c.mode == "modules" || c.mode == "uninstall" || c.mode == "reconcile"
	if needInstalled && svc.Installed() == nil {
		fmt.Fprintln(c.stderr, c.t("err.not_installed"))
		return exitFailure
	}
	if _, err := svc.Payload(); err != nil && c.mode != "uninstall" {
		fmt.Fprintln(c.stderr, c.t("err.payload", "error", err.Error()))
		return exitFailure
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if c.interactive() {
		return runInteractive(ctx, c, svc)
	}
	return runUnattended(ctx, c, svc)
}

// ---- line by line ----

func runUnattended(ctx context.Context, c *runCtx, svc *app.Service) int {
	o := c.o
	lang := c.lang
	policy := plain.PolicyAsk
	finish := "exit"
	var f *config.File
	if o.config != "" {
		var err error
		f, err = config.Load(o.config, config.ParseOptions{Name: o.config, Known: c.set.IDs()})
		if err != nil {
			fmt.Fprintln(c.stderr, c.t("err.config", "error", err.Error()))
			return exitUsage
		}
		policy, finish = plain.Policy(f.Run.OnError), f.Run.Finish
		if o.lang == "" && f.Lang != "" {
			lang = f.Lang
			svc.SetLang(lang)
		}
	} else if o.yes || !isTTY(stdin) {
		policy = plain.PolicyAbort
	}

	pr := plain.New(plain.Options{Out: c.stdout, Lang: lang, Policy: policy, Yes: o.yes, Color: false})
	report := svc.RunPreflight(ctx, 4<<30)
	svc.SetReport(report)
	pr.PrintPreflight(report)
	if !report.OKToProceed() {
		fmt.Fprintln(c.stderr, c.t("err.preflight_blocked"))
		return exitFailure
	}

	req := tui.Request{Mode: c.mode, Lang: lang, Restore: o.restore, Resume: o.resume, RemoveData: o.removeData}
	switch c.mode {
	case "install":
		if f != nil {
			sec := config.Resolved{}
			env := config.OSEnv()
			env.Home = c.getenv("HOME")
			env.Getenv = func(k string) (string, bool) { v := c.getenv(k); return v, v != "" }
			var warns []string
			var err error
			sec, warns, err = f.ResolveSecrets(env)
			for _, w := range warns {
				fmt.Fprintln(c.stderr, w)
			}
			if err != nil {
				fmt.Fprintln(c.stderr, c.t("err.config", "error", err.Error()))
				return exitUsage
			}
			for _, v := range sec.Values() {
				svc.Logger().AddSecret(v)
			}
			req, err = app.RequestFromConfig(f, sec, c.set, tagsOf(report, o), o.restore)
			if err != nil {
				fmt.Fprintln(c.stderr, c.t("err.config", "error", err.Error()))
				return exitUsage
			}
			req.Lang, req.Resume = lang, o.resume
		} else {
			list, code := c.pickModules(tagsOf(report, o))
			if code != exitOK {
				return code
			}
			req.Modules = list
		}
	case "modules":
		list, code := c.pickModules(tagsOf(report, o))
		if code != exitOK {
			return code
		}
		req.Modules = list
	case "uninstall":
		if !o.yes {
			fmt.Fprintln(c.stderr, c.t("err.need_yes"))
			return exitUsage
		}
	case "reconcile":
		req.Mode = app.ModeReconcile
	}
	if c.mode == "install" {
		req.Reinstall = o.reinstall
	}
	if o.restore != "" && c.mode != "install" {
		req.Restore = ""
	}

	res, err := svc.RunPlain(ctx, req, app.PlainOptions{Out: c.stdout, In: stdin, Lang: lang, Yes: o.yes, Policy: policy, Color: false})
	if len(res.Skipped) > 0 {
		fmt.Fprintln(c.stdout, c.t("msg.skipped_modules", "list", strings.Join(res.Skipped, ", ")))
		fmt.Fprintln(c.stdout, c.t("msg.later"))
	}
	fmt.Fprintln(c.stdout, c.t("msg.log_at", "path", svc.LogPath()))
	if err != nil {
		c.log.Error("run failed", "error", err.Error())
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	if res.ConfigPath != "" {
		fmt.Fprintln(c.stdout, c.t("msg.config_saved", "path", res.ConfigPath))
	}
	doFinish(c, finish)
	return exitOK
}

func tagsOf(r preflight.Report, o *options) []string {
	tags := r.Facts.Tags()
	if o.gpu != "" {
		tags = append(tags, "gpu:"+strings.ToLower(o.gpu))
	}
	return tags
}

// ---- full screen ----

func runInteractive(ctx context.Context, c *runCtx, svc *app.Service) int {
	o := c.o
	// the checks (and the sudo password prompt) run on the normal screen
	report := svc.RunPreflight(ctx, 4<<30)
	svc.SetReport(report)
	d := preflight.Deps{Getenv: c.getenv, LookPath: exec.LookPath}
	con := preflight.DecideConsole(d, preflight.Options{Lang: c.lang, Glyphs: o.glyphs})
	lang := c.lang
	if con.SetFont {
		lang = preflight.ApplyConsole(ctx, &irun.ExecRunner{}, con)
	}
	if con.Lang != "" && o.lang == "" && lang == c.lang {
		lang = con.Lang
	}
	if c.getenv("TERM") == "linux" {
		tui.ApplyVTPalette(c.stdout)
		defer tui.ResetVTPalette(c.stdout)
	}
	cfg := tui.Config{Backend: svc, Version: version, Lang: lang, Glyphs: con.Glyph, Sixteen: con.Colors <= 16,
		NoAnimation: con.Glyph == tui.GlyphASCII, Restore: o.restore, Resume: o.resume}
	if c.mode != "install" {
		cfg.Mode = c.mode
	}
	if o.modules != "" || o.preset != "full" {
		list, code := c.pickModules(tagsOf(report, o))
		if code != exitOK {
			return code
		}
		cfg.Modules = list
	}
	cfg.Context = ctx
	res, err := tui.Run(cfg)
	if err != nil {
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", err.Error()))
		return exitFailure
	}
	if res.Err != nil {
		c.log.Error("run failed", "error", res.Err.Error())
		fmt.Fprintln(c.stderr, c.t("err.run_failed", "error", res.Err.Error()))
		fmt.Fprintln(c.stdout, c.t("msg.log_at", "path", svc.LogPath()))
		return exitFailure
	}
	if res.OK {
		doFinish(c, res.Action)
	}
	if !res.OK && res.Action != tui.ActionExit {
		return exitFailure
	}
	return exitOK
}

// doFinish performs the final action.
func doFinish(c *runCtx, action string) {
	switch action {
	case tui.ActionReboot, tui.ActionHyprland:
		if err := finishHook(action); err != nil {
			key := "msg.reboot_failed"
			if action == tui.ActionHyprland {
				key = "msg.hyprland_failed"
			}
			fmt.Fprintln(c.stderr, c.t(key, "error", err.Error()))
		}
	}
}

func realFinish(action string) error {
	switch action {
	case tui.ActionReboot:
		return exec.Command("systemctl", "reboot").Run()
	case tui.ActionHyprland:
		for _, n := range []string{"start-hyprland", "Hyprland"} {
			if p, err := exec.LookPath(n); err == nil {
				return syscall.Exec(p, []string{n}, os.Environ())
			}
		}
		return errors.New("Hyprland not found in PATH")
	}
	return nil
}
