package engine_test

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"serpx/installer/internal/engine"
	"serpx/installer/internal/journal"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/steps/stepstest"
)

var ctx = context.Background()

// newSetup prepares a fixture whose repo knows every manifest package and
// whose Xray download matches the (re-pinned) manifest hash.
func newSetup(t *testing.T) (*stepstest.Fixture, *engine.Setup) {
	t.Helper()
	f := stepstest.New(t)
	for _, m := range f.Env.Set.List {
		for _, p := range m.Packages {
			f.Sim.Repo[p] = true
		}
	}
	f.Sim.Repo["hyprland"] = true
	for _, m := range f.Env.Set.List {
		for i := range m.Binary {
			var b bytes.Buffer
			zw := zip.NewWriter(&b)
			w, _ := zw.Create(m.Binary[i].ArchiveMember)
			w.Write([]byte("FAKE-" + m.Binary[i].Name))
			zw.Close()
			sum := sha256.Sum256(b.Bytes())
			m.Binary[i].SHA256 = hex.EncodeToString(sum[:])
			f.DL.Files[m.Binary[i].URL] = b.Bytes()
		}
	}
	var fb bytes.Buffer
	fz := zip.NewWriter(&fb)
	fw, _ := fz.Create("IosevkaNerdFont-Regular.ttf")
	fw.Write([]byte("ttf"))
	fz.Close()
	f.DL.Files[steps.FontsURL] = fb.Bytes()
	return f, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: func(w run.Whitelist) { f.Sim.White = &w }}
}

func entries(t *testing.T, f *stepstest.Fixture) []journal.Entry {
	t.Helper()
	e, err := journal.Read(filepath.Join(f.Env.StateDir, journal.FileJournal))
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func state(t *testing.T, f *stepstest.Fixture) map[string]string {
	return journal.States(entries(t, f))
}

func fullList(t *testing.T, f *stepstest.Fixture) []string {
	l, err := resolve.New(f.Env.Set).Preset(resolve.PresetFull, resolve.Detect{})
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

var tmpName = regexp.MustCompile(`root-\d+`)

func normalize(f *stepstest.Fixture, calls []string) string {
	var out []string
	r := strings.NewReplacer(f.Env.Home, "$HOME", f.Env.Payload, "$PAYLOAD", f.Env.Rootfs, "$ROOTFS")
	for _, c := range calls {
		out = append(out, tmpName.ReplaceAllString(r.Replace(c), "root-N"))
	}
	return strings.Join(out, "\n") + "\n"
}

func TestInstallFullPresetGolden(t *testing.T) {
	f, s := newSetup(t)
	f.Env.Opts.Secrets = map[string]string{"ai.gemini_key": "AIzaFAKEkey0123456789abcdef", "vpn.subscription": "https://sub.invalid/FAKETOKEN"}
	stepstest.Write(t, f.Env.Rootfs, "etc/pacman.conf", "#[multilib]\n#Include = x\n", 0o644)
	stepstest.Write(t, f.Env.Home, ".config/hypr/hyprland.lua", "-- old\n", 0o644)
	stepstest.Write(t, f.Env.Home, ".config/hypr/old.conf", "old", 0o644)
	f.Sim.Repo["wl-gammarelay-rs"] = false
	// the "is it installed?" probes of a clean system answer no once
	vpn := filepath.Join(f.Env.Home, ".local/share/serpantinum/src/scripts/custom/vpn/x_vpn.sh")
	f.Sim.FailOn("bash "+vpn+" install --check", errors.New("not installed"), 1)
	f.Sim.FailOn(filepath.Join(f.Env.Home, ".local/bin/serpantinum-x")+" cmd install --check", errors.New("not installed"), 1)

	if err := engine.Install(ctx, s, fullList(t, f)); err != nil {
		t.Fatalf("install: %v", err)
	}
	st := state(t, f)
	for id, ev := range st {
		if ev != journal.EvDone && ev != journal.EvSkip {
			t.Errorf("step %s ended as %s", id, ev)
		}
	}
	if !journal.Finished(entries(t, f)) {
		t.Error("no finish event")
	}

	// result on disk
	h := f.Env.Home
	for _, p := range []string{
		".local/share/serpantinum/bin/serpantinum", ".local/share/serpantinum/src/scripts/foo.sh", ".local/bin/serpantinum-x -> link",
		".local/state/serpantinum/version", ".config/serpantinum-x/modules.json", ".config/serpantinum/settings.json",
		".config/serpantinum/secrets/gemini_key", ".config/serpantinum/secrets/vpn_subscription", "Notes",
		".config/hypr/hyprland.lua", ".local/share/applications/serpantinum-commands.desktop",
		".local/state/serpantinum-installer/installed.toml", ".local/state/serpantinum-installer/plan.json",
		".local/state/serpantinum-installer/timings.json", ".local/state/serpantinum-installer/installed-packages.txt",
	} {
		p = strings.TrimSuffix(p, " -> link")
		if !exists(filepath.Join(h, p)) {
			t.Errorf("missing %s", p)
		}
	}
	if exists(filepath.Join(h, ".config/hypr/old.conf")) {
		t.Error("old compositor file should be pruned (and be in the backup)")
	}
	if bk, _ := filepath.Glob(filepath.Join(h, ".config/hypr_backup/backup_*/old.conf")); len(bk) != 1 {
		t.Errorf("hypr backup: %v", bk)
	}
	if !exists(filepath.Join(f.Env.Rootfs, "usr/local/bin/xray")) {
		t.Error("xray not installed")
	}
	inst, err := engine.ReadInstalled(f.Env.StateDir)
	if err != nil || inst.Build != "2.2.4-s3" || len(inst.Modules) != len(fullList(t, f)) {
		t.Fatalf("installed.toml: %+v %v", inst, err)
	}

	// no secret value anywhere in the state dir
	filepath.WalkDir(f.Env.StateDir, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && !strings.Contains(p, "backups") {
			b, _ := os.ReadFile(p)
			if bytes.Contains(b, []byte("AIzaFAKE")) || bytes.Contains(b, []byte("FAKETOKEN")) {
				t.Errorf("secret value in %s", p)
			}
		}
		return nil
	})
	plan, _ := os.ReadFile(filepath.Join(f.Env.StateDir, "plan.json"))
	if !strings.Contains(string(plan), `"ai.gemini_key": "set"`) {
		t.Errorf("plan.json should say the key is set:\n%s", plan)
	}
	for _, l := range f.Rep.Logs {
		if strings.Contains(l, "AIzaFAKE") || strings.Contains(l, "FAKETOKEN") {
			t.Errorf("secret in log line: %s", l)
		}
	}

	// command sequence
	got := normalize(f, f.Sim.Calls())
	golden := filepath.Join("testdata", "install-full.golden")
	if os.Getenv("UPDATE_GOLDEN") == "1" {
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(golden, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Errorf("command sequence differs from %s (UPDATE_GOLDEN=1 to refresh)\n--- got ---\n%s", golden, got)
	}
}

func TestSecondInstallIsANoOp(t *testing.T) {
	f, s := newSetup(t)
	mods := []string{"core", "hotkeys", "emoji", "tools", "vpn"}
	if err := engine.Install(ctx, s, mods); err != nil {
		t.Fatal(err)
	}
	calls := len(f.Sim.Calls())
	downloads := len(f.DL.Log)
	if downloads != 2 { // xray + fonts
		t.Fatalf("first install downloaded %v", f.DL.Log)
	}
	files := stepstest.Tree(t, f.Env.Home)

	f.Env.Run = "20261008-1300"
	f.Env.Opts.InstallState = "" // detected again: now "current"
	s2 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}
	if err := engine.Install(ctx, s2, mods); err != nil {
		t.Fatal(err)
	}
	if len(f.DL.Log) != downloads {
		t.Error("the xray archive was downloaded again")
	}
	for _, c := range f.Sim.Calls()[calls:] {
		if strings.HasPrefix(c, "sudo pacman -S ") || strings.HasPrefix(c, "sudo install") || strings.Contains(c, "x_vpn.sh install --apply") {
			t.Errorf("second run changed the system: %s", c)
		}
	}
	if strings.Join(files, "\n") != strings.Join(stepstest.Tree(t, f.Env.Home), "\n") {
		t.Error("second run changed files")
	}
}

func TestFailureAbortKeepsJournalAndResumeContinues(t *testing.T) {
	f, s := newSetup(t)
	f.Sim.FailOn("pacman -S --noconfirm --needed", errors.New("pacman: exit 1"), -1)
	err := engine.Install(ctx, s, []string{"core", "emoji"})
	if !errors.Is(err, engine.ErrAborted) {
		t.Fatalf("want ErrAborted, got %v", err)
	}
	var se *engine.StepError
	if !errors.As(err, &se) || se.Step != "pkg.repo" {
		t.Fatalf("step error: %v", err)
	}
	st := state(t, f)
	if st["pkg.repo"] != journal.EvFail || st["sudo"] == journal.EvFail || st["sudo"] == "" || st["deploy.code"] != "" {
		t.Fatalf("journal states: %v", st)
	}
	need, err := journal.NeedsResume(f.Env.StateDir)
	if err != nil || !need {
		t.Fatalf("NeedsResume = %v, %v", need, err)
	}
	if f.Sim.HasCall("sudo rm") {
		t.Error("abort must not roll anything back")
	}

	// the problem goes away; resume
	f.Sim.ClearRules()
	f.Env.Run = "20261008-1301"
	syncs := len(f.Sim.CallsWith("sudo pacman -Syyu"))
	s2 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm, Resume: true}
	f.Env.Opts.InstallState = steps.StateFresh // as saved in the first run's plan
	if err := engine.Install(ctx, s2, []string{"core", "emoji"}); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if n := len(f.Sim.CallsWith("sudo pacman -Syyu")); n != syncs {
		t.Errorf("finished steps were repeated (-Syyu %d -> %d)", syncs, n)
	}
	if !journal.Finished(entries(t, f)) || !exists(filepath.Join(f.Env.Home, ".local/state/serpantinum/version")) {
		t.Error("resumed install did not finish")
	}
}

func TestRetryThenSuccess(t *testing.T) {
	f, s := newSetup(t)
	f.Sim.FailOn("pacman -S --noconfirm --needed", errors.New("mirror timeout"), 1)
	var asked int
	s.Decide = func(st steps.Step, err error) engine.Decision {
		asked++
		return engine.Retry
	}
	if err := engine.Install(ctx, s, []string{"core"}); err != nil {
		t.Fatal(err)
	}
	if asked != 1 {
		t.Fatalf("asked %d times", asked)
	}
	var fails int
	for _, e := range entries(t, f) {
		if e.Step == "pkg.repo" && e.Ev == journal.EvFail {
			fails++
		}
	}
	if fails != 1 {
		t.Fatalf("fail events: %d", fails)
	}
}

func TestSkipModuleRollsBackAndCascades(t *testing.T) {
	f, s := newSetup(t)
	bin := filepath.Join(f.Env.Home, ".local/bin/serpantinum-x")
	f.Sim.FailOn(filepath.Join(f.Env.Home, ".local/bin/serpantinum-x")+" cmd install --check", errors.New("not installed"), 1) // Check says "not done" once
	// commands.unit applies fine, commands.desktop fails (missing templates)
	os.RemoveAll(filepath.Join(f.Env.Payload, "src/assets/custom-desktop"))
	s.Decide = func(st steps.Step, err error) engine.Decision {
		if st.ID() == "commands.desktop" {
			return engine.Skip
		}
		t.Errorf("unexpected failure of %s: %v", st.ID(), err)
		return engine.Abort
	}
	if err := engine.Install(ctx, s, []string{"core", "commands-media", "emoji"}); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.HasCall(bin + " cmd uninstall") {
		t.Errorf("commands.unit was not rolled back: %v", f.Sim.CallsWith(bin))
	}
	st := state(t, f)
	if st["commands.desktop"] != journal.EvSkip || st["emoji.cache"] != journal.EvDone {
		t.Fatalf("states: %v", st)
	}
	inst, _ := engine.ReadInstalled(f.Env.StateDir)
	if strings.Join(inst.Modules, ",") != "core,emoji" {
		t.Fatalf("skipped modules must not be recorded as installed: %v", inst.Modules)
	}
	var undo bool
	for _, e := range entries(t, f) {
		if e.Step == "commands.unit" && e.Ev == journal.EvUndo {
			undo = true
		}
	}
	if !undo {
		t.Error("no undo event for commands.unit")
	}
}

func TestCoreFailureCannotBeSkipped(t *testing.T) {
	f, s := newSetup(t)
	f.Sim.FailOn("pacman -S --noconfirm --needed", errors.New("boom"), -1)
	s.Decide = func(steps.Step, error) engine.Decision { return engine.Skip }
	if err := engine.Install(ctx, s, []string{"core"}); !errors.Is(err, engine.ErrAborted) {
		t.Fatalf("want abort, got %v", err)
	}
}

func TestCancelLeavesNoFailEvent(t *testing.T) {
	f, s := newSetup(t)
	cctx, cancel := context.WithCancel(ctx)
	s.OnStep = func(i, n int, st steps.Step, ev string) {
		if st.ID() == "keyring" && ev == journal.EvStart {
			cancel()
		}
	}
	f.Sim.KeyringBuilt = f.Sim.KeyringBuilt.AddDate(-1, 0, 0)
	if err := engine.Install(cctx, s, []string{"core"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	for _, e := range entries(t, f) {
		if e.Ev == journal.EvFail {
			t.Fatalf("cancel must not be recorded as a failure: %+v", e)
		}
	}
}

func TestRepairRestoresBrokenAndMissing(t *testing.T) {
	f, s := newSetup(t)
	mods := []string{"core", "hotkeys", "tools"}
	if err := engine.Install(ctx, s, mods); err != nil {
		t.Fatal(err)
	}
	h := f.Env.Home
	custom := filepath.Join(h, ".config/kitty/kitty.conf")
	os.WriteFile(custom, []byte("my tuned kitty"), 0o644)
	os.Remove(filepath.Join(h, ".local/bin/serpantinumd"))
	os.Remove(filepath.Join(h, ".local/share/serpantinum/bin/serpantinum"))
	os.Remove(filepath.Join(h, ".config/cava/config"))
	os.Remove(filepath.Join(h, "Notes"))
	f.Sim.Installed["cava"] = false

	f.Env.Run = "20261008-1400"
	if err := engine.Repair(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{".local/bin/serpantinumd", ".local/share/serpantinum/bin/serpantinum", ".config/cava/config", "Notes"} {
		if !exists(filepath.Join(h, p)) {
			t.Errorf("repair did not restore %s", p)
		}
	}
	if !f.Sim.Installed["cava"] {
		t.Error("repair did not reinstall the missing package")
	}
	if b, _ := os.ReadFile(custom); string(b) != "my tuned kitty" {
		t.Error("repair overwrote a customised config")
	}
}

func TestModulesAddAndRemove(t *testing.T) {
	f, s := newSetup(t)
	if err := engine.Install(ctx, s, []string{"core", "hotkeys"}); err != nil {
		t.Fatal(err)
	}
	h := f.Env.Home
	stepstest.Write(t, h, ".config/hypr/hyprland.lua", "require(\"config/variables\")\npcall(require, \"config/user_keybinds\")\n", 0o644)
	stepstest.Write(t, h, ".config/hypr/config/user_keybinds.lua", "-- generated", 0o644)

	// add tools + ocr
	f.Env.Run = "20261008-1500"
	s2 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}
	if err := engine.Modules(ctx, s2, []string{"core", "hotkeys", "tools", "ocr"}); err != nil {
		t.Fatal(err)
	}
	if !exists(filepath.Join(h, "Notes")) || !f.Sim.Installed["tesseract"] {
		t.Fatalf("added modules not installed (notes=%v tesseract=%v)", exists(filepath.Join(h, "Notes")), f.Sim.Installed["tesseract"])
	}
	if n := len(f.Sim.CallsWith("sudo pacman -Syyu")); n != 1 {
		t.Fatalf("modules mode must not sync the system again (%d syncs)", n)
	}
	inst, _ := engine.ReadInstalled(f.Env.StateDir)
	if strings.Join(inst.Modules, ",") != "core,hotkeys,tools,ocr" {
		t.Fatalf("installed.toml: %v", inst.Modules)
	}
	if mj, _ := os.ReadFile(f.Env.ModulesFile()); !strings.Contains(string(mj), "ocr") {
		t.Fatalf("modules.json: %s", mj)
	}

	// remove ocr and hotkeys; packages only after confirmation
	f.Env.Run = "20261008-1501"
	var asked []string
	s3 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm, Confirm: func(kind string, items []string) bool {
		asked = append(asked, kind+":"+strings.Join(items, " "))
		return false
	}}
	if err := engine.Modules(ctx, s3, []string{"core", "tools"}); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.Installed["tesseract"] {
		t.Error("packages were removed without confirmation")
	}
	if len(asked) != 1 || !strings.Contains(asked[0], "packages:") || !strings.Contains(asked[0], "tesseract") {
		t.Errorf("confirm calls: %v", asked)
	}
	lua, _ := os.ReadFile(filepath.Join(h, ".config/hypr/hyprland.lua"))
	if strings.Contains(string(lua), "user_keybinds") || !strings.Contains(string(lua), "config/variables") {
		t.Errorf("hyprland.lua after removing hotkeys: %q", lua)
	}
	if exists(filepath.Join(h, ".config/hypr/config/user_keybinds.lua")) {
		t.Error("user_keybinds.lua should be removed with the hotkeys module")
	}
	inst, _ = engine.ReadInstalled(f.Env.StateDir)
	if strings.Join(inst.Modules, ",") != "core,tools" {
		t.Fatalf("installed.toml: %v", inst.Modules)
	}

	// confirmed removal takes the packages out
	f.Env.Run = "20261008-1502"
	s4 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm, Confirm: func(string, []string) bool { return true }}
	if err := engine.Modules(ctx, s4, []string{"core", "tools", "ocr"}); err != nil { // re-add ocr first
		t.Fatal(err)
	}
	f.Env.Run = "20261008-1503"
	if err := engine.Modules(ctx, s4, []string{"core", "tools"}); err != nil {
		t.Fatal(err)
	}
	if f.Sim.Installed["tesseract"] {
		t.Error("confirmed removal left the package")
	}
}

func TestUninstallKeepsUserData(t *testing.T) {
	f, s := newSetup(t)
	f.Env.Opts.Secrets = map[string]string{"ai.gemini_key": "AIzaFAKEkey0123456789abcdef"}
	if err := engine.Install(ctx, s, fullList(t, f)); err != nil {
		t.Fatal(err)
	}
	h := f.Env.Home
	stepstest.Write(t, h, ".local/share/serpantinum/src/user-extra.txt", "foreign", 0o644)
	stepstest.Write(t, h, ".local/share/serpantinum-x/vpn/nodes.json", "{}", 0o644)
	stepstest.Write(t, h, "Notes/idea.md", "# idea", 0o644)
	stepstest.Write(t, h, ".config/hypr/hyprland.lua", "pcall(require, \"config/user_keybinds\")\n-- mine\n", 0o644)

	f.Env.Run = "20261008-1600"
	if err := engine.Uninstall(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}, engine.UninstallOptions{}); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{".local/bin/serpantinum", ".local/bin/serpantinum-x", ".local/share/serpantinum/bin", ".local/share/serpantinum/src/scripts", ".local/share/serpantinum-x",
		".local/state/serpantinum/version", ".config/serpantinum-x/modules.json", ".local/state/serpantinum-installer/installed.toml",
		".local/share/applications/serpantinum-commands.desktop"} {
		if exists(filepath.Join(h, p)) {
			t.Errorf("%s should be gone", p)
		}
	}
	for _, p := range []string{".config/serpantinum/settings.json", ".config/serpantinum/secrets/gemini_key", "Notes/idea.md",
		".local/share/serpantinum/src/user-extra.txt", ".config/kitty/kitty.conf"} {
		if !exists(filepath.Join(h, p)) {
			t.Errorf("%s must survive uninstall", p)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(h, ".config/hypr/hyprland.lua")); strings.Contains(string(b), "user_keybinds") || !strings.Contains(string(b), "-- mine") {
		t.Errorf("hyprland.lua: %q", b)
	}
	bin := filepath.Join(h, ".local/bin/serpantinum-x")
	if !f.Sim.HasCall(bin + " cmd uninstall") {
		t.Error("the commands daemon was not uninstalled")
	}
	// x_vpn.sh has no uninstall command: the root layer goes away through root_files
	if f.Sim.HasCall("sudo bash ") || f.Sim.HasCall("bash "+filepath.Join(h, ".local/share/serpantinum/src/scripts/custom/vpn/x_vpn.sh")+" uninstall") {
		t.Errorf("x_vpn.sh uninstall does not exist: %v", f.Sim.CallsWith("sudo bash"))
	}
	if exists(filepath.Join(f.Env.Rootfs, "usr/local/bin/xray")) {
		t.Error("xray binary should be removed")
	}
	if !f.Sim.Installed["kitty"] {
		t.Error("packages must stay by default")
	}
	if _, err := engine.ReadInstalled(f.Env.StateDir); !errors.Is(err, engine.ErrNotInstalled) {
		t.Error("installed.toml still there")
	}
}

func TestUninstallWithDataNeedsBackupAndConfirm(t *testing.T) {
	f, s := newSetup(t)
	if err := engine.Install(ctx, s, []string{"core", "tools"}); err != nil {
		t.Fatal(err)
	}
	h := f.Env.Home
	stepstest.Write(t, h, "Notes/idea.md", "# idea", 0o644)
	f.Env.Run = "20261008-1700"
	if err := engine.Uninstall(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}, engine.UninstallOptions{RemoveData: true}); err == nil {
		t.Fatal("removing data without a backup must be refused")
	}
	if !exists(filepath.Join(h, ".config/serpantinum/settings.json")) {
		t.Fatal("nothing may be removed when refused")
	}
	var backedUp bool
	opts := engine.UninstallOptions{RemoveData: true, RemovePackages: true, BackupBefore: func(context.Context) error { backedUp = true; return nil }}
	// no confirmation: data and packages stay
	f.Env.Run = "20261008-1701"
	if err := engine.Uninstall(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}, opts); err != nil {
		t.Fatal(err)
	}
	if !backedUp || !exists(filepath.Join(h, "Notes/idea.md")) || !f.Sim.Installed["kitty"] {
		t.Fatal("without confirmation data and packages must stay")
	}
}

func TestUninstallConfirmedRemovesDataAndPackages(t *testing.T) {
	f, s := newSetup(t)
	if err := engine.Install(ctx, s, []string{"core", "tools"}); err != nil {
		t.Fatal(err)
	}
	h := f.Env.Home
	stepstest.Write(t, h, "Notes/idea.md", "# idea", 0o644)
	f.Env.Run = "20261008-1800"
	var kinds []string
	err := engine.Uninstall(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm,
		Confirm: func(kind string, items []string) bool { kinds = append(kinds, kind); return true }},
		engine.UninstallOptions{RemoveData: true, RemovePackages: true, BackupBefore: func(context.Context) error { return nil }})
	if err != nil {
		t.Fatal(err)
	}
	if exists(filepath.Join(h, "Notes")) || exists(filepath.Join(h, ".config/serpantinum")) {
		t.Error("data was not removed")
	}
	if f.Sim.Installed["cava"] {
		t.Error("installer packages were not removed")
	}
	if strings.Join(kinds, ",") != "data,packages" {
		t.Errorf("confirmations: %v", kinds)
	}
}

func TestReconcileInstallsOnlyWhatIsMissing(t *testing.T) {
	f, s := newSetup(t)
	if err := engine.Install(ctx, s, []string{"core", "emoji"}); err != nil {
		t.Fatal(err)
	}
	f.Sim.Installed["noto-fonts-emoji"] = false
	n := len(f.Sim.Calls())
	f.Env.Run = "20261008-1900"
	if err := engine.Reconcile(ctx, &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm}); err != nil {
		t.Fatal(err)
	}
	var txs []string
	for _, c := range f.Sim.Calls()[n:] {
		if strings.HasPrefix(c, "sudo pacman -S ") {
			txs = append(txs, c)
		}
	}
	if len(txs) != 1 || !strings.Contains(txs[0], "noto-fonts-emoji") || strings.Contains(txs[0], "kitty") {
		t.Fatalf("reconcile transactions: %v", txs)
	}
}

func TestRepairWithoutInstallIsAnError(t *testing.T) {
	f, s := newSetup(t)
	if err := engine.Repair(ctx, s); !errors.Is(err, engine.ErrNotInstalled) {
		t.Fatalf("got %v", err)
	}
	if err := engine.Modules(ctx, s, []string{"core"}); !errors.Is(err, engine.ErrNotInstalled) {
		t.Fatalf("got %v", err)
	}
	_ = f
}

// A run killed in the middle of pacman leaves a stale db.lck and a package whose local db entry is
// cut short (found in the QEMU stand, scenario 4). --resume must clean that up and finish.
func TestResumeAfterKillRecoversPacman(t *testing.T) {
	f, s := newSetup(t)
	f.Sim.FailOn("pacman -S --noconfirm --needed", errors.New("pacman: exit 1"), -1)
	if err := engine.Install(ctx, s, []string{"core"}); !errors.Is(err, engine.ErrAborted) {
		t.Fatalf("want ErrAborted, got %v", err)
	}
	// the journal says pkg.repo started and never ended
	j, err := journal.Open(f.Env.StateDir, "20261008-1300")
	if err != nil {
		t.Fatal(err)
	}
	j.Append("pkg.repo", journal.EvStart, nil)
	j.Close()
	stepstest.Write(t, f.Env.Rootfs, "var/lib/pacman/db.lck", "", 0o644)
	f.Sim.ClearRules()
	f.Sim.Broken = []string{"source-highlight-3.1.9-19"}

	f.Env.Run = "20261008-1301"
	f.Env.Opts.InstallState = steps.StateFresh
	s2 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm, Resume: true}
	if err := engine.Install(ctx, s2, []string{"core"}); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if !f.Sim.HasCall("sudo rm -f /var/lib/pacman/db.lck") {
		t.Errorf("stale lock not removed: %v", f.Sim.Calls())
	}
	if !f.Sim.HasCall("sudo pacman -S --noconfirm --overwrite * source-highlight") {
		t.Errorf("cut-short package not reinstalled: %v", f.Sim.CallsWith("sudo pacman -S"))
	}
}

// "done" in the journal must mean the data is on the disk: the filesystems are flushed after a step
// that changed something and before its done event (power-loss scenario of the QEMU stand).
func TestStepsAreSyncedBeforeDone(t *testing.T) {
	f, s := newSetup(t)
	var syncs int
	old := engine.SyncFS
	engine.SyncFS = func() { syncs++ }
	defer func() { engine.SyncFS = old }()
	if err := engine.Install(ctx, s, []string{"core"}); err != nil {
		t.Fatal(err)
	}
	applied := 0
	for _, e := range entries(t, f) {
		if e.Ev == journal.EvDone {
			applied++
		}
	}
	if syncs == 0 || syncs < applied {
		t.Fatalf("syncs=%d for %d done steps", syncs, applied)
	}
}

// A root file in a directory the user cannot read (/etc/polkit-1/rules.d is 0700 root) must still be
// removed with `sudo rm -f` when its module goes away (found in the QEMU stand, scenario 3).
func TestRemoveModuleRemovesUnreadableRootFile(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read everything")
	}
	f, s := newSetup(t)
	if err := engine.Install(ctx, s, []string{"core", "vpn"}); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(f.Env.Rootfs, "etc/polkit-1/rules.d")
	stepstest.Write(t, f.Env.Rootfs, "etc/polkit-1/rules.d/49-serpantinum-xray.rules", "x", 0o644)
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	f.Env.Run = "20261008-1600"
	s2 := &engine.Setup{Env: f.Env, Cat: f.Cat, Arm: s.Arm, Confirm: func(string, []string) bool { return false }}
	if err := engine.Modules(ctx, s2, []string{"core"}); err != nil {
		t.Fatal(err)
	}
	if !f.Sim.HasCall("sudo rm -f /etc/polkit-1/rules.d/49-serpantinum-xray.rules") {
		t.Fatalf("unreadable root file not removed: %v", f.Sim.CallsWith("sudo rm"))
	}
}
