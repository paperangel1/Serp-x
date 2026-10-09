// Package app wires the engine to the two front ends (full-screen TUI and
// plain lines): it builds the environment, maps wizard answers and
// my-setup.toml to engine options, runs the modes and reports progress.
package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"serpx/installer"
	"serpx/installer/internal/backup"
	"serpx/installer/internal/engine"
	"serpx/installer/internal/eta"
	"serpx/installer/internal/fsx"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/journal"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plan"
	"serpx/installer/internal/preflight"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/tui"
	"serpx/installer/internal/xlog"
)

// Config is everything the service needs from the outside; tests replace the
// system-facing parts (Runner, DL, Net, Rootfs, Home, ...).
type Config struct {
	Home    string
	Getenv  func(string) string
	Version string
	Commit  string
	Payload string // --payload (dir or .tar.zst); "" = search
	Lang    string
	Glyphs  string
	Rootfs  string // "" = "/"
	Exe     string // path of the running binary (payload search)
	Cwd     string
	// System-facing pieces (nil = the real ones).
	Runner     run.Runner
	Arm        func(run.Whitelist) // extra: tests arm the fake runner's whitelist
	DL         steps.Downloader
	Net        preflight.NetProbe
	Deps       *preflight.Deps
	LookPath   func(string) (string, error)
	Now        func() time.Time
	NProc      int
	Compressor backup.Compressor
	SkipNet    bool
	SkipSudo   bool
	// Options of the install (flags).
	Compositors []string
}

// Service implements tui.Backend and the plain runs.
type Service struct {
	cfg  Config
	set  *manifest.Set
	cat  *i18n.Catalog
	log  *xlog.Logger
	home string
	exec *run.ExecRunner

	mu      sync.Mutex
	report  *preflight.Report
	payload string
	runID   string
}

// New loads the embedded manifests and strings.
func New(cfg Config) (*Service, error) {
	if cfg.Getenv == nil {
		cfg.Getenv = os.Getenv
	}
	if cfg.Home == "" {
		cfg.Home = cfg.Getenv("HOME")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.NProc == 0 {
		cfg.NProc = runtime.NumCPU()
	}
	if cfg.LookPath == nil {
		cfg.LookPath = exec.LookPath
	}
	if cfg.Lang == "" {
		cfg.Lang = i18n.RU
	}
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		return nil, err
	}
	cat, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		return nil, err
	}
	s := &Service{cfg: cfg, set: set, cat: cat, home: cfg.Home}
	s.log = xlog.New("installer", cfg.Getenv)
	if cfg.Runner == nil {
		s.exec = &run.ExecRunner{Redact: s.log.Redact}
	}
	s.runID = journal.NewRunID(cfg.Now())
	return s, nil
}

// SetLang changes the language of step titles (my-setup.toml lang).
func (s *Service) SetLang(l string) { s.cfg.Lang = l }

// Logger returns the installer logger.
func (s *Service) Logger() *xlog.Logger { return s.log }

// Catalog returns the installer strings.
func (s *Service) Catalog() *i18n.Catalog { return s.cat }

// Set implements tui.Backend.
func (s *Service) Set() *manifest.Set { return s.set }

// StateDir is ~/.local/state/serpantinum-installer.
func (s *Service) StateDir() string {
	return filepath.Join(s.home, ".local", "state", "serpantinum-installer")
}

// ShareDir is ~/.local/share/serpantinum-installer.
func (s *Service) ShareDir() string {
	return filepath.Join(s.home, ".local", "share", "serpantinum-installer")
}

// BackupDir is ~/serpantinum-backups.
func (s *Service) BackupDir() string { return filepath.Join(s.home, "serpantinum-backups") }

// LogPath implements tui.Backend (the per-run log of the engine).
func (s *Service) LogPath() string {
	return filepath.Join(s.StateDir(), "logs", s.runID+".log")
}

func (s *Service) runner() run.Runner {
	if s.cfg.Runner != nil {
		return s.cfg.Runner
	}
	return s.exec
}

func (s *Service) arm(w run.Whitelist) {
	if s.exec != nil {
		s.exec.White = w
	}
	if s.cfg.Arm != nil {
		s.cfg.Arm(w)
	}
}

func (s *Service) compressor() backup.Compressor {
	if s.cfg.Compressor != nil {
		return s.cfg.Compressor
	}
	return backup.Zstd{}
}

func (s *Service) roots(notes string) backup.Roots {
	if notes == "" {
		notes = filepath.Join(s.home, "Notes")
	}
	return backup.Roots{Config: filepath.Join(s.home, ".config"), State: filepath.Join(s.home, ".local", "state"), Notes: notes}
}

// ---- preflight ----

// SetReport stores a finished preflight (the TUI main runs it before the
// full-screen program so that the sudo prompt stays on the normal screen).
func (s *Service) SetReport(r preflight.Report) {
	s.mu.Lock()
	s.report = &r
	s.mu.Unlock()
}

// Report returns the stored preflight, if any.
func (s *Service) Report() *preflight.Report {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.report
}

// Preflight implements tui.Backend; the stored report wins.
func (s *Service) Preflight(ctx context.Context) preflight.Report {
	if r := s.Report(); r != nil {
		return *r
	}
	r := s.RunPreflight(ctx, 4<<30)
	s.SetReport(r)
	return r
}

// RunPreflight runs the real checks (or the injected ones).
func (s *Service) RunPreflight(ctx context.Context, need int64) preflight.Report {
	var d preflight.Deps
	switch {
	case s.cfg.Deps != nil:
		d = *s.cfg.Deps
		if d.Runner == nil {
			d.Runner = s.runner()
		}
	default:
		var net preflight.NetProbe = s.cfg.Net
		if net == nil {
			net = preflight.HTTPProbe{}
		}
		d = preflight.RealDeps(s.runner(), net)
		d.Home = s.home
		d.StateDir = s.StateDir()
		d.Getenv = s.cfg.Getenv
	}
	return preflight.Run(ctx, d, preflight.Options{NeedBytes: need, Lang: s.cfg.Lang, Glyphs: s.cfg.Glyphs, SkipNet: s.cfg.SkipNet, SkipSudo: s.cfg.SkipSudo})
}

// ---- installed ----

// Installed implements tui.Backend.
func (s *Service) Installed() *tui.Installed {
	in, err := engine.ReadInstalled(s.StateDir())
	if err != nil {
		return nil
	}
	t, _ := time.Parse(time.RFC3339, in.InstalledAt)
	return &tui.Installed{Build: in.Build, InstalledAt: t, Modules: in.Modules}
}

// ---- payload ----

// Payload resolves the payload directory (flag, then upwards from the binary
// and the working directory); a .tar.zst is unpacked into the state dir.
func (s *Service) Payload() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.payload != "" {
		return s.payload, nil
	}
	p, err := findPayload(s.cfg.Payload, s.cfg.Exe, s.cfg.Cwd, filepath.Join(s.StateDir(), "payload"), s.compressor())
	if err != nil {
		return "", err
	}
	s.payload = p
	return p, nil
}

// ---- environment ----

func (s *Service) newEnv(req tui.Request, rep steps.Reporter, payload string) *steps.Env {
	var dl steps.Downloader = s.cfg.DL
	if dl == nil {
		dl = steps.HTTPDownloader{}
	}
	opts := steps.Options{Compositors: s.cfg.Compositors, Reinstall: req.Reinstall, Secrets: req.Secrets, Config: req.Config}
	if len(opts.Compositors) == 0 {
		opts.Compositors = []string{"hyprland"}
	}
	opts.InstallState = steps.DetectInstallState(s.home)
	if opts.Secrets == nil {
		opts.Secrets = map[string]string{}
	}
	if opts.Config == nil {
		opts.Config = map[string]string{}
	}
	e := &steps.Env{
		Home: s.home, Payload: payload, StateDir: s.StateDir(), Rootfs: s.cfg.Rootfs, Run: s.runID,
		Version: s.cfg.Version, Commit: s.cfg.Commit, Runner: s.runner(), DL: dl, Set: s.set, Opts: opts, Rep: rep,
		Getenv: s.cfg.Getenv, LookPath: s.cfg.LookPath, Now: s.cfg.Now, NProc: s.cfg.NProc,
	}
	return e
}

// registerSecrets teaches the logger and the redactor about the secret values.
func (s *Service) registerSecrets(req tui.Request) {
	for _, v := range req.Secrets {
		if v != "" {
			s.log.AddSecret(v)
		}
	}
}

// explicit returns the module list of a request (resolved by the engine).
func (s *Service) explicit(req tui.Request) []string { return req.Modules }

func (s *Service) selection(req tui.Request) (*resolve.Selection, error) {
	return resolve.New(s.set).Resolve(s.modulesFor(req))
}

// modulesFor: install/modules use the request; repair/uninstall/reconcile the
// installed set.
func (s *Service) modulesFor(req tui.Request) []string {
	switch req.Mode {
	case tui.ModeRepair, tui.ModeUninstall:
		if in, err := engine.ReadInstalled(s.StateDir()); err == nil {
			return in.Modules
		}
	}
	return req.Modules
}

// adoptUpstream: an install request over an original (upstream) Serpantinum install is
// handled as a reinstall: the config files are redeployed (upstream "current" state would
// skip them), user data is backed up first and restored afterwards. Returns true if so.
func (s *Service) adoptUpstream(req tui.Request) (tui.Request, bool) {
	if req.Mode != tui.ModeInstall || s.Installed() != nil {
		return req, false
	}
	if kind, _ := preflight.DetectInstall(s.home); kind != preflight.InstallUpstream {
		return req, false
	}
	req.Reinstall = true
	return req, true
}

// Plan implements tui.Backend: the steps a Request would run.
func (s *Service) Plan(ctx context.Context, req tui.Request) (tui.PlanInfo, error) {
	req, _ = s.adoptUpstream(req)
	payload, err := s.Payload()
	if err != nil {
		payload = s.cfg.Cwd // plan texts do not need the payload
	}
	if req.Mode == tui.ModeRepair || req.Mode == tui.ModeModules || req.Mode == ModeReconcile {
		if s.Installed() == nil {
			return tui.PlanInfo{}, engine.ErrNotInstalled
		}
	}
	e := s.newEnv(req, steps.NopReporter{}, payload)
	var list []steps.Step
	var sel *resolve.Selection
	switch req.Mode {
	case tui.ModeUninstall:
		setup := &engine.Setup{Env: e, Cat: s.cat}
		list, err = engine.PlanUninstall(setup, engine.UninstallOptions{RemoveData: req.RemoveData, BackupBefore: func(context.Context) error { return nil }})
		if err != nil {
			return tui.PlanInfo{}, err
		}
	default:
		mode := steps.ModeInstall
		var only map[string]bool
		switch req.Mode {
		case tui.ModeRepair:
			mode = steps.ModeRepair
			e.Opts.InstallState = steps.StateCurrent
		case tui.ModeModules:
			mode = steps.ModeModules
			e.Opts.InstallState = steps.StateCurrent
		}
		e.Mode = mode
		sel, err = s.selection(req)
		if err != nil {
			return tui.PlanInfo{}, err
		}
		if mode == steps.ModeModules {
			only = map[string]bool{}
			have := map[string]bool{}
			if in := s.Installed(); in != nil {
				for _, m := range in.Modules {
					have[m] = true
				}
			}
			for _, m := range sel.Modules {
				if !have[m] {
					only[m] = true
				}
			}
		}
		e.Sel = sel
		list, err = plan.Build(plan.Input{Set: s.set, Sel: sel, Cat: s.cat, Opts: e.Opts, Restore: req.Restore != "" || req.Reinstall, Only: only})
		if err != nil {
			return tui.PlanInfo{}, err
		}
	}
	info := tui.PlanInfo{}
	mdl := eta.New(s.cfg.NProc)
	_ = mdl.Load(filepath.Join(s.StateDir(), journal.FileTimings))
	info.ETA = mdl
	for _, st := range list {
		est := int(st.Estimate().Seconds())
		info.Steps = append(info.Steps, tui.StepInfo{ID: st.ID(), Module: st.Module(), Title: manifest.Text{RU: st.Title("ru"), EN: st.Title("en")}, Root: st.Root(), EstSec: est})
		info.Items = append(info.Items, eta.Item{ID: st.ID(), Kind: eta.KindOther, EstimateS: est})
		info.Seconds += est
	}
	if sel != nil {
		for _, id := range sel.Modules {
			if m, ok := s.set.Get(id); ok {
				info.DownloadMiB += m.Estimate.DownloadMiB
				info.DiskMiB += m.Estimate.DiskMiB
			}
		}
	}
	if info.DownloadMiB > 0 {
		speed := eta.DefaultSpeed
		if r := s.Report(); r != nil && r.Facts.NetSpeedBps > 0 {
			speed = int(r.Facts.NetSpeedBps)
		}
		info.Seconds += int(info.DownloadMiB * (1 << 20) / float64(speed))
	}
	return info, nil
}

// ---- backup helpers ----

func (s *Service) autoBackup(modules []string, notes string) (*backup.AutoResult, error) {
	host, _ := os.Hostname()
	return backup.AutoBackup(backup.AutoOptions{
		ExportOptions: backup.ExportOptions{Roots: s.roots(notes), Build: s.cfg.Version, Modules: modules, Host: host,
			Now: s.cfg.Now(), OutDir: s.BackupDir(), Compressor: s.compressor()},
		Run: s.runID, ShareDir: s.ShareDir(),
	})
}

// ExportBackup writes a backup archive (without secrets) into dir.
func (s *Service) ExportBackup(dir string) (string, error) {
	var mods []string
	if in := s.Installed(); in != nil {
		mods = in.Modules
	}
	host, _ := os.Hostname()
	if dir == "" {
		dir = s.BackupDir()
	}
	return backup.Export(backup.ExportOptions{Roots: s.roots(""), Build: s.cfg.Version, Modules: mods, Host: host,
		Now: s.cfg.Now(), OutDir: dir, Compressor: s.compressor()})
}

// ImportBackup restores an archive; the result lists secrets to enter again.
func (s *Service) ImportBackup(ctx context.Context, archive string) (*backup.ImportResult, error) {
	e := s.newEnv(tui.Request{}, steps.NopReporter{}, s.cfg.Cwd)
	fx, err := fsx.New(fsx.Config{Allowed: append(e.Allowed(), filepath.Join(s.home, ".config", "serpantinum"), filepath.Join(s.home, ".local/state/serpantinum")), StateDir: s.StateDir(), Run: s.runID})
	if err != nil {
		return nil, err
	}
	var mods []string
	if in := s.Installed(); in != nil {
		mods = in.Modules
	}
	return backup.Import(ctx, archive, backup.ImportOptions{Roots: s.roots(""), FS: fx, Tag: "restore", Modules: mods, Compressor: s.compressor()})
}

// restoreHook returns the Hooks.Restore function for an archive.
func (s *Service) restoreHook(e *steps.Env, archive string, h func(string, []string)) func(context.Context) error {
	return func(ctx context.Context) error {
		if archive == "" {
			return errors.New("no backup archive to restore")
		}
		notes := ""
		if d := e.Opts.Config["tools.notes_dir"]; d != "" {
			notes = e.Expand(d)
		}
		var mods []string
		if e.Sel != nil {
			mods = e.Sel.Modules
		}
		res, err := backup.Import(ctx, archive, backup.ImportOptions{Roots: s.roots(notes), FS: e.FS, Tag: "restore", Modules: mods, Compressor: s.compressor()})
		if err != nil {
			return err
		}
		if _, err := backup.RestoreSecretsIfEmpty(ctx, s.roots(notes), s.ShareDir(), e.FS, "restore"); err != nil {
			e.Rep.Warn("local secrets copy: " + err.Error())
		}
		if len(res.Retype) > 0 {
			e.Rep.Log("secrets to enter again: " + strings.Join(res.Retype, ", "))
		}
		if h != nil {
			h(fmt.Sprintf("%d files restored", len(res.Restored)), res.Retype)
		}
		return nil
	}
}

var _ = io.Discard
