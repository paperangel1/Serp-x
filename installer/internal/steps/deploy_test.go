package steps_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"serpx/installer/internal/steps"
	"serpx/installer/internal/steps/stepstest"
)

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestDeployCodeMirrorKeepsForeignFiles(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	base := f.Env.TargetBase()
	// a foreign file the user keeps inside the install dir
	stepstest.Write(t, base, "src/my-notes.txt", "mine", 0o644)
	stepstest.Write(t, base, "local-plugin/x.lua", "mine too", 0o644)
	// a foreign file that collides with a shipped one
	stepstest.Write(t, base, "src/scripts/foo.sh", "user edited", 0o644)

	s := steps.NewDeployCode(steps.Base{StepID: "deploy.code", Mod: "core"})
	cycle(t, s, f)

	for _, p := range []string{"bin/serpantinum", "bin/serpantinumd", "src/scripts/foo.sh", "src/scripts/custom/vpn/x_vpn.sh", "src/assets/languages/en.json"} {
		if !exists(filepath.Join(base, p)) {
			t.Errorf("missing %s", p)
		}
	}
	if exists(filepath.Join(base, "src/scripts/__pycache__")) {
		t.Error("__pycache__ must not be deployed")
	}
	if b, _ := os.ReadFile(filepath.Join(base, "src/my-notes.txt")); string(b) != "mine" {
		t.Error("foreign file inside src/ was removed")
	}
	if !exists(filepath.Join(base, "local-plugin/x.lua")) {
		t.Error("foreign directory was removed")
	}
	fi, _ := os.Stat(filepath.Join(base, "bin/serpantinum"))
	if fi.Mode().Perm()&0o111 == 0 {
		t.Error("bin/* must be executable")
	}
	if fi, _ := os.Stat(filepath.Join(base, "src/scripts/foo.sh")); fi.Mode().Perm()&0o111 == 0 {
		t.Error("scripts/*.sh must be executable")
	}
	// the colliding file was saved by fsx before being replaced
	var saved bool
	for _, c := range f.Env.FS.Changes() {
		if strings.HasSuffix(c.Path, "src/scripts/foo.sh") && c.Backup != "" {
			if b, _ := os.ReadFile(c.Backup); string(b) == "user edited" {
				saved = true
			}
		}
	}
	if !saved {
		t.Error("foreign colliding file was not backed up")
	}

	// the payload drops a file: only files WE deployed are removed
	os.Remove(filepath.Join(f.Env.Payload, "src/scripts/foo.sh"))
	check(t, s, f, false)
	apply(t, s, f)
	if exists(filepath.Join(base, "src/scripts/foo.sh")) {
		t.Error("stale deployed file should be removed")
	}
	if !exists(filepath.Join(base, "src/my-notes.txt")) {
		t.Error("foreign file must survive a mirror")
	}
}

func TestDeployConfigs(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "hotkeys")
	h := f.Env.Home
	// existing user config: backed up as upstream does, foreign files pruned, module files kept
	stepstest.Write(t, h, ".config/hypr/hyprland.conf", "old conf", 0o644)
	stepstest.Write(t, h, ".config/hypr/config/user_keybinds.lua", "mine", 0o644)
	stepstest.Write(t, h, ".config/kitty/kitty.conf", "my kitty", 0o644)

	s := steps.NewDeployConfigs(steps.Base{StepID: "deploy.configs", Mod: "core"})
	// hotkeys' user_keybinds.lua is a module file: protected from pruning
	apply(t, s, f)
	if b, _ := os.ReadFile(filepath.Join(h, ".config/hypr/hyprland.lua")); !strings.Contains(string(b), "config/variables") {
		t.Fatalf("hyprland.lua: %s", b)
	}
	if exists(filepath.Join(h, ".config/hypr/hyprland.conf")) {
		t.Error("upstream behaviour: files not in the source are removed from the compositor dir")
	}
	if b, _ := os.ReadFile(filepath.Join(h, ".config/hypr/config/user_keybinds.lua")); string(b) != "mine" {
		t.Error("module-owned user_keybinds.lua must survive")
	}
	bk, _ := filepath.Glob(filepath.Join(h, ".config/hypr_backup/backup_*/hyprland.conf"))
	if len(bk) != 1 {
		t.Fatalf("hypr backup missing: %v", bk)
	}
	if b, _ := os.ReadFile(filepath.Join(h, ".config/kitty/kitty.conf")); string(b) != "font_size 12\n" {
		t.Error("kitty config not deployed")
	}
	var kittySaved bool
	for _, c := range f.Env.FS.Changes() {
		if strings.HasSuffix(c.Path, "kitty/kitty.conf") && c.Backup != "" {
			kittySaved = true
		}
	}
	if !kittySaved {
		t.Error("foreign kitty.conf was overwritten without a copy")
	}
	check(t, s, f, true)

	// update (state current): nothing is touched
	f.Env.Opts.InstallState = steps.StateCurrent
	os.WriteFile(filepath.Join(h, ".config/kitty/kitty.conf"), []byte("customised"), 0o644)
	check(t, s, f, true)
	apply(t, s, f)
	if b, _ := os.ReadFile(filepath.Join(h, ".config/kitty/kitty.conf")); string(b) != "customised" {
		t.Error("update must not overwrite configs")
	}

	// repair restores only what is missing
	f.Env.Mode = steps.ModeRepair
	os.Remove(filepath.Join(h, ".config/cava/config"))
	check(t, s, f, false)
	apply(t, s, f)
	if !exists(filepath.Join(h, ".config/cava/config")) {
		t.Error("repair did not restore the missing file")
	}
	if b, _ := os.ReadFile(filepath.Join(h, ".config/kitty/kitty.conf")); string(b) != "customised" {
		t.Error("repair overwrote a customised file")
	}
}

func TestBuildSettings(t *testing.T) {
	tmpl := []byte(`{"general":{"language":"en","theme":"dark"},"bar":{"height":30},"big":12345678901234567890}`)
	cases := []struct {
		name, existing, wp, lang string
		want                     map[string]string // json path substrings
	}{
		{"fresh", "", "/p/Wallpapers", "ru", map[string]string{`"language": "ru"`: "", `"wallpaperDir": "/p/Wallpapers"`: "", `"theme": "dark"`: "", "12345678901234567890": ""}},
		{"existing keeps user values and language", `{"general":{"language":"de"},"bar":{"height":44}}`, "/p/W", "ru",
			map[string]string{`"language": "de"`: "", `"height": 44`: "", `"theme": "dark"`: "", `"wallpaperDir": "/p/W"`: ""}},
		{"existing without language gets one", `{"bar":{"height":44}}`, "", "ru", map[string]string{`"language": "ru"`: "", `"height": 44`: ""}},
	}
	for _, c := range cases {
		out, err := steps.BuildSettings(tmpl, []byte(c.existing), c.wp, c.lang)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		for want := range c.want {
			if !strings.Contains(string(out), want) {
				t.Errorf("%s: %q missing in\n%s", c.name, want, out)
			}
		}
	}
	if out, _ := steps.BuildSettings(tmpl, nil, "", "en"); strings.Contains(string(out), "wallpaperDir") {
		t.Error("empty wallpaper dir must not be written")
	}
	if _, err := steps.BuildSettings(tmpl, []byte(`{broken`), "", "en"); err == nil {
		t.Error("broken existing settings must be an error (file left untouched)")
	}
}

func TestConfigStep(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := stepOf(t, f, "core", "core.config")
	check(t, s, f, false)
	apply(t, s, f)
	b, err := os.ReadFile(filepath.Join(f.Env.Home, ".config/serpantinum/settings.json"))
	if err != nil || !strings.Contains(string(b), `"language": "ru"`) {
		t.Fatalf("%v\n%s", err, b)
	}
	if !strings.Contains(string(b), "Pictures/Wallpapers") {
		t.Fatalf("wallpaperDir missing:\n%s", b)
	}
	if !f.Sim.HasCall("bash " + filepath.Join(f.Env.Payload, "src/scripts/location.sh") + " --refresh") {
		t.Errorf("location refresh missing: %v", f.Sim.Calls())
	}
	// broken user file is left alone
	os.WriteFile(filepath.Join(f.Env.Home, ".config/serpantinum/settings.json"), []byte("{broken"), 0o644)
	apply(t, stepOf(t, f, "core", "core.config"), f) // Verify fails on broken JSON -> apply helper would fatal
}

func TestUserDirsWallpaperDir(t *testing.T) {
	f := stepstest.New(t)
	if got := f.Env.WallpaperDir(); got != filepath.Join(f.Env.Home, "Pictures/Wallpapers") {
		t.Fatal(got)
	}
	stepstest.Write(t, f.Env.Home, ".config/user-dirs.dirs", "XDG_PICTURES_DIR=\"$HOME/Bilder/\"\n", 0o644)
	if got := f.Env.WallpaperDir(); got != filepath.Join(f.Env.Home, "Bilder/Wallpapers") {
		t.Fatal(got)
	}
	stepstest.Write(t, f.Env.Home, ".config/user-dirs.dirs", "XDG_PICTURES_DIR=\"$HOME\"\n", 0o644)
	if got := f.Env.WallpaperDir(); got != filepath.Join(f.Env.Home, "Pictures/Wallpapers") {
		t.Fatal(got)
	}
}

func TestDetectSystemLanguage(t *testing.T) {
	f := stepstest.New(t)
	for env, want := range map[string]string{"ru_RU.UTF-8": "ru", "en_US.UTF-8": "en", "de_DE": "en" /* no de.json in the fixture */, "": "en"} {
		env := env
		f.Env.Getenv = func(k string) string {
			if k == "LANG" {
				return env
			}
			return ""
		}
		if got := f.Env.DetectSystemLanguage(); got != want {
			t.Errorf("%q: %s want %s", env, got, want)
		}
	}
}
