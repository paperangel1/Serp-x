package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"serpx/installer/internal/fsx"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/journal"
	"serpx/installer/internal/plan"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
)

// Setup is everything a mode needs. Env must have Home, Payload, StateDir,
// Run, Runner, Set, Version/Commit, Opts (Compositors default to hyprland)
// and optionally DL, Hooks, Rep, Getenv, LookPath, Now, NProc, Rootfs.
type Setup struct {
	Env     *steps.Env
	Cat     *i18n.Catalog
	Decide  func(steps.Step, error) Decision
	Confirm Confirm
	Resume  bool
	Restore bool // add the restore step (install only)
	OnStep  func(i, n int, s steps.Step, ev string)
	// Arm is called with the sudo whitelist of the resolved selection, before
	// any command runs (the caller puts it into its ExecRunner).
	Arm func(w run.Whitelist)
}

func (s *Setup) init(mode steps.Mode) error {
	e := s.Env
	if e == nil || e.Set == nil || e.Runner == nil {
		return errors.New("engine: Env needs Set and Runner")
	}
	e.Mode = mode
	if len(e.Opts.Compositors) == 0 {
		e.Opts.Compositors = []string{"hyprland"}
	}
	if e.Opts.InstallState == "" {
		e.Opts.InstallState = steps.DetectInstallState(e.Home)
	}
	if e.Rep == nil {
		e.Rep = steps.NopReporter{}
	}
	return os.MkdirAll(e.StateDir, 0o700)
}

// attach opens fsx and the journal for the resolved selection.
func (s *Setup) attach(sel *resolve.Selection) (*journal.Journal, error) {
	if err := s.attachFS(sel); err != nil {
		return nil, err
	}
	return journal.Open(s.Env.StateDir, s.Env.Run)
}

func (s *Setup) attachFS(sel *resolve.Selection) error {
	e := s.Env
	e.Sel = sel
	fx, err := fsx.New(fsx.Config{Allowed: e.Allowed(), StateDir: e.StateDir, Run: e.Run})
	if err != nil {
		return err
	}
	e.FS = fx
	if s.Arm != nil {
		s.Arm(e.Whitelist())
	}
	return nil
}

func (s *Setup) engine(j *journal.Journal) *Engine {
	g := &Engine{Env: s.Env, Journal: j, Decide: s.Decide, Resume: s.Resume, OnStep: s.OnStep, Requires: map[string][]string{}}
	for _, m := range s.Env.Set.List {
		g.Requires[m.ID] = m.Requires
	}
	return g
}

func (s *Setup) installedWriter(g **Engine) func(*steps.Env) error {
	return func(e *steps.Env) error {
		skipped := map[string]bool{}
		if *g != nil {
			for _, m := range (*g).Skipped() {
				skipped[m] = true
			}
		}
		var mods []string
		for _, m := range e.Sel.Modules {
			if !skipped[m] {
				mods = append(mods, m)
			}
		}
		return WriteInstalled(e.StateDir, Installed{Build: e.Version, Commit: e.Commit, Compositors: e.Opts.Compositors, Modules: mods}, e.Now2())
	}
}

// resolveModules resolves an explicit module list.
func (s *Setup) resolveModules(explicit []string) (*resolve.Selection, error) {
	return resolve.New(s.Env.Set).Resolve(explicit)
}

// execute builds the plan, writes plan.json and runs it.
func (s *Setup) execute(ctx context.Context, mode steps.Mode, sel *resolve.Selection, only map[string]bool, recheck bool) error {
	j, err := s.attach(sel)
	if err != nil {
		return err
	}
	defer j.Close()
	e := s.Env
	var g *Engine
	list, err := plan.Build(plan.Input{Set: e.Set, Sel: sel, Cat: s.Cat, Opts: e.Opts, Restore: s.Restore, Only: only, WriteInstalled: s.installedWriter(&g)})
	if err != nil {
		return err
	}
	doc := plan.NewDoc(e.Run, mode, e.Version, e.Commit, sel.Modules, e.Opts, list)
	if err := journal.WriteJSON(filepath.Join(e.StateDir, journal.FilePlan), doc); err != nil {
		return err
	}
	g = s.engine(j)
	g.RecheckAll = recheck
	return g.Run(ctx, list)
}

// Install runs the full plan for the given explicit module list.
func Install(ctx context.Context, s *Setup, explicit []string) error {
	if err := s.init(steps.ModeInstall); err != nil {
		return err
	}
	sel, err := s.resolveModules(explicit)
	if err != nil {
		return err
	}
	return s.execute(ctx, steps.ModeInstall, sel, nil, false)
}

// Repair re-checks and verifies every step of the installed modules and
// applies what is broken or missing.
func Repair(ctx context.Context, s *Setup) error {
	return s.again(ctx, steps.ModeRepair, true)
}

// Reconcile brings the installation in line with the (new) manifests:
// missing packages/steps are applied; steps that are already fine are not
// re-verified. Secret questions are never asked.
func Reconcile(ctx context.Context, s *Setup) error {
	return s.again(ctx, steps.ModeReconcile, false)
}

func (s *Setup) again(ctx context.Context, mode steps.Mode, recheck bool) error {
	if err := s.init(mode); err != nil {
		return err
	}
	inst, err := ReadInstalled(s.Env.StateDir)
	if err != nil {
		return err
	}
	if len(inst.Compositors) > 0 {
		s.Env.Opts.Compositors = inst.Compositors
	}
	s.Env.Opts.InstallState = steps.StateCurrent
	sel, err := s.resolveModules(inst.Modules)
	if err != nil {
		return err
	}
	return s.execute(ctx, mode, sel, nil, recheck)
}

// Modules changes the module set: removes what was deselected, installs what
// was added, using installed.toml as the baseline.
func Modules(ctx context.Context, s *Setup, explicit []string) error {
	if err := s.init(steps.ModeModules); err != nil {
		return err
	}
	inst, err := ReadInstalled(s.Env.StateDir)
	if err != nil {
		return err
	}
	if len(inst.Compositors) > 0 {
		s.Env.Opts.Compositors = inst.Compositors
	}
	s.Env.Opts.InstallState = steps.StateCurrent
	target, err := s.resolveModules(explicit)
	if err != nil {
		return err
	}
	have := map[string]bool{}
	for _, m := range inst.Modules {
		have[m] = true
	}
	added := map[string]bool{}
	for _, m := range target.Modules {
		if !have[m] {
			added[m] = true
		}
	}
	var removed []string
	for _, m := range inst.Modules {
		if !target.Has(m) {
			removed = append(removed, m)
		}
	}
	if len(removed) > 0 {
		// reverse of install order (dependents first)
		prev, err := s.resolveModules(inst.Modules)
		if err != nil {
			return err
		}
		if err := s.attachFS(prev); err != nil {
			return err
		}
		rm := map[string]bool{}
		for _, m := range removed {
			rm[m] = true
		}
		var pkgs []string
		for i := len(prev.Modules) - 1; i >= 0; i-- {
			id := prev.Modules[i]
			if !rm[id] {
				continue
			}
			m, _ := s.Env.Set.Get(id)
			if m.Core {
				return resolve.ErrCoreRequired
			}
			p, rerr := removeModule(ctx, s.Env, m)
			if rerr != nil {
				s.Env.Rep.Warn(fmt.Sprintf("removing %s: %v", id, rerr))
			}
			pkgs = append(pkgs, p...)
		}
		pkgs = removablePackages(ctx, s.Env, pkgs)
		if s.Confirm.ask("packages", pkgs) {
			if err := removePackages(ctx, s.Env, pkgs); err != nil {
				return err
			}
		}
	}
	return s.execute(ctx, steps.ModeModules, target, added, false)
}

// UninstallOptions control Uninstall.
type UninstallOptions struct {
	RemoveData     bool // also ~/.config/serpantinum, notes, colour history (needs BackupBefore)
	RemovePackages bool // packages the installer added (asks Confirm("packages"))
	// BackupBefore must create the automatic backup; RemoveData fails without it.
	BackupBefore func(ctx context.Context) error
}

// Uninstall removes the installation (02 section 11). User data stays unless
// RemoveData is set.
func Uninstall(ctx context.Context, s *Setup, o UninstallOptions) error {
	list, sel, err := s.uninstallList(o)
	if err != nil {
		return err
	}
	j, err := s.attach(sel)
	if err != nil {
		return err
	}
	defer j.Close()
	if o.RemoveData && o.BackupBefore == nil {
		return errors.New("engine: removing data requires a backup first")
	}
	g := s.engine(j)
	return g.Run(ctx, list)
}

// PlanUninstall returns the steps Uninstall would run (nothing is executed),
// so the UI can show them before the user confirms.
func PlanUninstall(s *Setup, o UninstallOptions) ([]steps.Step, error) {
	list, _, err := s.uninstallList(o)
	return list, err
}

func (s *Setup) uninstallList(o UninstallOptions) ([]steps.Step, *resolve.Selection, error) {
	if err := s.init(steps.ModeUninstall); err != nil {
		return nil, nil, err
	}
	inst, err := ReadInstalled(s.Env.StateDir)
	if err != nil {
		return nil, nil, err
	}
	if len(inst.Compositors) > 0 {
		s.Env.Opts.Compositors = inst.Compositors
	}
	sel, err := s.resolveModules(inst.Modules)
	if err != nil {
		return nil, nil, err
	}
	e := s.Env
	e.Sel = sel
	var list []steps.Step
	add := func(id string, f func(ctx context.Context) error) {
		list = append(list, &funcStep{Base: steps.Base{StepID: id, Text: titleOf(s.Cat, id), NeedsRoot: false}, f: f})
	}
	if o.RemoveData {
		add("un.backup", func(ctx context.Context) error {
			if o.BackupBefore == nil {
				return errors.New("engine: removing data requires a backup first")
			}
			return o.BackupBefore(ctx)
		})
	}
	for i := len(sel.Modules) - 1; i >= 0; i-- {
		id := sel.Modules[i]
		m, _ := e.Set.Get(id)
		if m.Core {
			continue
		}
		add("un.module."+id, func(ctx context.Context) error {
			_, err := removeModule(ctx, e, m)
			return err
		})
	}
	add("un.links", func(ctx context.Context) error { return removeLinks(ctx, e) })
	add("un.hotkeys", func(ctx context.Context) error { return dropRequireLine(e, hotkeysRequire) })
	add("un.code", func(ctx context.Context) error { return removeCode(e) })
	add("un.state", func(ctx context.Context) error { return removeState(e) })
	if o.RemoveData {
		add("un.data", func(ctx context.Context) error {
			items := dataPaths(e)
			if !s.Confirm.ask("data", items) {
				return nil
			}
			for _, p := range items {
				if err := os.RemoveAll(p); err != nil {
					return err
				}
			}
			return nil
		})
	}
	if o.RemovePackages {
		add("un.packages", func(ctx context.Context) error {
			all := steps.InstalledPackages(e.StateDir)
			var ps []string
			for p := range all {
				ps = append(ps, p)
			}
			sort.Strings(ps)
			ps = removablePackages(ctx, e, ps)
			if !s.Confirm.ask("packages", ps) {
				return nil
			}
			return removePackages(ctx, e, ps)
		})
	}
	add("un.record", func(ctx context.Context) error { return RemoveInstalled(e.StateDir) })
	return list, sel, nil
}

// dataPaths are the user-data locations removed by "delete my data too".
func dataPaths(e *steps.Env) []string {
	notes := "~/Notes"
	if d := e.Opts.Config["tools.notes_dir"]; d != "" {
		notes = d
	}
	var out []string
	for _, p := range []string{e.ConfigDir(), filepath.Join(e.Home, ".local/state/serpantinum"), e.Expand(notes)} {
		if _, err := os.Lstat(p); err == nil {
			out = append(out, p)
		}
	}
	return out
}

func removeLinks(ctx context.Context, e *steps.Env) error {
	for _, n := range []string{"serpantinum", "serpantinumd", "serpantinum-x"} {
		src := filepath.Join(e.TargetBase(), "bin", n)
		l := filepath.Join(e.BinDir(), n)
		if t, err := os.Readlink(l); err == nil && t == src {
			os.Remove(l)
		}
		if n != "serpantinum-x" {
			if t, err := os.Readlink(e.Sys(filepath.Join("/usr/local/bin", n))); err == nil && t == src {
				e.Runner.Run(ctx, cmdOf("rm", true, "-f", filepath.Join("/usr/local/bin", n)))
			}
		}
	}
	return nil
}

// removeCode deletes the files an earlier deploy put into the install dir
// (foreign files stay) and the -x dir.
func removeCode(e *steps.Env) error {
	for rel := range e.DeployedCode() {
		os.Remove(filepath.Join(e.TargetBase(), filepath.FromSlash(rel)))
	}
	pruneDirs(e.TargetBase())
	os.Remove(e.TargetBase())
	os.Remove(filepath.Join(e.StateDir, "deployed-code.txt"))
	return os.RemoveAll(e.TargetBase() + "-x")
}

func removeState(e *steps.Env) error {
	os.Remove(e.VersionFile())
	os.Remove(e.ModulesFile())
	return nil
}

func pruneDirs(root string) {
	var dirs []string
	filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.IsDir() && p != root {
			dirs = append(dirs, p)
		}
		return nil
	})
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, d := range dirs {
		os.Remove(d)
	}
}

// funcStep adapts a function to a one-shot step (uninstall phases).
type funcStep struct {
	steps.Base
	f func(ctx context.Context) error
}

func (s *funcStep) Check(context.Context, *steps.Env) (bool, error) { return false, nil }
func (s *funcStep) Apply(ctx context.Context, _ *steps.Env, _ steps.Reporter) error {
	return s.f(ctx)
}

func titleOf(cat *i18n.Catalog, id string) manifestText {
	if cat == nil {
		return manifestText{RU: id, EN: id}
	}
	key, kv := "uninstall."+strings.ReplaceAll(id, ".", "_"), []string(nil)
	if mod, ok := strings.CutPrefix(id, "un.module."); ok {
		key, kv = "uninstall.un_module", []string{"id", mod}
	}
	return manifestText{RU: cat.T("ru", key, kv...), EN: cat.T("en", key, kv...)}
}
