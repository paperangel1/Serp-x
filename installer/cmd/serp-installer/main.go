// serp-installer: installer for the serp-x build of Serpantinum.
//
// The command line picks a mode; the engine runs behind internal/app, shown
// either by the full-screen UI (internal/tui) or line by line (--plain).
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"

	"serpx/installer"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/xlog"
)

// Set by -ldflags "-X main.version=... -X main.commit=...".
var (
	version = "dev"
	commit  = "none"
)

// Exit codes.
const (
	exitOK      = 0
	exitFailure = 1
	exitUsage   = 2
)

// modes lists the commands in the order of the usage text.
var modes = []string{"install", "repair", "modules", "uninstall", "backup", "reconcile", "export-config"}

type options struct {
	config, restore, payload, lang, glyphs, preset, modules, gpu, out         string
	yes, plain, resume, reinstall, dryRun, showVersion, removeData, presetSet bool
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, os.Getenv))
}

func newFlagSet(o *options, out io.Writer) *flag.FlagSet {
	fs := flag.NewFlagSet("serp-installer", flag.ContinueOnError)
	fs.SetOutput(out)
	fs.StringVar(&o.config, "config", "", "")
	fs.StringVar(&o.restore, "restore", "", "")
	fs.BoolVar(&o.yes, "yes", false, "")
	fs.BoolVar(&o.plain, "plain", false, "")
	fs.StringVar(&o.payload, "payload", "", "")
	fs.StringVar(&o.lang, "lang", "", "")
	fs.StringVar(&o.glyphs, "glyphs", "", "")
	fs.BoolVar(&o.resume, "resume", false, "")
	fs.BoolVar(&o.dryRun, "dry-run", false, "")
	fs.StringVar(&o.preset, "preset", "full", "")
	fs.StringVar(&o.modules, "modules", "", "")
	fs.StringVar(&o.gpu, "gpu", "", "")
	fs.BoolVar(&o.showVersion, "version", false, "")
	fs.StringVar(&o.out, "out", "", "")
	fs.BoolVar(&o.removeData, "remove-data", false, "")
	fs.BoolVar(&o.reinstall, "reinstall", false, "")
	return fs
}

// parseArgs allows flags before and after the sub-command.
func parseArgs(args []string, o *options, out io.Writer) (rest []string, err error) {
	fs := newFlagSet(o, out)
	defer fs.Visit(func(f *flag.Flag) {
		if f.Name == "preset" {
			o.presetSet = true
		}
	})
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			return rest, nil
		}
		rest = append(rest, args[0])
		args = args[1:]
		if len(args) == 0 {
			return rest, nil
		}
	}
}

func run(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	var o options
	// flag errors go to stderr in English (the catalog is not loaded yet)
	rest, err := parseArgs(args, &o, io.Discard)
	if err != nil {
		fmt.Fprintln(stderr, "serp-installer:", err)
		return exitUsage
	}

	cat, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		fmt.Fprintln(stderr, "serp-installer: cannot load strings:", err)
		return exitFailure
	}
	if !i18n.ValidLang(o.lang) {
		fmt.Fprintln(stderr, cat.T(i18n.EN, "err.bad_flag", "flag", "--lang", "value", o.lang))
		return exitUsage
	}
	lang := i18n.DetectLang(o.lang, getenv)
	t := func(key string, kv ...string) string { return cat.T(lang, key, kv...) }

	if o.showVersion {
		fmt.Fprintln(stdout, t("app.version", "version", version, "commit", commit))
		return exitOK
	}
	switch o.glyphs {
	case "", "nerd", "unicode", "ascii":
	default:
		fmt.Fprintln(stderr, t("err.bad_flag", "flag", "--glyphs", "value", o.glyphs))
		return exitUsage
	}

	if len(rest) == 0 {
		usage(stdout, t)
		return exitUsage
	}
	mode := rest[0]
	if !contains(modes, mode) {
		fmt.Fprintln(stderr, t("err.unknown_command", "name", mode))
		usage(stderr, t)
		return exitUsage
	}

	log := xlog.New("installer", getenv)
	log.Info("start", "mode", mode, "version", version, "dry_run", o.dryRun, "plain", o.plain, "lang", lang)

	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		fmt.Fprintln(stderr, t("err.load_manifests", "error", err.Error()))
		log.Error("manifests", "error", err.Error())
		return exitFailure
	}
	if err := cat.Verify(); err != nil {
		fmt.Fprintln(stderr, t("err.load_i18n", "error", err.Error()))
		return exitFailure
	}
	if mode == "install" && o.dryRun {
		return dryRunInstall(&o, set, cat, lang, stdout, stderr, getenv, log)
	}
	ctx := &runCtx{o: &o, rest: rest[1:], mode: mode, set: set, cat: cat, lang: lang, t: t, stdout: stdout, stderr: stderr, getenv: getenv, log: log}
	switch mode {
	case "backup":
		return cmdBackup(ctx)
	case "export-config":
		return cmdExportConfig(ctx)
	}
	return cmdRun(ctx)
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func usage(w io.Writer, t func(string, ...string) string) {
	fmt.Fprintln(w, t("usage.head"))
	fmt.Fprintln(w, t("usage.commands"))
	for _, m := range modes {
		fmt.Fprintf(w, "  %-14s %s\n", m, t("cmd."+m))
	}
	fmt.Fprintln(w, t("usage.flags"))
	flags := [][2]string{
		{"--config FILE", "flag.config"}, {"--restore FILE", "flag.restore"}, {"--yes", "flag.yes"},
		{"--plain", "flag.plain"}, {"--payload PATH", "flag.payload"}, {"--lang ru|en", "flag.lang"},
		{"--glyphs nerd|unicode|ascii", "flag.glyphs"}, {"--resume", "flag.resume"}, {"--dry-run", "flag.dry_run"},
		{"--preset NAME", "flag.preset"}, {"--modules a,b", "flag.modules"}, {"--gpu NAME", "flag.gpu"},
		{"--version", "flag.version"}, {"--out PATH", "flag.out"}, {"--remove-data", "flag.remove_data"}, {"--reinstall", "flag.reinstall"},
	}
	for _, f := range flags {
		fmt.Fprintf(w, "  %-28s %s\n", f[0], t(f[1]))
	}
}

// detectFromFlags builds the Detect from the --gpu flag (real detection is
// the preflight of stage 4).
func detectFromFlags(o *options) resolve.Detect {
	var d resolve.Detect
	if o.gpu != "" {
		d.Tags = append(d.Tags, "gpu:"+strings.ToLower(o.gpu))
	}
	return d
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
