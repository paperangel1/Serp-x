package steps

import (
	"path/filepath"
	"sort"

	"serpx/installer/internal/run"
)

// Allowed is the fsx allow-list: only these roots may be written (plan 4.5).
func (e *Env) Allowed() []string {
	h := e.Home
	m := map[string]bool{}
	add := func(p string) {
		if p != "" && filepath.IsAbs(p) {
			m[filepath.Clean(p)] = true
		}
	}
	for _, p := range []string{
		e.TargetBase(), e.TargetBase() + "-x", e.BinDir(),
		e.ConfigDir(), filepath.Join(h, ".config/serpantinum-x"),
		filepath.Join(h, ".local/state/serpantinum"),
		filepath.Join(h, ".local/share/fonts"), filepath.Join(h, ".local/share/applications"),
		filepath.Join(h, ".config/systemd/user"), filepath.Join(h, ".config/hypr"),
		e.WallpaperDir(), filepath.Join(h, "Notes"),
	} {
		add(p)
	}
	for _, c := range ExtraConfigs {
		add(filepath.Join(h, ".config", c))
	}
	for _, c := range e.Opts.Compositors {
		add(filepath.Join(h, ".config", compositorDir(c)))
	}
	if e.Set != nil && e.Sel != nil {
		for _, id := range e.Sel.Modules {
			if mm, ok := e.Set.Get(id); ok {
				for _, uf := range mm.UserFiles {
					add(e.Expand(uf))
				}
			}
		}
	}
	if d := e.Opts.Config["tools.notes_dir"]; d != "" {
		add(e.Expand(d))
	}
	out := make([]string, 0, len(m))
	for p := range m {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Whitelist is the sudo whitelist for this plan: root_files of the selected
// modules, binary destinations and the fixed system paths the ported
// upstream steps touch.
func (e *Env) Whitelist() run.Whitelist {
	w := run.Whitelist{
		VPNScript: filepath.Join(e.TargetBase(), "src/scripts/custom/vpn/x_vpn.sh"),
		RootFiles: []string{"/etc/pacman.conf", "/var/lib/pacman/db.lck", "/usr/local/bin/serpantinum", "/usr/local/bin/serpantinumd",
			"/usr/share/fonts/IosevkaNerdFont", "/usr/share/fonts/TTF", "/var/service", "/etc/sddm.conf", "/etc/sddm.conf.d", "/usr/share/sddm/themes"},
		RootGlobs: []string{"/etc/sddm.conf.backup.*"},
		RootTrees: []string{"/usr/share/sddm/themes/material-you", "/usr/share/sddm/themes/matugen-minimal"},
	}
	if e.Set != nil && e.Sel != nil {
		for _, id := range e.Sel.Modules {
			if mm, ok := e.Set.Get(id); ok {
				w.RootFiles = append(w.RootFiles, mm.RootFiles...)
				for _, b := range mm.Binary {
					w.RootFiles = append(w.RootFiles, e.Expand(b.Dest))
				}
			}
		}
	}
	return w
}
