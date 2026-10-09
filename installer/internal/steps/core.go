package steps

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ---- core.state: version file, module flags, first-launch markers ----

type stateStep struct{ Base }

func (s stateStep) desired(e *Env) (ver, mods []byte) {
	fork := e.Commit
	if fork == "" {
		fork = "serp-x"
	}
	ver = FormatVersionFile(VersionInfo{Version: e.Version, Commit: e.Commit, Compositors: strings.Join(e.Opts.Compositors, " "), ForkCommit: fork})
	return ver, e.modulesJSON()
}

func (s stateStep) Check(_ context.Context, e *Env) (bool, error) {
	ver, mods := s.desired(e)
	a, _ := readIfExists(e.VersionFile())
	b, _ := readIfExists(e.ModulesFile())
	return bytes.Equal(a, ver) && bytes.Equal(b, mods), nil
}

// Apply is write_version_state (atomic) plus the serp-x module flags and the
// removal of first_launch.done after a fresh/legacy install or reinstall.
func (s stateStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	ver, mods := s.desired(e)
	if err := e.FS.Write("core.state", e.VersionFile(), ver, 0o644); err != nil {
		return err
	}
	if err := e.FS.Write("core.state", e.ModulesFile(), mods, 0o644); err != nil {
		return err
	}
	if e.Opts.InstallState == StateLegacy || e.Opts.InstallState == StateFresh || e.Opts.Reinstall {
		os.Remove(filepath.Join(e.Home, ".local/state/serpantinum/first_launch.done"))
		os.Remove(filepath.Join(e.Home, ".local/state/quickshell/first_launch.done"))
	}
	return nil
}

func (s stateStep) Verify(ctx context.Context, e *Env) error {
	ok, _ := s.Check(ctx, e)
	if !ok {
		return errors.New("version/module state files do not match")
	}
	return nil
}

func (stateStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback("core.state") }

// ---- links ----

type linkStep struct {
	Base
	Names     []string
	Dir       string
	System    []string
	SystemDir string
}

func (s linkStep) Check(_ context.Context, e *Env) (bool, error) {
	for _, n := range s.Names {
		src := filepath.Join(e.TargetBase(), "bin", n)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if t, err := os.Readlink(filepath.Join(e.Expand(s.Dir), n)); err != nil || t != src {
			return false, nil
		}
	}
	for _, n := range s.System {
		src := filepath.Join(e.TargetBase(), "bin", n)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if t, err := os.Readlink(e.Sys(filepath.Join(s.SystemDir, n))); err != nil || t != src {
			return false, nil
		}
	}
	return true, nil
}

func (s linkStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	dir := e.Expand(s.Dir)
	for _, n := range s.Names {
		src := filepath.Join(e.TargetBase(), "bin", n)
		if _, err := os.Stat(src); err != nil {
			continue // upstream links only what exists
		}
		if err := e.FS.Symlink("core.links", filepath.Join(dir, n), src); err != nil {
			return err
		}
	}
	for _, n := range s.System {
		src := filepath.Join(e.TargetBase(), "bin", n)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := e.best(ctx, true, "ln", "-sf", src, filepath.Join(s.SystemDir, n)); err != nil {
			return err
		}
	}
	return nil
}

func (s linkStep) Verify(ctx context.Context, e *Env) error {
	dir := e.Expand(s.Dir)
	for _, n := range s.Names {
		if _, err := os.Stat(filepath.Join(e.TargetBase(), "bin", n)); err != nil {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			return fmt.Errorf("link %s is broken", filepath.Join(dir, n))
		}
	}
	return nil
}

func (s linkStep) Rollback(ctx context.Context, e *Env) error {
	for _, n := range s.System {
		src := filepath.Join(e.TargetBase(), "bin", n)
		if t, err := os.Readlink(e.Sys(filepath.Join(s.SystemDir, n))); err == nil && t == src {
			e.best(ctx, true, "rm", "-f", filepath.Join(s.SystemDir, n))
		}
	}
	return e.FS.Rollback("core.links")
}

// ---- skeleton steps without a manifest ----

type preflightStep struct{ Base }

func (preflightStep) Check(context.Context, *Env) (bool, error) { return false, nil }
func (preflightStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	if e.Hooks.Preflight == nil {
		return nil
	}
	return e.Hooks.Preflight(ctx)
}

// sudoStep verifies that sudo works without a prompt (the UI obtains the
// ticket before the plan starts; keep-alive then refreshes it).
type sudoStep struct{ Base }

func (sudoStep) Check(ctx context.Context, e *Env) (bool, error) {
	return e.ok(ctx, "sudo", "-n", "-v"), nil
}
func (sudoStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	if _, err := e.exec(ctx, false, "sudo", "-n", "-v"); err != nil {
		return errors.New("sudo needs a password: run `sudo -v` first")
	}
	return nil
}

type restoreStep struct{ Base }

func (restoreStep) Check(context.Context, *Env) (bool, error) { return false, nil }
func (restoreStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	if e.Hooks.Restore == nil {
		return errors.New("restore is not available in this build (backup import arrives with the backup package)")
	}
	return e.Hooks.Restore(ctx)
}

// verifyStep is the final check: the shell is deployed and callable.
type verifyStep struct{ Base }

func (verifyStep) Check(context.Context, *Env) (bool, error) { return false, nil }
func (verifyStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	for _, p := range []string{filepath.Join(e.TargetBase(), "src"), e.VersionFile()} {
		if _, err := os.Stat(p); err != nil {
			return fmt.Errorf("missing after install: %s", p)
		}
	}
	if _, err := os.Stat(filepath.Join(e.TargetBase(), "bin")); err != nil {
		return fmt.Errorf("missing after install: %s", filepath.Join(e.TargetBase(), "bin"))
	}
	return nil
}

// finishStep writes installed.toml (see state package function in engine).
type finishStep struct {
	Base
	Write func(e *Env) error
}

func (finishStep) Check(context.Context, *Env) (bool, error) { return false, nil }
func (s finishStep) Apply(_ context.Context, e *Env, _ Reporter) error {
	if s.Write == nil {
		return nil
	}
	return s.Write(e)
}
