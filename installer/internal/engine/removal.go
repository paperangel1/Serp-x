package engine

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/pacman"
	"serpx/installer/internal/steps"
)

// Confirm asks the user before something irreversible. kind is "packages" or
// "data"; items is what would be removed. nil Confirm answers no.
type Confirm func(kind string, items []string) bool

func (c Confirm) ask(kind string, items []string) bool {
	return c != nil && len(items) > 0 && c(kind, items)
}

// keepData reports whether path is listed in the module's uninstall.keep_data
// (or lies inside such a path).
func keepData(e *steps.Env, m *manifest.Manifest, p string) bool {
	for _, k := range m.Uninstall.KeepData {
		kp := e.Expand(k)
		if p == kp || strings.HasPrefix(p, kp+"/") {
			return true
		}
	}
	return false
}

const hotkeysRequire = `config/user_keybinds`

// removeModule undoes one module using its manifest: undo commands (newest
// step first), systemd units, binaries, files that are ours, root files,
// hyprland hooks. Data listed in uninstall.keep_data stays. Packages are
// returned for the caller (they need a confirmation).
func removeModule(ctx context.Context, e *steps.Env, m *manifest.Manifest) (pkgs []string, err error) {
	var list []steps.Step
	for _, st := range m.Steps {
		s, ferr := steps.FromManifest(m, st)
		if ferr != nil {
			continue // not buildable here: nothing to undo for it
		}
		list = append(list, s)
	}
	for i := len(list) - 1; i >= 0; i-- {
		if rerr := list[i].Rollback(ctx, e); rerr != nil && err == nil {
			err = rerr
		}
	}
	for _, u := range m.SystemdUser {
		e.Runner.Run(ctx, cmdOf("systemctl", false, "--user", "disable", "--now", u))
	}
	for _, u := range m.SystemdSys {
		e.DisableSystemService(ctx, strings.TrimSuffix(u, ".service"), e.DetectInit())
	}
	for _, b := range m.Binary {
		steps.NewBinary(steps.Base{StepID: "binary." + b.Name, Mod: m.ID}, b).Rollback(ctx, e)
	}
	owned := e.FS.Owned()
	for _, uf := range m.UserFiles {
		p := e.Expand(uf)
		// ~/.config/serpantinum is the user's data (settings, secrets, commands):
		// only "delete my data too" removes it.
		if keepData(e, m, p) || !owned[p] || p == e.ConfigDir() || strings.HasPrefix(p, e.ConfigDir()+"/") {
			continue
		}
		if fi, serr := os.Lstat(p); serr == nil && !fi.IsDir() {
			if rerr := e.FS.Remove("uninstall."+m.ID, p); rerr != nil && err == nil {
				err = rerr
			}
		}
	}
	for _, rf := range m.RootFiles {
		// Not readable (e.g. /etc/polkit-1/rules.d is root-only) is not "absent": rm -f is idempotent.
		fi, serr := os.Stat(e.Sys(rf))
		if serr == nil && fi.IsDir() || serr != nil && errors.Is(serr, os.ErrNotExist) {
			continue
		}
		e.Runner.Run(ctx, cmdOf("rm", true, "-f", rf))
		// a directory that only held our file goes too (rmdir fails, harmlessly, if it has other content)
		if d := filepath.Dir(rf); strings.HasPrefix(filepath.Base(d), "serpantinum") || strings.HasPrefix(filepath.Base(d), "serp-") {
			e.Runner.Run(ctx, cmdOf("rmdir", true, d))
		}
	}
	for _, st := range m.Steps {
		if _, ok := st.Args["env"]; ok && st.Kind == "hypr" {
			name := "serp_" + strings.ReplaceAll(m.ID, "-", "_")
			if rerr := dropRequireLine(e, "config/"+name); rerr != nil && err == nil {
				err = rerr
			}
			os.Remove(filepath.Join(e.Home, ".config/hypr/config", name+".lua"))
		}
	}
	if m.ID == "hotkeys" {
		if rerr := dropRequireLine(e, hotkeysRequire); rerr != nil && err == nil {
			err = rerr
		}
		p := filepath.Join(e.Home, ".config/hypr/config/user_keybinds.lua")
		if _, serr := os.Lstat(p); serr == nil {
			os.Remove(p)
		}
		os.Remove(filepath.Join(e.Home, ".config/hypr/hyprland.lua.serpantinum.bak"))
	}
	for pkg, owner := range steps.InstalledPackages(e.StateDir) {
		if owner == m.ID {
			pkgs = append(pkgs, pkg)
		}
	}
	sort.Strings(pkgs)
	return pkgs, err
}

// dropRequireLine removes the lines of hyprland.lua that contain marker.
func dropRequireLine(e *steps.Env, marker string) error {
	p := filepath.Join(e.Home, ".config/hypr/hyprland.lua")
	b, err := os.ReadFile(p)
	if err != nil {
		return nil
	}
	var keep []string
	changed := false
	for _, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, marker) {
			changed = true
			continue
		}
		keep = append(keep, l)
	}
	if !changed {
		return nil
	}
	return e.FS.Write("uninstall", p, []byte(strings.Join(keep, "\n")), 0o644)
}

// removablePackages filters pkgs to those nothing outside the set requires.
func removablePackages(ctx context.Context, e *steps.Env, pkgs []string) []string {
	set := pacman.Set(pkgs)
	var out []string
	for _, p := range pkgs {
		if !e.OKQuiet(ctx, "pacman", "-Qq", p) {
			continue // already gone
		}
		qi, _ := e.Out(ctx, "pacman", "-Qi", p)
		ok := true
		for _, r := range pacman.RequiredBy(qi) {
			if !set[r] {
				ok = false
			}
		}
		if ok {
			out = append(out, p)
		}
	}
	return out
}

// removePackages removes pkgs (already confirmed) and forgets them in installed-packages.txt.
func removePackages(ctx context.Context, e *steps.Env, pkgs []string) error {
	if len(pkgs) == 0 {
		return nil
	}
	if _, err := e.Runner.Run(ctx, cmdOf("pacman", true, append([]string{"-R", "--noconfirm"}, pkgs...)...)); err != nil {
		return err
	}
	return forgetPackages(e, pkgs)
}

func forgetPackages(e *steps.Env, gone []string) error {
	g := pacman.Set(gone)
	all := steps.InstalledPackages(e.StateDir)
	var lines []string
	for p, m := range all {
		if !g[p] {
			lines = append(lines, p+"\t"+m)
		}
	}
	sort.Strings(lines)
	var buf bytes.Buffer
	for _, l := range lines {
		buf.WriteString(l + "\n")
	}
	return os.WriteFile(filepath.Join(e.StateDir, "installed-packages.txt"), buf.Bytes(), 0o600)
}
