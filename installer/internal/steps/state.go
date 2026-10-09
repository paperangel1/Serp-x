package steps

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// DetectInstallState is upstream state.sh detect_install_state.
func DetectInstallState(home string) string {
	exists := func(p string) bool { _, err := os.Stat(filepath.Join(home, p)); return err == nil }
	switch {
	case exists(".local/state/serpantinum/version"):
		return StateCurrent
	case exists(".local/state/imperative-dots-version"),
		exists(".config/hypr/scripts/settings_watcher.sh"),
		exists(".config/hypr/settings.json"):
		return StateLegacy
	}
	return StateFresh
}

// VersionInfo is the content of ~/.local/state/serpantinum/version.
type VersionInfo struct {
	Version, Commit, Compositors string
	ForkCommit                   string // set by this installer; marks a serp-x build
}

// ParseVersionFile reads KEY="value" lines (upstream write_version_state).
func ParseVersionFile(data []byte) VersionInfo {
	var v VersionInfo
	sc := bufio.NewScanner(strings.NewReader(string(data)))
	for sc.Scan() {
		k, val, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		val = strings.Trim(val, `"`)
		switch k {
		case "SERPANTINUM_VERSION":
			v.Version = val
		case "SERPANTINUM_COMMIT":
			v.Commit = val
		case "SELECTED_COMPOSITORS":
			v.Compositors = val
		case "SERPANTINUM_FORK_COMMIT":
			v.ForkCommit = val
		}
	}
	return v
}

// FormatVersionFile renders the file exactly like upstream, plus the fork marker.
func FormatVersionFile(v VersionInfo) []byte {
	if v.Version == "" {
		v.Version = "2.0.0"
	}
	if v.Commit == "" || v.Commit == "null" {
		v.Commit = "unknown"
	}
	s := fmt.Sprintf("SERPANTINUM_VERSION=%q\nSERPANTINUM_COMMIT=%q\nSELECTED_COMPOSITORS=%q\n", v.Version, v.Commit, v.Compositors)
	if v.ForkCommit != "" {
		s += fmt.Sprintf("SERPANTINUM_FORK_COMMIT=%q\n", v.ForkCommit)
	}
	return []byte(s)
}

// ModulesFile is ~/.config/serpantinum-x/modules.json.
func (e *Env) ModulesFile() string {
	return filepath.Join(e.Home, ".config/serpantinum-x/modules.json")
}

func (e *Env) modulesJSON() []byte {
	enabled := []string{}
	if e.Sel != nil {
		enabled = append(enabled, e.Sel.Modules...)
	}
	b, _ := json.MarshalIndent(map[string]any{"enabled": enabled}, "", "  ")
	return append(b, '\n')
}

// WallpaperDir is upstream get_wallpaper_dir. (`xdg-user-dir PICTURES` reads
// the same user-dirs.dirs, so it is not run separately.)
func (e *Env) WallpaperDir() string {
	pics := ""
	if b, err := os.ReadFile(filepath.Join(e.Home, ".config/user-dirs.dirs")); err == nil {
		sc := bufio.NewScanner(strings.NewReader(string(b)))
		for sc.Scan() {
			if l := sc.Text(); strings.HasPrefix(l, "XDG_PICTURES_DIR") {
				_, v, _ := strings.Cut(l, "=")
				pics = strings.ReplaceAll(strings.ReplaceAll(v, `"`, ""), "$HOME", e.Home)
				break
			}
		}
	}
	if pics == "" || pics == e.Home {
		pics = filepath.Join(e.Home, "Pictures")
	}
	return filepath.Join(strings.TrimRight(pics, "/"), "Wallpapers")
}
