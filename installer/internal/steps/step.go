// Package steps holds the step kinds of the installer (plan 4.3) and the
// ports of upstream install/modules/{deps,deploy,config,service,migrate}.sh.
//
// A Step is a stateless description; everything it needs (paths, Runner,
// fsx, options) comes from Env, so tests run with a temp HOME, a temp
// "root filesystem" and a run.FakeRunner and never touch the real system.
package steps

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"serpx/installer/internal/fsx"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/run"
)

// Mode of the engine run.
type Mode string

const (
	ModeInstall   Mode = "install"
	ModeRepair    Mode = "repair"
	ModeModules   Mode = "modules"
	ModeUninstall Mode = "uninstall"
	ModeReconcile Mode = "reconcile"
)

// Install states (upstream detect_install_state).
const (
	StateFresh   = "fresh"
	StateLegacy  = "legacy"
	StateCurrent = "current"
)

// Reporter receives human-readable progress. Never pass secrets to it.
type Reporter interface {
	Log(msg string)
	Warn(msg string)
	Progress(frac float64, text string) // frac in 0..1, <0 = unknown
}

// NopReporter discards everything.
type NopReporter struct{}

func (NopReporter) Log(string)               {}
func (NopReporter) Warn(string)              {}
func (NopReporter) Progress(float64, string) {}

// Downloader fetches a URL to a local file (tests inject a fake).
type Downloader interface {
	Download(ctx context.Context, url, dst string) error
}

// Options are the answers of the wizard / my-setup.toml.
type Options struct {
	Compositors  []string // upstream SELECTED_COMPOSITORS; default [hyprland]
	Reinstall    bool     // upstream IS_REINSTALL
	InstallState string   // fresh|legacy|current (detected before the run)
	OldCommit    string
	ReplaceDM    bool // upstream REPLACE_DM (sddm)
	SDDMWayland  bool // upstream SDDM_WAYLAND
	// WallpaperSample: also fetch the 3-random-pictures sample when the full
	// pack is not selected (upstream always did; it costs a ~300 MiB clone).
	WallpaperSample bool
	// Secrets holds secret answers by config key. Values are never logged or
	// journaled.
	Secrets map[string]string
	// Config holds non-secret answers by config key.
	Config map[string]string
}

// Hooks are the places where UI-bound or stage-4 code plugs in.
type Hooks struct {
	Preflight func(ctx context.Context) error // nil = nothing to check here
	Restore   func(ctx context.Context) error // backup import (stage 4)
}

// Env is everything a step may touch.
type Env struct {
	Home     string // $HOME
	Payload  string // payload root: bin/ src/ config/ compositors/ version.txt
	StateDir string // ~/.local/state/serpantinum-installer
	Rootfs   string // "/" (tests: a temp dir standing in for /)
	Run      string
	Mode     Mode
	Version  string // build version, e.g. 2.2.4-s3
	Commit   string

	Runner   run.Runner
	FS       *fsx.FS
	DL       Downloader
	Set      *manifest.Set
	Sel      *resolve.Selection
	Opts     Options
	Hooks    Hooks
	Rep      Reporter
	Getenv   func(string) string
	LookPath func(string) (string, error)
	Now      func() time.Time
	NProc    int
}

// Step is the contract of plan 4.3 (Estimate has no eta.Model yet: the model
// is stage 4; the base estimate is returned and the caller refines it).
type Step interface {
	ID() string
	Module() string
	Title(lang string) string
	Root() bool
	Estimate() time.Duration
	Check(ctx context.Context, env *Env) (done bool, err error)
	Apply(ctx context.Context, env *Env, rep Reporter) error
	Verify(ctx context.Context, env *Env) error
	Rollback(ctx context.Context, env *Env) error
}

// Base implements the descriptive half of Step.
type Base struct {
	StepID, Mod string
	Text        manifest.Text
	NeedsRoot   bool
	Est         time.Duration
}

func (b Base) ID() string                           { return b.StepID }
func (b Base) Module() string                       { return b.Mod }
func (b Base) Title(lang string) string             { return b.Text.Get(lang) }
func (b Base) Root() bool                           { return b.NeedsRoot }
func (b Base) Estimate() time.Duration              { return b.Est }
func (b Base) Verify(context.Context, *Env) error   { return nil }
func (b Base) Rollback(context.Context, *Env) error { return nil }

// ---- Env helpers ----

func (e *Env) rep() Reporter {
	if e.Rep == nil {
		return NopReporter{}
	}
	return e.Rep
}

func (e *Env) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

func (e *Env) rootfs() string {
	if e.Rootfs == "" {
		return "/"
	}
	return e.Rootfs
}

// Sys maps an absolute system path into the (possibly fake) root filesystem.
func (e *Env) Sys(p string) string { return filepath.Join(e.rootfs(), p) }

// Paths of the installation.
func (e *Env) TargetBase() string { return filepath.Join(e.Home, ".local/share/serpantinum") }
func (e *Env) BinDir() string     { return filepath.Join(e.Home, ".local/bin") }
func (e *Env) ConfigDir() string  { return filepath.Join(e.Home, ".config/serpantinum") }
func (e *Env) SecretsDir() string { return filepath.Join(e.ConfigDir(), "secrets") }
func (e *Env) VersionFile() string {
	return filepath.Join(e.Home, ".local/state/serpantinum/version")
}
func (e *Env) CacheDir() string {
	if d := e.getenv("XDG_CACHE_HOME"); d != "" {
		return d
	}
	return filepath.Join(e.Home, ".cache")
}

func (e *Env) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func (e *Env) lookPath(name string) bool {
	if e.LookPath == nil {
		return false
	}
	_, err := e.LookPath(name)
	return err == nil
}

// Expand resolves "~/", @HOME@ and the other manifest tokens.
func (e *Env) Expand(s string) string {
	r := strings.NewReplacer(
		"@HOME@", e.Home,
		"@SRC@", filepath.Join(e.TargetBase(), "src"),
		"@PAYLOAD@", e.Payload,
		"@BIN_X@", filepath.Join(e.BinDir(), "serpantinum-x"),
		"@WALLPAPER_DIR@", e.WallpaperDir(),
	)
	s = r.Replace(s)
	if s == "~" {
		return e.Home
	}
	if strings.HasPrefix(s, "~/") {
		return filepath.Join(e.Home, s[2:])
	}
	return s
}

// ExpandAll expands every element.
func (e *Env) ExpandAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = e.Expand(s)
	}
	return out
}

// exec runs a command, returning its result. A non-zero exit is an error.
func (e *Env) exec(ctx context.Context, root bool, name string, args ...string) (run.Result, error) {
	return e.Runner.Run(ctx, run.Cmd{Name: name, Args: args, Root: root, OnLine: e.lineLogger()})
}

func (e *Env) lineLogger() func(stream, line string) {
	rep := e.rep()
	return func(_ string, line string) { rep.Log(line) }
}

// best runs a command like upstream's `cmd || true`: failure is reported as a
// warning and swallowed. A cancelled context is still an error.
func (e *Env) best(ctx context.Context, root bool, name string, args ...string) error {
	if _, err := e.exec(ctx, root, name, args...); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		e.rep().Warn(fmt.Sprintf("%s: %v", run.Cmd{Name: name, Args: args, Root: root}, err))
	}
	return nil
}

// ok runs a command and reports only whether it exited 0.
func (e *Env) ok(ctx context.Context, name string, args ...string) bool {
	_, err := e.Runner.Run(ctx, run.Cmd{Name: name, Args: args})
	return err == nil
}

// out runs a command and returns its stdout (error ignored when the command
// printed something: `pacman -T` exits non-zero when packages are missing).
func (e *Env) out(ctx context.Context, name string, args ...string) (string, error) {
	res, err := e.Runner.Run(ctx, run.Cmd{Name: name, Args: args, Env: []string{"LC_ALL=C"}})
	if err != nil && ctx.Err() != nil {
		return "", ctx.Err()
	}
	return res.Stdout, err
}

// rootInstallFile writes data to a root-owned destination: temp file in the
// state dir, then `sudo install -m MODE tmp dest` (whitelisted kind).
func (e *Env) rootInstallFile(ctx context.Context, dest string, data []byte, mode string) error {
	tmpDir := filepath.Join(e.StateDir, "tmp")
	if err := os.MkdirAll(tmpDir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(tmpDir, "root-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if _, err := e.exec(ctx, true, "install", "-m", mode, f.Name(), dest); err != nil {
		return err
	}
	return nil
}

// readIfExists returns file content or nil.
func readIfExists(p string) ([]byte, error) {
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return b, err
}

func dur(sec int) time.Duration { return time.Duration(sec) * time.Second }

func runCmd(name string, args ...string) run.Cmd { return run.Cmd{Name: name, Args: args} }

// OKQuiet runs a command and reports only whether it exited 0 (exported for the engine).
func (e *Env) OKQuiet(ctx context.Context, name string, args ...string) bool {
	return e.ok(ctx, name, args...)
}

// Out runs a command and returns stdout (exported for the engine).
func (e *Env) Out(ctx context.Context, name string, args ...string) (string, error) {
	return e.out(ctx, name, args...)
}

// Now2 returns the current time (exported for the engine).
func (e *Env) Now2() time.Time { return e.now() }
