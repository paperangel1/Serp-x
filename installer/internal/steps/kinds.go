package steps

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/run"
)

// ---- argument helpers (steps.args is free-form TOML) ----

func argStr(m map[string]any, k string) string {
	s, _ := m[k].(string)
	return s
}

func argStrs(m map[string]any, k string) []string {
	var out []string
	switch v := m[k].(type) {
	case []string:
		return v
	case []any:
		for _, x := range v {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

func argMap(m map[string]any, k string) map[string]string {
	out := map[string]string{}
	if v, ok := m[k].(map[string]any); ok {
		for kk, x := range v {
			if s, ok := x.(string); ok {
				out[kk] = s
			}
		}
	}
	return out
}

// builtins are the Go-implemented steps a manifest refers to by id
// (`kind = "builtin"`).
var builtins = map[string]func(Base) Step{
	"core.pre.multilib": func(b Base) Step { return multilibStep{b} },
	"core.pre.tools":    func(b Base) Step { return toolsStep{b} },
	"core.pre.migrate":  func(b Base) Step { return migrateStep{b} },
	"core.pre.cleanup":  func(b Base) Step { return cleanupStep{b} },
	"core.fonts":        func(b Base) Step { return fontsStep{b} },
	"core.config":       func(b Base) Step { return configStep{b} },
	"core.wallpapers":   func(b Base) Step { return wallpapersStep{Base: b, Full: false} },
	"core.state":        func(b Base) Step { return stateStep{b} },
	"wallpapers.clone":  func(b Base) Step { return wallpapersStep{Base: b, Full: true} },
	"sddm.theme":        func(b Base) Step { return sddmThemeStep{b} },
	"sddm.enable":       func(b Base) Step { return sddmEnableStep{b} },
}

// BuiltinIDs lists the ids that have a Go implementation (used by tests that
// compare them with the manifests).
func BuiltinIDs() []string {
	var ids []string
	for id := range builtins {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// FromManifest builds the step for one `[[steps]]` entry of module m.
func FromManifest(m *manifest.Manifest, st manifest.Step) (Step, error) {
	b := Base{StepID: st.ID, Mod: m.ID, Text: st.Title, NeedsRoot: st.Root, Est: dur(st.EstimateS)}
	switch st.Kind {
	case "builtin":
		f, ok := builtins[st.ID]
		if !ok {
			return nil, fmt.Errorf("step %s: no builtin implementation", st.ID)
		}
		return f(b), nil
	case "script", "root":
		if st.Kind == "root" {
			b.NeedsRoot = true
		}
		return newCmdStep(b, st), nil
	case "hypr":
		if _, ok := st.Args["env"]; ok {
			return hyprEnvStep{Base: b, Env: argMap(st.Args, "env")}, nil
		}
		return newCmdStep(b, st), nil
	case "files":
		return filesStep{Base: b, Dirs: argStrs(st.Args, "dirs"), Mode: argStr(st.Args, "mode")}, nil
	case "link":
		return linkStep{Base: b, Names: argStrs(st.Args, "links"), Dir: argStr(st.Args, "dir"),
			System: argStrs(st.Args, "system"), SystemDir: argStr(st.Args, "system_dir")}, nil
	case "template":
		return templateStep{Base: b, From: argStr(st.Args, "from"), To: argStr(st.Args, "to")}, nil
	case "secret":
		keys := argStrs(st.Args, "keys")
		if k := argStr(st.Args, "key"); k != "" {
			keys = append(keys, k)
		}
		return NewSecrets(b, keys), nil
	case "download":
		return gitStep{Base: b, URL: argStr(st.Args, "git"), Dest: argStr(st.Args, "dest")}, nil
	case "restore":
		return restoreStep{b}, nil
	}
	return nil, fmt.Errorf("step %s: kind %q is not built from manifests", st.ID, st.Kind)
}

// ---- script / root / hypr (cmd) ----

type cmdStep struct {
	Base
	Cmd, CheckCmd, UndoCmd []string
	Dest, Content, Mode    string
	MkDir                  string
	hypr                   bool
	// SelfSudo: the command is shown as a root step but runs as the user and
	// elevates itself (x_vpn.sh install uses `sudo -n install` inside).
	SelfSudo bool
	SetEnv   []string // KEY=VAL added to the environment of the command
}

func newCmdStep(b Base, st manifest.Step) Step {
	return cmdStep{Base: b, Cmd: argStrs(st.Args, "cmd"), CheckCmd: st.Check, UndoCmd: st.Undo,
		Dest: argStr(st.Args, "dest"), Content: argStr(st.Args, "content"), Mode: argStr(st.Args, "mode"),
		MkDir: argStr(st.Args, "mkdir"), hypr: st.Kind == "hypr",
		SelfSudo: argStr(st.Args, "self_sudo") == "true", SetEnv: argStrs(st.Args, "setenv")}
}

func (s cmdStep) cmd(e *Env, argv []string, root bool) run.Cmd {
	a := e.ExpandAll(argv)
	return run.Cmd{Name: a[0], Args: a[1:], Root: root && !s.SelfSudo, Env: s.SetEnv, OnLine: e.lineLogger()}
}

func (s cmdStep) hyprMissing(e *Env) bool {
	if !s.hypr {
		return false
	}
	_, err := os.Stat(filepath.Join(e.Home, ".config/hypr/hyprland.lua"))
	return err != nil
}

func (s cmdStep) Check(ctx context.Context, e *Env) (bool, error) {
	if s.hyprMissing(e) {
		e.rep().Warn(s.StepID + ": no ~/.config/hypr/hyprland.lua (Lua config), step skipped")
		return true, nil
	}
	if s.Dest != "" {
		b, err := readIfExists(e.Sys(e.Expand(s.Dest)))
		return err == nil && b != nil && string(b) == s.Content, err
	}
	if len(s.CheckCmd) == 0 {
		return false, nil
	}
	_, err := e.Runner.Run(ctx, s.cmd(e, s.CheckCmd, s.NeedsRoot && s.CheckCmd[0] != "test"))
	if err != nil && ctx.Err() != nil {
		return false, ctx.Err()
	}
	return err == nil, nil
}

func (s cmdStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	if s.MkDir != "" {
		d := e.Expand(s.MkDir)
		if _, err := e.FS.Check(d); err != nil {
			return err
		}
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
	}
	if s.Dest != "" {
		mode := s.Mode
		if mode == "" {
			mode = "644"
		}
		return e.rootInstallFile(ctx, e.Expand(s.Dest), []byte(s.Content), mode)
	}
	if len(s.Cmd) == 0 {
		return errors.New("step has no command")
	}
	_, err := e.Runner.Run(ctx, s.cmd(e, s.Cmd, s.NeedsRoot))
	return err
}

func (s cmdStep) Verify(ctx context.Context, e *Env) error {
	if len(s.CheckCmd) == 0 || s.hyprMissing(e) {
		return nil
	}
	if _, err := e.Runner.Run(ctx, s.cmd(e, s.CheckCmd, s.NeedsRoot && s.CheckCmd[0] != "test")); err != nil {
		return fmt.Errorf("check failed after apply: %w", err)
	}
	return nil
}

func (s cmdStep) Rollback(ctx context.Context, e *Env) error {
	if s.Dest != "" {
		return e.best(ctx, true, "rm", "-f", e.Expand(s.Dest))
	}
	if len(s.UndoCmd) == 0 {
		return nil
	}
	_, err := e.Runner.Run(ctx, s.cmd(e, s.UndoCmd, s.NeedsRoot))
	return err
}

// ---- files (directories) ----

type filesStep struct {
	Base
	Dirs []string
	Mode string
}

func (s filesStep) mode() os.FileMode {
	var m uint32 = 0o755
	if s.Mode != "" {
		fmt.Sscanf(s.Mode, "%o", &m)
	}
	return os.FileMode(m)
}

func (s filesStep) Check(_ context.Context, e *Env) (bool, error) {
	for _, d := range s.Dirs {
		fi, err := os.Stat(e.Expand(d))
		if err != nil || !fi.IsDir() || fi.Mode().Perm() != s.mode() {
			return false, nil
		}
	}
	return len(s.Dirs) > 0, nil
}

func (s filesStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	for _, d := range s.Dirs {
		p := e.Expand(d)
		if _, err := e.FS.Check(p); err != nil {
			return err
		}
		if err := os.MkdirAll(p, s.mode()); err != nil {
			return err
		}
		if err := os.Chmod(p, s.mode()); err != nil {
			return err
		}
	}
	return nil
}

func (s filesStep) Rollback(_ context.Context, e *Env) error {
	for _, d := range s.Dirs {
		os.Remove(e.Expand(d)) // only if empty: user notes are never deleted
	}
	return nil
}

// ---- template (desktop entries etc.) ----

type templateStep struct {
	Base
	From, To string
}

func (s templateStep) render(e *Env, data []byte) []byte {
	return []byte(strings.NewReplacer("@HOME@", e.Home).Replace(string(data)))
}

func (s templateStep) sources(e *Env) ([]string, error) {
	m, err := filepath.Glob(filepath.Join(e.Payload, s.From))
	if err != nil {
		return nil, err
	}
	if len(m) == 0 {
		return nil, fmt.Errorf("no files match %s", s.From)
	}
	sort.Strings(m)
	return m, nil
}

func (s templateStep) Check(_ context.Context, e *Env) (bool, error) {
	src, err := s.sources(e)
	if err != nil {
		return false, nil
	}
	for _, f := range src {
		data, err := os.ReadFile(f)
		if err != nil {
			return false, err
		}
		cur, _ := readIfExists(filepath.Join(e.Expand(s.To), filepath.Base(f)))
		if !bytes.Equal(cur, s.render(e, data)) {
			return false, nil
		}
	}
	return true, nil
}

func (s templateStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	src, err := s.sources(e)
	if err != nil {
		return err
	}
	for _, f := range src {
		data, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if err := e.FS.Write(s.StepID, filepath.Join(e.Expand(s.To), filepath.Base(f)), s.render(e, data), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func (s templateStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback(s.StepID) }

// ---- hypr env (Lua) ----

type hyprEnvStep struct {
	Base
	Env map[string]string
}

func (s hyprEnvStep) names(e *Env) (entry, file, req string) {
	name := "serp_" + strings.ReplaceAll(s.Mod, "-", "_")
	return filepath.Join(e.Home, ".config/hypr/hyprland.lua"), filepath.Join(e.Home, ".config/hypr/config", name+".lua"), fmt.Sprintf("require(%q)", "config/"+name)
}

func (s hyprEnvStep) content() []byte {
	keys := make([]string, 0, len(s.Env))
	for k := range s.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	fmt.Fprintf(&b, "-- generated by serp-installer (module %s)\n", s.Mod)
	for _, k := range keys {
		fmt.Fprintf(&b, "hl.env(%q, %q)\n", k, s.Env[k])
	}
	return []byte(b.String())
}

func (s hyprEnvStep) Check(_ context.Context, e *Env) (bool, error) {
	entry, file, req := s.names(e)
	eb, err := readIfExists(entry)
	if err != nil {
		return false, err
	}
	if eb == nil {
		e.rep().Warn(s.StepID + ": no hyprland.lua, environment variables not written")
		return true, nil
	}
	fb, _ := readIfExists(file)
	return bytes.Equal(fb, s.content()) && bytes.Contains(eb, []byte(req)), nil
}

func (s hyprEnvStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	entry, file, req := s.names(e)
	eb, err := readIfExists(entry)
	if err != nil || eb == nil {
		return err
	}
	if err := e.FS.Write(s.StepID, file, s.content(), 0o644); err != nil {
		return err
	}
	if !bytes.Contains(eb, []byte(req)) {
		// first line: the variables must exist before the rest of the config loads
		return e.FS.Write(s.StepID, entry, append([]byte(req+"\n"), eb...), 0o644)
	}
	return nil
}

func (s hyprEnvStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback(s.StepID) }

// ---- secrets ----

type secretStep struct {
	Base
	Keys []string
}

// NewSecrets builds a step that stores secret answers (config keys) into
// ~/.config/serpantinum/secrets/<name> with mode 600.
func NewSecrets(b Base, keys []string) Step { return secretStep{Base: b, Keys: keys} }

// secretFile finds the target file of a secret config key.
func (e *Env) secretFile(key string) (string, bool) {
	if e.Set == nil {
		return "", false
	}
	for _, m := range e.Set.List {
		for _, c := range m.Config {
			if c.Key == key && c.Kind == "secret" && strings.HasPrefix(c.Store, "secrets/") {
				return filepath.Join(e.ConfigDir(), c.Store), true
			}
		}
	}
	return "", false
}

func (s secretStep) Check(_ context.Context, e *Env) (bool, error) {
	for _, k := range s.Keys {
		v := e.Opts.Secrets[k]
		if v == "" {
			continue // nothing to store: "set later"
		}
		f, ok := e.secretFile(k)
		if !ok {
			return false, fmt.Errorf("unknown secret key %q", k)
		}
		if b, _ := readIfExists(f); string(b) != v+"\n" {
			return false, nil
		}
	}
	return true, nil
}

func (s secretStep) Apply(_ context.Context, e *Env, rep Reporter) error {
	for _, k := range s.Keys {
		f, ok := e.secretFile(k)
		if !ok {
			return fmt.Errorf("unknown secret key %q", k)
		}
		v := e.Opts.Secrets[k]
		if v == "" {
			rep.Log(k + ": not provided, set it later in the shell settings")
			continue
		}
		if err := os.MkdirAll(filepath.Dir(f), 0o700); err != nil {
			return err
		}
		if err := e.FS.Write(s.StepID, f, []byte(v+"\n"), 0o600); err != nil {
			return errors.New("cannot store " + k) // never include the value
		}
	}
	return nil
}

func (s secretStep) Verify(_ context.Context, e *Env) error {
	for _, k := range s.Keys {
		if e.Opts.Secrets[k] == "" {
			continue
		}
		f, _ := e.secretFile(k)
		fi, err := os.Stat(f)
		if err != nil {
			return err
		}
		if fi.Mode().Perm() != 0o600 {
			return fmt.Errorf("%s must have mode 600", f)
		}
	}
	return nil
}

func (s secretStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback(s.StepID) }

// ---- git "download" ----

type gitStep struct {
	Base
	URL, Dest string
}

func (s gitStep) Check(_ context.Context, e *Env) (bool, error) {
	_, err := os.Stat(filepath.Join(e.Expand(s.Dest), ".git"))
	return err == nil, nil
}

func (s gitStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	d := e.Expand(s.Dest)
	if _, err := e.FS.Check(d); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
		if _, err := e.exec(ctx, false, "git", "-C", d, "fetch", "--depth", "1", "origin"); err != nil {
			return err
		}
		_, err := e.exec(ctx, false, "git", "-C", d, "reset", "--hard", "FETCH_HEAD")
		return err
	}
	_, err := e.exec(ctx, false, "git", "clone", "--depth", "1", s.URL, d)
	return err
}

// ---- constructors for the plan skeleton ----

func NewPreflight(b Base) Step                      { return preflightStep{b} }
func NewSudo(b Base) Step                           { return sudoStep{b} }
func NewKeyring(b Base) Step                        { return keyringStep{b} }
func NewSync(b Base) Step                           { return syncStep{b} }
func NewAURHelper(b Base) Step                      { return aurHelperStep{b} }
func NewRepo(b Base, pkgs []string) Step            { return repoStep{Base: b, Pkgs: pkgs} }
func NewAUR(b Base, pkg string) Step                { return aurStep{Base: b, Pkg: pkg} }
func NewBinary(b Base, bin manifest.Binary) Step    { return binaryStep{Base: b, B: bin} }
func NewDeployCode(b Base) Step                     { return deployCodeStep{b} }
func NewDeployConfigs(b Base) Step                  { return deployConfigsStep{b} }
func NewServices(b Base) Step                       { return servicesStep{b} }
func NewRestore(b Base) Step                        { return restoreStep{b} }
func NewVerify(b Base) Step                         { return verifyStep{b} }
func NewFinish(b Base, write func(*Env) error) Step { return finishStep{Base: b, Write: write} }
