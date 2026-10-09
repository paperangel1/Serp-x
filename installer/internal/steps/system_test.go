package steps_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/steps/stepstest"
)

func TestDetectInit(t *testing.T) {
	f := stepstest.New(t)
	e := f.Env
	if e.DetectInit() != steps.InitSystemd {
		t.Fatal("systemd by /run/systemd/system")
	}
	os.RemoveAll(filepath.Join(e.Rootfs, "run/systemd"))
	f.Bins["systemctl"] = false
	if e.DetectInit() != steps.InitGeneric {
		t.Fatal("generic")
	}
	f.Bins["openrc-init"] = true
	if e.DetectInit() != steps.InitOpenRC {
		t.Fatal("openrc")
	}
	f.Bins["openrc-init"] = false
	os.MkdirAll(filepath.Join(e.Rootfs, "etc/dinit.d"), 0o755)
	if e.DetectInit() != steps.InitDinit {
		t.Fatal("dinit")
	}
	os.RemoveAll(filepath.Join(e.Rootfs, "etc/dinit.d"))
	os.MkdirAll(filepath.Join(e.Rootfs, "run/runit"), 0o755)
	if e.DetectInit() != steps.InitRunit {
		t.Fatal("runit")
	}
	os.RemoveAll(filepath.Join(e.Rootfs, "run/runit"))
	f.Bins["s6-svscan"] = true
	if e.DetectInit() != steps.InitS6 {
		t.Fatal("s6")
	}
}

func TestServicesSystemd(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := steps.NewServices(steps.Base{StepID: "services", Mod: "core"})
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	want := []string{
		"sudo systemctl --global enable pipewire wireplumber pipewire-pulse",
		"systemctl --user start pipewire wireplumber pipewire-pulse",
		"systemctl --user daemon-reload",
		"systemctl --user enable --now easyeffects.service",
		"sudo systemctl enable --now NetworkManager.service",
		"sudo systemctl enable --now power-profiles-daemon.service",
	}
	got := f.Sim.CallsWith("sudo systemctl --global")
	got = append(got, f.Sim.CallsWith("systemctl --user")...)
	got = append(got, f.Sim.CallsWith("sudo systemctl enable")...)
	for _, w := range want {
		found := false
		for _, g := range got {
			if g == w {
				found = true
			}
		}
		if !found {
			t.Errorf("missing %q in %v", w, got)
		}
	}
}

func TestServiceAlternativesAndOtherInits(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	// systemctl enable --now fails -> -f is tried (upstream chain)
	f.Sim.FailOn("systemctl enable --now sddm.service", os.ErrInvalid, 1)
	if err := f.Env.EnableSystemService(ctx, "sddm", steps.InitSystemd); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.HasCall("sudo systemctl enable -f sddm.service") {
		t.Fatalf("%v", f.Sim.Calls())
	}
	// everything failing is tolerated (|| true) with a warning
	f.Sim.FailOn("systemctl", os.ErrInvalid, -1)
	if err := f.Env.EnableSystemService(ctx, "x", steps.InitSystemd); err != nil || len(f.Rep.Warns) == 0 {
		t.Fatalf("err=%v warns=%v", err, f.Rep.Warns)
	}

	g := stepstest.New(t)
	g.Select(t, "core")
	for init, svc := range map[string][]string{
		steps.InitOpenRC: {"sudo rc-update add sddm default", "sudo rc-service sddm start"},
		steps.InitDinit:  {"sudo dinitctl enable sddm"},
		steps.InitS6:     {"sudo s6-rc-bundle-update -b add default sddm"},
	} {
		if err := g.Env.EnableSystemService(ctx, "sddm", init); err != nil {
			t.Fatal(err)
		}
		for _, w := range svc {
			if !g.Sim.HasCall(w) {
				t.Errorf("%s: missing %q in %v", init, w, g.Sim.Calls())
			}
		}
	}
	// runit links only if /etc/sv/<svc> exists
	g.Env.EnableSystemService(ctx, "sddm", steps.InitRunit)
	if g.Sim.HasCall("sudo ln -sf /etc/sv/sddm") {
		t.Fatal("no /etc/sv/sddm yet")
	}
	os.MkdirAll(filepath.Join(g.Env.Rootfs, "etc/sv/sddm"), 0o755)
	g.Env.EnableSystemService(ctx, "sddm", steps.InitRunit)
	if !g.Sim.HasCall("sudo ln -sf /etc/sv/sddm /var/service/sddm") {
		t.Fatalf("%v", g.Sim.Calls())
	}
	g.Env.DisableSystemService(ctx, "sddm", steps.InitSystemd)
	if !g.Sim.HasCall("sudo systemctl disable --now sddm.service") {
		t.Fatal("disable")
	}
}

func TestMigrateLegacy(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	h := f.Env.Home
	f.Env.Opts.InstallState = steps.StateLegacy
	stepstest.Write(t, h, ".local/state/imperative-dots-version", "old", 0o644)
	stepstest.Write(t, h, ".config/hypr/hyprland.conf", "legacy", 0o644)
	f.Sim.Installed["quickshell-git"] = true
	s := stepOf(t, f, "core", "core.pre.migrate")
	check(t, s, f, false)
	apply(t, s, f)
	for _, w := range []string{"pkill -f settings_watcher.sh", "pkill -f hypr/scripts/quickshell"} {
		if !f.Sim.HasCall(w) {
			t.Errorf("missing %s", w)
		}
	}
	bk, _ := filepath.Glob(filepath.Join(h, ".config/hypr_backup/backup_*/hyprland.conf"))
	if len(bk) != 1 {
		t.Fatalf("backup: %v", bk)
	}
	if b, _ := os.ReadFile(filepath.Join(h, ".config/hypr_backup/imperative-dots-version.bak")); string(b) != "old" {
		t.Fatal("legacy marker not moved")
	}
	if exists(filepath.Join(h, ".local/state/imperative-dots-version")) {
		t.Fatal("legacy marker still there")
	}
	if f.Sim.Installed["quickshell-git"] {
		t.Fatal("quickshell-git must be removed")
	}
	// current + not reinstall: nothing to do
	f.Env.Opts.InstallState = steps.StateCurrent
	check(t, s, f, true)
}

func TestCleanupQuickshellGit(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := stepOf(t, f, "core", "core.pre.cleanup")
	check(t, s, f, true)
	f.Sim.Installed["quickshell-git"] = true
	check(t, s, f, false)
	f.Sim.FailOn("yay -R", os.ErrInvalid, -1) // yay fails -> pacman -Rdd
	apply(t, s, f)
	if !f.Sim.HasCall("sudo pacman -Rdd --noconfirm quickshell-git") {
		t.Fatalf("%v", f.Sim.Calls())
	}
	check(t, s, f, true)
}

func TestToolsBootstrap(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	f.Bins["jq"], f.Bins["unzip"] = false, false
	s := stepOf(t, f, "core", "core.pre.tools")
	check(t, s, f, false)
	f.Env.Runner = hookRunner{f.Sim, map[string]func(runCmd){"pacman": func(c runCmd) {
		if c.Root {
			f.Bins["jq"], f.Bins["unzip"] = true, true
			f.Sim.Installed["base-devel"] = true
		}
	}}}
	apply(t, s, f)
	if !f.Sim.HasCall("sudo pacman -Sy --noconfirm --needed jq unzip base-devel") {
		t.Fatalf("%v", f.Sim.Calls())
	}
	check(t, s, f, true)
}

func TestSDDM(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "sddm")
	f.Env.Opts.SDDMWayland = true
	f.Env.Opts.ReplaceDM = true
	f.Sim.Installed["gdm"] = true
	stepstest.Write(t, f.Env.Rootfs, "etc/sddm.conf", "[Old]\n", 0o644)
	stepstest.Write(t, f.Env.Rootfs, "etc/sddm.conf.d/old-matugen.conf", "x", 0o644)
	stepstest.Write(t, f.Env.Rootfs, "etc/sddm.conf.d/keep.conf", "y", 0o644)
	theme := stepOf(t, f, "sddm", "sddm.theme")
	check(t, theme, f, false)
	apply(t, theme, f)
	check(t, theme, f, true)
	conf, _ := os.ReadFile(filepath.Join(f.Env.Rootfs, "etc/sddm.conf.d/10-material-you.conf"))
	if !strings.Contains(string(conf), "DisplayServer=wayland") || !strings.Contains(string(conf), "Current=material-you") {
		t.Fatalf("conf: %s", conf)
	}
	for _, p := range []string{"usr/share/sddm/themes/material-you/Main.qml", "usr/share/sddm/themes/material-you/font/Google.ttf", "usr/share/fonts/TTF/Google.ttf", "etc/sddm.conf.d/keep.conf", "etc/sddm.conf.backup.20261008_120000"} {
		if !exists(filepath.Join(f.Env.Rootfs, p)) {
			t.Errorf("missing %s", p)
		}
	}
	for _, p := range []string{"etc/sddm.conf", "etc/sddm.conf.d/old-matugen.conf"} {
		if exists(filepath.Join(f.Env.Rootfs, p)) {
			t.Errorf("%s should be gone", p)
		}
	}
	if !f.Sim.HasCall("sudo pacman -Rns --noconfirm gdm") || !f.Sim.HasCall("sudo systemctl disable --now gdm.service") {
		t.Errorf("display manager not replaced: %v", f.Sim.Calls())
	}
	en := stepOf(t, f, "sddm", "sddm.enable")
	cycle(t, en, f)
	if err := en.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, en, f, false)
	if err := theme.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, theme, f, false)

	// non-wayland drop-in is plain
	if got := string(steps.SDDMConf(false)); strings.Contains(got, "DisplayServer") || !strings.HasSuffix(got, "InputMethod=\n") {
		t.Fatalf("%s", got)
	}
}

func TestSDDMUpdateKeepsExistingConfAndDM(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "sddm")
	f.Env.Opts.InstallState = steps.StateCurrent
	f.Env.Opts.ReplaceDM = true
	f.Sim.Installed["gdm"] = true
	stepstest.Write(t, f.Env.Rootfs, "etc/sddm.conf", "[Old]\n", 0o644)
	apply(t, stepOf(t, f, "sddm", "sddm.theme"), f)
	if f.Sim.HasCall("sudo pacman -Rns") || !exists(filepath.Join(f.Env.Rootfs, "etc/sddm.conf")) {
		t.Fatal("an update must not remove display managers or /etc/sddm.conf")
	}
}

func TestFonts(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	var b strings.Builder
	_ = b
	archive := zipMany(t, map[string]string{"IosevkaNerdFont-Regular.ttf": "R", "IosevkaNerdFontMono-Regular.ttf": "M", "sub/Other.ttf": "X", "README.md": "r"})
	f.DL.Files[steps.FontsURL] = archive
	s := stepOf(t, f, "core", "core.fonts")
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	dir := filepath.Join(f.Env.Home, ".local/share/fonts/IosevkaNerdFont")
	if !exists(filepath.Join(dir, "IosevkaNerdFont-Regular.ttf")) || exists(filepath.Join(dir, "IosevkaNerdFontMono-Regular.ttf")) || exists(filepath.Join(dir, "Other.ttf")) {
		t.Fatalf("fonts dir: %v", stepstest.Tree(t, dir))
	}
	if !exists(filepath.Join(f.Env.Rootfs, "usr/share/fonts/IosevkaNerdFont/IosevkaNerdFont-Regular.ttf")) {
		t.Fatal("system copy missing")
	}
	if !f.Sim.HasCall("fc-cache -f " + filepath.Join(f.Env.Home, ".local/share/fonts")) {
		t.Fatal("fc-cache not run")
	}
	if exists(filepath.Join(f.Env.Home, ".cache/serpantinum-fonts")) {
		t.Fatal("font cache not cleaned")
	}
}

func TestFontsDownloadFailureOnlyWarns(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	f.DL.Err[steps.FontsURL] = os.ErrDeadlineExceeded
	s := stepOf(t, f, "core", "core.fonts")
	if err := s.Apply(ctx, f.Env, f.Rep); err != nil {
		t.Fatalf("upstream skips fonts on download failure: %v", err)
	}
	if len(f.DL.Log) != 3 {
		t.Fatalf("expected 3 attempts, got %d", len(f.DL.Log))
	}
	if len(f.Rep.Warns) == 0 {
		t.Fatal("no warning")
	}
}

func TestWallpapers(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "wallpapers")
	clone := filepath.Join(f.Env.Home, ".cache/serpantinum-wallpapers")
	for i, n := range []string{"a.jpg", "b.PNG", "c.webp", "d.txt", "e.gif"} {
		stepstest.Write(t, clone, "images/"+n, strings.Repeat("x", i+1), 0o644)
	}
	os.MkdirAll(filepath.Join(clone, ".git"), 0o755)
	dest := filepath.Join(f.Env.Home, "Pictures/Wallpapers")
	stepstest.Write(t, dest, "a.jpg", "mine", 0o644) // same name, other content: saved first

	s := stepOf(t, f, "wallpapers", "wallpapers.clone")
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	if !f.Sim.HasCall("git -C "+clone+" fetch --depth 1 origin") || !f.Sim.HasCall("git -C "+clone+" reset --hard FETCH_HEAD") {
		t.Fatalf("%v", f.Sim.Calls())
	}
	if exists(filepath.Join(dest, "d.txt")) || !exists(filepath.Join(dest, "e.gif")) || !exists(filepath.Join(dest, "b.PNG")) {
		t.Fatalf("copied: %v", stepstest.Tree(t, dest))
	}
	var saved bool
	for _, c := range f.Env.FS.Changes() {
		if strings.HasSuffix(c.Path, "a.jpg") && c.Backup != "" {
			if b, _ := os.ReadFile(c.Backup); string(b) == "mine" {
				saved = true
			}
		}
	}
	if !saved {
		t.Fatal("the user's a.jpg was overwritten without a copy")
	}
	if err := s.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "a.jpg")); string(b) != "mine" || exists(filepath.Join(dest, "e.gif")) {
		t.Fatalf("rollback: %v", stepstest.Tree(t, dest))
	}
}

func TestWallpaperSampleOnlyWhenEmpty(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	clone := filepath.Join(f.Env.Home, ".cache/serpantinum-wallpapers")
	for _, n := range []string{"1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"} {
		stepstest.Write(t, clone, n, n, 0o644)
	}
	os.MkdirAll(filepath.Join(clone, ".git"), 0o755)
	s := stepOf(t, f, "core", "core.wallpapers")
	apply(t, s, f)
	dest := filepath.Join(f.Env.Home, "Pictures/Wallpapers")
	if n := len(stepstest.Tree(t, dest)); n != 3 {
		t.Fatalf("want 3 random pictures, got %d", n)
	}
	before := stepstest.Tree(t, dest)
	apply(t, s, f)
	if strings.Join(before, ",") != strings.Join(stepstest.Tree(t, dest), ",") {
		t.Fatal("a folder that already has pictures must be left alone")
	}
}

func TestWallpaperCloneFailureIsTolerated(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	f.Sim.FailOn("git clone", os.ErrInvalid, -1)
	s := stepOf(t, f, "core", "core.wallpapers")
	if err := s.Apply(ctx, f.Env, f.Rep); err != nil {
		t.Fatalf("upstream ignores a failed wallpaper clone: %v", err)
	}
}

var _ = manifest.Text{}
