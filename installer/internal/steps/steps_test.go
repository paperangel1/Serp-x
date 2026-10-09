package steps_test

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/steps/stepstest"
)

var ctx = context.Background()

type runCmd = run.Cmd

func mod(t *testing.T, f *stepstest.Fixture, id string) *manifest.Manifest {
	t.Helper()
	m, ok := f.Env.Set.Get(id)
	if !ok {
		t.Fatalf("no module %s", id)
	}
	return m
}

func stepOf(t *testing.T, f *stepstest.Fixture, modID, stepID string) steps.Step {
	t.Helper()
	m := mod(t, f, modID)
	for _, st := range m.Steps {
		if st.ID == stepID {
			s, err := steps.FromManifest(m, st)
			if err != nil {
				t.Fatal(err)
			}
			return s
		}
	}
	t.Fatalf("no step %s", stepID)
	return nil
}

func check(t *testing.T, s steps.Step, f *stepstest.Fixture, want bool) {
	t.Helper()
	got, err := s.Check(ctx, f.Env)
	if err != nil || got != want {
		t.Fatalf("%s: Check = %v, %v; want %v", s.ID(), got, err, want)
	}
}

func apply(t *testing.T, s steps.Step, f *stepstest.Fixture) {
	t.Helper()
	if err := s.Apply(ctx, f.Env, f.Rep); err != nil {
		t.Fatalf("%s Apply: %v", s.ID(), err)
	}
	if err := s.Verify(ctx, f.Env); err != nil {
		t.Fatalf("%s Verify: %v", s.ID(), err)
	}
}

// cycle: not done -> apply -> verify -> done -> second apply is harmless.
func cycle(t *testing.T, s steps.Step, f *stepstest.Fixture) {
	t.Helper()
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	apply(t, s, f)
	check(t, s, f, true)
}

func TestEnableMultilib(t *testing.T) {
	in := "[core]\nInclude = a\n\n#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n\n#[x]\n"
	out, changed := steps.EnableMultilib(in)
	if !changed || !strings.Contains(out, "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n") || !strings.Contains(out, "#[x]") {
		t.Fatalf("%q", out)
	}
	if _, again := steps.EnableMultilib(out); again {
		t.Fatal("second pass must change nothing")
	}
}

func TestMultilibStep(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	stepstest.Write(t, f.Env.Rootfs, "etc/pacman.conf", "#[multilib]\n#Include = /etc/pacman.d/mirrorlist\n", 0o644)
	s := stepOf(t, f, "core", "core.pre.multilib")
	check(t, s, f, false)
	if err := s.Apply(ctx, f.Env, f.Rep); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(f.Env.Rootfs, "etc/pacman.conf"))
	if string(got) != "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" {
		t.Fatalf("pacman.conf: %q", got)
	}
	if !f.Sim.HasCall("sudo pacman -Sy --noconfirm") {
		t.Fatalf("no sync: %v", f.Sim.Calls())
	}
	check(t, s, f, true)
}

func TestRepoPackagesSingleTransaction(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	for _, p := range []string{"kitty", "cava", "hyprland", "jq"} {
		f.Sim.Repo[p] = true
	}
	f.Sim.Installed["jq"] = true
	s := steps.NewRepo(steps.Base{StepID: "pkg.repo"}, []string{"kitty", "cava", "jq", "hyprland"})
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	tx := f.Sim.CallsWith("sudo pacman -S ")
	if len(tx) != 1 || tx[0] != "sudo pacman -S --noconfirm --needed kitty cava hyprland" {
		t.Fatalf("transaction: %v", tx)
	}
	rec := steps.InstalledPackages(f.Env.StateDir)
	if rec["kitty"] != "core" || rec["hyprland"] != "_dep" || rec["jq"] != "" {
		t.Fatalf("installed-packages: %v", rec)
	}
}

func TestRepoFallsBackToAURForNonRepoPackages(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	f.Sim.Repo["kitty"] = true
	s := steps.NewRepo(steps.Base{StepID: "pkg.repo"}, []string{"kitty", "weird-aur-only"})
	apply(t, s, f)
	if !f.Sim.HasCall("yay -S --noconfirm --needed weird-aur-only") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
}

func TestRepoStaleLock(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	stepstest.Write(t, f.Env.Rootfs, "var/lib/pacman/db.lck", "", 0o644)
	s := steps.NewRepo(steps.Base{StepID: "pkg.repo"}, []string{"kitty"})
	err := s.Apply(ctx, f.Env, f.Rep)
	var le *steps.DBLockError
	if !errors.As(err, &le) {
		t.Fatalf("want DBLockError, got %v", err)
	}
	if f.Sim.HasCall("sudo pacman -S ") {
		t.Fatal("pacman must not run with a stale lock")
	}
	if err := steps.ClearStaleLock(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.HasCall("sudo rm -f /var/lib/pacman/db.lck") || !f.Sim.HasCall("pacman -Dk") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
}

func TestAURAndHelper(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := steps.NewAUR(steps.Base{StepID: "aur.wl-gammarelay-rs", Mod: "core"}, "wl-gammarelay-rs")
	check(t, s, f, false)
	apply(t, s, f)
	check(t, s, f, true)
	var found bool
	for _, c := range f.Sim.Recorded() {
		if c.Name == "yay" {
			found = true
			if !contains(c.Env, "MAKEFLAGS=-j4") || !contains(c.Env, "CARGO_BUILD_JOBS=4") {
				t.Fatalf("env %v", c.Env)
			}
		}
	}
	if !found {
		t.Fatal("yay not called")
	}
	if steps.SafeJobs(1) != 1 || steps.SafeJobs(3) != 1 || steps.SafeJobs(64) != 4 {
		t.Fatal("SafeJobs")
	}

	// no helper: yay-bin is built from the AUR with makepkg
	f.Bins["yay"] = false
	h := steps.NewAURHelper(steps.Base{StepID: "aur-helper"})
	check(t, h, f, false)
	f.Env.Runner = hookRunner{f.Sim, map[string]func(runCmd){"makepkg": func(runCmd) { f.Bins["yay"] = true }}}
	if err := h.Apply(ctx, f.Env, f.Rep); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.HasCall("git clone https://aur.archlinux.org/yay-bin.git") || !f.Sim.HasCall("makepkg -si --noconfirm") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
	if err := h.Verify(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func TestKeyring(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := steps.NewKeyring(steps.Base{StepID: "keyring"})
	// built 2026-10-01, now 2026-10-08: fresh
	check(t, s, f, true)
	f.Sim.KeyringBuilt = time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	check(t, s, f, false)
	apply(t, s, f)
	if !f.Sim.HasCall("sudo pacman -Sy --noconfirm --needed archlinux-keyring") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
}

func TestSyncOnlyOnFreshFirstInstall(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	s := steps.NewSync(steps.Base{StepID: "pkg.sync"})
	check(t, s, f, false) // fresh
	f.Env.Opts.Reinstall = true
	check(t, s, f, true)
	f.Env.Opts.Reinstall = false
	f.Env.Opts.InstallState = steps.StateCurrent
	check(t, s, f, true)
	f.Env.Opts.InstallState = steps.StateLegacy
	f.Env.Mode = steps.ModeRepair
	check(t, s, f, true)
	f.Env.Mode = steps.ModeInstall
	check(t, s, f, false)
	apply(t, s, f)
	if !f.Sim.HasCall("sudo pacman -Syyu --noconfirm") {
		t.Fatal("no -Syyu")
	}
}

func zipOf(t *testing.T, name string, body []byte) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := zip.NewWriter(&b)
	w, _ := zw.Create(name)
	w.Write(body)
	zw.Close()
	return b.Bytes()
}

func TestBinaryDownloadVerifyInstall(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "vpn")
	archive := zipOf(t, "xray", []byte("XRAY-BINARY"))
	sum := sha256.Sum256(archive)
	b := manifest.Binary{Name: "xray", URL: "https://example.invalid/xray.zip", Version: "1", SHA256: hex.EncodeToString(sum[:]),
		ArchiveMember: "xray", Dest: "/usr/local/bin/xray", Mode: "0755", SkipIfPkg: []string{"xray", "xray-bin"}}
	f.DL.Files[b.URL] = archive
	s := steps.NewBinary(steps.Base{StepID: "binary.xray", Mod: "vpn"}, b)
	cycle(t, s, f)
	got, _ := os.ReadFile(filepath.Join(f.Env.Rootfs, "usr/local/bin/xray"))
	if string(got) != "XRAY-BINARY" {
		t.Fatalf("installed %q", got)
	}
	if len(f.DL.Log) != 1 {
		t.Fatalf("downloaded %d times", len(f.DL.Log))
	}
	if err := s.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, s, f, false)
	if _, err := os.Stat(filepath.Join(f.Env.Rootfs, "usr/local/bin/xray")); err == nil {
		t.Fatal("rollback must remove the binary")
	}
}

func TestBinaryWrongHashInstallsNothing(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "vpn")
	b := manifest.Binary{Name: "xray", URL: "https://example.invalid/x.zip", Version: "1", SHA256: strings.Repeat("0", 64),
		ArchiveMember: "xray", Dest: "/usr/local/bin/xray"}
	f.DL.Files[b.URL] = zipOf(t, "xray", []byte("EVIL"))
	s := steps.NewBinary(steps.Base{StepID: "binary.xray", Mod: "vpn"}, b)
	err := s.Apply(ctx, f.Env, f.Rep)
	if err == nil || !strings.Contains(err.Error(), "sha256 mismatch") {
		t.Fatalf("err = %v", err)
	}
	if f.Sim.HasCall("sudo install") {
		t.Fatal("nothing may be installed after a hash mismatch")
	}
}

func TestBinarySkippedWhenPackageInstalled(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "vpn")
	f.Sim.Installed["xray-bin"] = true
	m := mod(t, f, "vpn")
	s := steps.NewBinary(steps.Base{StepID: "binary.xray", Mod: "vpn"}, m.Binary[0])
	check(t, s, f, true)
	if m.Binary[0].SHA256 == "" || len(m.Binary[0].SHA256) != 64 {
		t.Fatal("manifest hash must be pinned")
	}
}

func TestSecretsStoredWith600AndNeverLogged(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "ai-gemini")
	f.Env.Opts.Secrets = map[string]string{"ai.gemini_key": "AIzaFAKEkey0123456789abcdef"}
	s := stepOf(t, f, "ai-gemini", "ai-gemini.secret")
	cycle(t, s, f)
	p := filepath.Join(f.Env.Home, ".config/serpantinum/secrets/gemini_key")
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", fi, err)
	}
	for _, l := range append(f.Rep.Logs, f.Rep.Warns...) {
		if strings.Contains(l, "AIzaFAKE") {
			t.Fatalf("secret in log: %s", l)
		}
	}
	// no answer: nothing written, step is "done" (set later)
	f2 := stepstest.New(t)
	f2.Select(t, "core", "ai-gemini")
	s2 := stepOf(t, f2, "ai-gemini", "ai-gemini.secret")
	check(t, s2, f2, true)
	apply(t, s2, f2)
	if _, err := os.Stat(filepath.Join(f2.Env.Home, ".config/serpantinum/secrets/gemini_key")); err == nil {
		t.Fatal("empty secret must not create a file")
	}
}

func TestScriptRootFilesLinkTemplateHypr(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "hotkeys", "tools", "commands", "servers", "vpn", "nvidia")

	// files: ~/Notes mode 700
	notes := stepOf(t, f, "tools", "tools.notes")
	cycle(t, notes, f)
	if fi, _ := os.Stat(filepath.Join(f.Env.Home, "Notes")); fi.Mode().Perm() != 0o700 {
		t.Fatal("Notes mode")
	}

	// template: desktop entries rendered with the real home
	tmpl := stepOf(t, f, "commands", "commands.desktop")
	cycle(t, tmpl, f)
	d, _ := os.ReadFile(filepath.Join(f.Env.Home, ".local/share/applications/serpantinum-commands.desktop"))
	if !strings.Contains(string(d), "Exec="+f.Env.Home+"/.local/bin/serpantinum ipc") {
		t.Fatalf("desktop: %s", d)
	}
	if err := tmpl.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, tmpl, f, false)

	// script with check/undo: the commands unit
	unit := stepOf(t, f, "commands", "commands.unit")
	bin := filepath.Join(f.Env.Home, ".local/bin/serpantinum-x")
	f.Sim.FailOn(bin+" cmd install --check", errors.New("not installed"), 1)
	check(t, unit, f, false)
	apply(t, unit, f)
	if !f.Sim.HasCall(bin + " cmd install") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
	if err := unit.Rollback(ctx, f.Env); err != nil || !f.Sim.HasCall(bin+" cmd uninstall") {
		t.Fatalf("undo: %v", err)
	}

	// root file content (nvidia modprobe) through sudo install
	mp := stepOf(t, f, "nvidia", "nvidia.modprobe")
	cycle(t, mp, f)
	if b, _ := os.ReadFile(filepath.Join(f.Env.Rootfs, "etc/modprobe.d/serp-nvidia.conf")); string(b) != "options nvidia_drm modeset=1\n" {
		t.Fatalf("modprobe: %q", b)
	}
	if err := mp.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, mp, f, false)

	// ssh key: mkdir + keygen, then the check passes
	key := stepOf(t, f, "servers", "servers.sshkey")
	cycle(t, key, f)

	// vpn root step: x_vpn.sh runs as the user (it elevates itself) and is allowed to write
	// the root layer through XVPN_ALLOW_ROOT_INSTALL=1; without it the script refuses.
	vr := stepOf(t, f, "vpn", "vpn.root")
	apply(t, vr, f)
	if !f.Sim.HasCall("bash " + filepath.Join(f.Env.Home, ".local/share/serpantinum/src/scripts/custom/vpn/x_vpn.sh") + " install --apply") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
	if f.Sim.HasCall("sudo bash " + filepath.Join(f.Env.Home, ".local/share/serpantinum/src/scripts/custom/vpn/x_vpn.sh") + " install --apply") {
		t.Fatal("the vpn script must not be run under sudo (it would lose XVPN_ALLOW_ROOT_INSTALL)")
	}
	passed := false
	for _, c := range f.Sim.Cmds() {
		if len(c.Args) > 1 && strings.HasSuffix(c.Args[0], "x_vpn.sh") && c.Args[1] == "install" {
			for _, kv := range c.Env {
				passed = passed || kv == "XVPN_ALLOW_ROOT_INSTALL=1"
			}
		}
	}
	if !passed {
		t.Fatalf("XVPN_ALLOW_ROOT_INSTALL=1 not passed: %v", f.Sim.Calls())
	}
}

func TestHyprNeedsLuaConfig(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "hotkeys", "nvidia")
	hk := stepOf(t, f, "hotkeys", "hotkeys.require")
	check(t, hk, f, true) // no hyprland.lua: skipped with a warning
	if len(f.Rep.Warns) == 0 {
		t.Fatal("expected a warning")
	}
	stepstest.Write(t, f.Env.Home, ".config/hypr/hyprland.lua", "require(\"config/variables\")\n", 0o644)
	check(t, hk, f, false)
	apply(t, hk, f)
	if !f.Sim.HasCall("bash " + filepath.Join(f.Env.Home, ".local/share/serpantinum/src/scripts/custom/x_keybinds.sh") + " ensure-require") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}

	nv := stepOf(t, f, "nvidia", "nvidia.hypr")
	cycle(t, nv, f)
	entry, _ := os.ReadFile(filepath.Join(f.Env.Home, ".config/hypr/hyprland.lua"))
	if !strings.HasPrefix(string(entry), `require("config/serp_nvidia")`+"\n") {
		t.Fatalf("hyprland.lua: %s", entry)
	}
	env, _ := os.ReadFile(filepath.Join(f.Env.Home, ".config/hypr/config/serp_nvidia.lua"))
	if !strings.Contains(string(env), `hl.env("LIBVA_DRIVER_NAME", "nvidia")`) {
		t.Fatalf("env file: %s", env)
	}
	if err := nv.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	entry, _ = os.ReadFile(filepath.Join(f.Env.Home, ".config/hypr/hyprland.lua"))
	if string(entry) != "require(\"config/variables\")\n" {
		t.Fatalf("rollback must restore hyprland.lua, got %q", entry)
	}
}

func TestStateFilesAndInstallState(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core", "hotkeys")
	if got := steps.DetectInstallState(f.Env.Home); got != steps.StateFresh {
		t.Fatal(got)
	}
	s := stepOf(t, f, "core", "core.state")
	cycle(t, s, f)
	if got := steps.DetectInstallState(f.Env.Home); got != steps.StateCurrent {
		t.Fatal(got)
	}
	b, _ := os.ReadFile(f.Env.VersionFile())
	v := steps.ParseVersionFile(b)
	if v.Version != "2.2.4-s3" || v.Commit != "abc1234" || v.Compositors != "hyprland" || v.ForkCommit != "abc1234" {
		t.Fatalf("%+v\n%s", v, b)
	}
	if !strings.HasPrefix(string(b), "SERPANTINUM_VERSION=\"2.2.4-s3\"\nSERPANTINUM_COMMIT=\"abc1234\"\nSELECTED_COMPOSITORS=\"hyprland\"\n") {
		t.Fatalf("upstream format changed:\n%s", b)
	}
	m, _ := os.ReadFile(f.Env.ModulesFile())
	if !strings.Contains(string(m), `"core"`) || !strings.Contains(string(m), `"hotkeys"`) {
		t.Fatalf("modules.json: %s", m)
	}
	stepstest.Write(t, f.Env.Home, ".local/state/serpantinum/first_launch.done", "", 0o644)
	apply(t, s, f)
	if err := s.Rollback(ctx, f.Env); err != nil {
		t.Fatal(err)
	}
	check(t, s, f, false)

	g := stepstest.New(t)
	stepstest.Write(t, g.Env.Home, ".local/state/imperative-dots-version", "x", 0o644)
	if steps.DetectInstallState(g.Env.Home) != steps.StateLegacy {
		t.Fatal("legacy")
	}
}

func TestLinks(t *testing.T) {
	f := stepstest.New(t)
	f.Select(t, "core")
	dc := steps.NewDeployCode(steps.Base{StepID: "deploy.code", Mod: "core"})
	apply(t, dc, f)
	l := stepOf(t, f, "core", "core.links")
	cycle(t, l, f)
	for _, n := range []string{"serpantinum", "serpantinumd", "serpantinum-x"} {
		tg, err := os.Readlink(filepath.Join(f.Env.Home, ".local/bin", n))
		if err != nil || tg != filepath.Join(f.Env.TargetBase(), "bin", n) {
			t.Fatalf("%s -> %q %v", n, tg, err)
		}
	}
	if !f.Sim.HasCall("sudo ln -sf " + filepath.Join(f.Env.TargetBase(), "bin/serpantinum") + " /usr/local/bin/serpantinum") {
		t.Fatalf("calls: %v", f.Sim.Calls())
	}
	if f.Sim.HasCall("sudo ln -sf " + filepath.Join(f.Env.TargetBase(), "bin/serpantinum-x")) {
		t.Fatal("serpantinum-x is linked into ~/.local/bin only")
	}
}

func TestEveryManifestStepHasAnImplementation(t *testing.T) {
	f := stepstest.New(t)
	for _, m := range f.Env.Set.List {
		for _, st := range m.Steps {
			if _, err := steps.FromManifest(m, st); err != nil {
				t.Errorf("%s/%s: %v", m.ID, st.ID, err)
			}
		}
	}
	used := map[string]bool{}
	for _, m := range f.Env.Set.List {
		for _, st := range m.Steps {
			if st.Kind == "builtin" {
				used[st.ID] = true
			}
		}
	}
	for _, id := range steps.BuiltinIDs() {
		if !used[id] {
			t.Errorf("builtin %s is not used by any manifest", id)
		}
	}
}
