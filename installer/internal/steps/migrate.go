package steps

import (
	"context"
	"os"
	"path/filepath"
)

// backupCompositorDir is upstream backup_compositor_directory.
func (e *Env) backupCompositorDir(comp string) error {
	name := compositorDir(comp)
	dir := filepath.Join(e.Home, ".config", name)
	if !nonEmptyDir(dir) {
		return nil
	}
	dst := filepath.Join(e.Home, ".config", name+"_backup", "backup_"+e.now().Format("20060102_150405"))
	if _, err := os.Stat(dst); err == nil {
		return nil // already saved in this second
	}
	return copyDirAll(dir, dst)
}

type migrateStep struct{ Base }

func (migrateStep) work(e *Env) bool {
	if e.Mode == ModeRepair || e.Mode == ModeReconcile {
		return false
	}
	switch {
	case e.Opts.InstallState == StateLegacy:
		return true
	case e.Opts.InstallState == StateFresh || e.Opts.Reinstall:
		for _, c := range e.Opts.Compositors {
			if nonEmptyDir(filepath.Join(e.Home, ".config", compositorDir(c))) {
				return true
			}
		}
	}
	return false
}

func (s migrateStep) Check(_ context.Context, e *Env) (bool, error) { return !s.work(e), nil }

// Apply is upstream install.sh: migrate_legacy for a legacy install,
// backup_compositors for a fresh install or a reinstall.
func (s migrateStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	if e.Opts.InstallState == StateLegacy {
		e.ok(ctx, "pkill", "-f", "settings_watcher.sh")
		e.ok(ctx, "pkill", "-f", "hypr/scripts/quickshell")
		if err := removeQuickshellGit(ctx, e); err != nil {
			return err
		}
	}
	for _, c := range e.Opts.Compositors {
		if err := e.backupCompositorDir(c); err != nil {
			return err // upstream ignored cp errors; we stop before anything is replaced
		}
	}
	if e.Opts.InstallState == StateLegacy {
		marker := filepath.Join(e.Home, ".local/state/imperative-dots-version")
		if _, err := os.Stat(marker); err == nil {
			bdir := filepath.Join(e.Home, ".config/hypr_backup")
			if err := os.MkdirAll(bdir, 0o755); err != nil {
				return err
			}
			os.Rename(marker, filepath.Join(bdir, "imperative-dots-version.bak"))
		}
	}
	return nil
}
