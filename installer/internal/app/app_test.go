package app_test

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/app"
	"serpx/installer/internal/app/apptest"
	"serpx/installer/internal/config"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/steps/stepstest"
	"serpx/installer/internal/tui"
)

const (
	fakeKey   = "AIzaFAKE0000000000000000000000000000"
	fakeToken = "FAKE-TOKEN-SECRET-0000"
)

type rig struct {
	*apptest.Rig
	svc *app.Service
	out *bytes.Buffer
}

// newRig builds a Service over the simulated machine.
func newRig(t *testing.T) *rig {
	t.Helper()
	ar := apptest.New(t)
	svc, err := app.New(ar.Cfg)
	if err != nil {
		t.Fatal(err)
	}
	return &rig{Rig: ar, svc: svc, out: &bytes.Buffer{}}
}

func (r *rig) plainOpts(policy plain.Policy) app.PlainOptions {
	return app.PlainOptions{Out: r.out, Lang: "en", Yes: true, Policy: policy, Verbose: true}
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

var minimal = []string{"core", "emoji", "hotkeys"}

func (r *rig) install(modules []string, secrets map[string]string) (tui.RunResult, error) {
	req := tui.Request{Mode: tui.ModeInstall, Modules: modules, Lang: "en", Secrets: secrets, Config: map[string]string{}}
	return r.svc.RunPlain(context.Background(), req, r.plainOpts(plain.PolicyAbort))
}

func TestPlainInstallMinimal(t *testing.T) {
	r := newRig(t)
	res, err := r.install(minimal, nil)
	if err != nil {
		t.Fatalf("install: %v\n%s", err, r.out)
	}
	out := r.out.String()
	for _, want := range []string{"Plan: ", "[ 1/", "Installation finished."} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	in := r.svc.Installed()
	if in == nil || strings.Join(in.Modules, ",") != "core,hotkeys,emoji" && strings.Join(in.Modules, ",") != "core,emoji,hotkeys" {
		t.Fatalf("installed = %+v", in)
	}
	if res.ConfigPath != "~/serpantinum-backups/my-setup.toml" || !exists(filepath.Join(r.Home, "serpantinum-backups/my-setup.toml")) {
		t.Fatalf("config path %q", res.ConfigPath)
	}
	if !exists(filepath.Join(r.Home, ".local/share/serpantinum/bin/serpantinum")) {
		t.Fatal("shell code not deployed")
	}
	// the per-run log exists and is private
	st, err := os.Stat(r.svc.LogPath())
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("log: %v %v", err, st)
	}
}

func TestSecretsAreWrittenButNeverPrinted(t *testing.T) {
	r := newRig(t)
	_, err := r.install([]string{"core", "ai-gemini", "servers"}, map[string]string{"ai.gemini_key": fakeKey, "servers.remnawave_token": fakeToken, "servers.remnawave_url": "https://panel.example.com"})
	if err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	b, err := os.ReadFile(filepath.Join(r.Home, ".config/serpantinum/secrets/gemini_key"))
	if err != nil || strings.TrimSpace(string(b)) != fakeKey {
		t.Fatalf("secret file: %v %q", err, b)
	}
	if st, _ := os.Stat(filepath.Join(r.Home, ".config/serpantinum/secrets/gemini_key")); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", st.Mode())
	}
	// not in the output, the run log, the journal, the plan, the xlog file
	var texts []string
	texts = append(texts, r.out.String())
	for _, root := range []string{filepath.Join(r.Home, ".local/state/serpantinum-installer"), filepath.Join(r.Home, "logs"), filepath.Join(r.Home, "serpantinum-backups")} {
		filepath.Walk(root, func(p string, i os.FileInfo, err error) error {
			if err == nil && !i.IsDir() {
				b, _ := os.ReadFile(p)
				texts = append(texts, string(b))
			}
			return nil
		})
	}
	for i, tx := range texts {
		for _, s := range []string{fakeKey, fakeToken} {
			if strings.Contains(tx, s) {
				t.Fatalf("text %d contains a secret", i)
			}
		}
	}
}

func TestSkipOptionalPolicySkipsFailedModule(t *testing.T) {
	r := newRig(t)
	r.Sim.FailOn("fc-cache", errors.New("boom"), -1) // the emoji module's own step
	req := tui.Request{Mode: tui.ModeInstall, Modules: []string{"core", "emoji", "hotkeys"}, Lang: "en", Config: map[string]string{}}
	res, err := r.svc.RunPlain(context.Background(), req, r.plainOpts(plain.PolicySkipOptional))
	if err != nil {
		t.Fatalf("a skippable module must not stop the run: %v\n%s", err, r.out)
	}
	if len(res.Skipped) != 1 || res.Skipped[0] != "emoji" {
		t.Fatalf("skipped = %v\n%s", res.Skipped, r.out)
	}
	in := r.svc.Installed()
	if in == nil || contains(in.Modules, "emoji") || !contains(in.Modules, "hotkeys") {
		t.Fatalf("installed = %+v", in)
	}
	if !strings.Contains(r.out.String(), "FAILED") || !strings.Contains(r.out.String(), "skipped") {
		t.Fatalf("output:\n%s", r.out)
	}
}

func TestAbortPolicyStopsOnOptionalFailure(t *testing.T) {
	r := newRig(t)
	r.Sim.FailOn("fc-cache", errors.New("boom"), -1)
	_, err := r.install([]string{"core", "emoji"}, nil)
	if err == nil || r.svc.Installed() != nil {
		t.Fatalf("err %v installed %v", err, r.svc.Installed())
	}
}

func TestAbortLeavesJournalForResume(t *testing.T) {
	r := newRig(t)
	r.Sim.FailOn("pacman -S", errors.New("boom"), -1)
	_, err := r.install(minimal, nil)
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(r.out.String(), "--resume") {
		t.Fatalf("resume hint missing:\n%s", r.out)
	}
	if !exists(filepath.Join(r.Home, ".local/state/serpantinum-installer/journal.jsonl")) {
		t.Fatal("journal missing")
	}
}

func TestRepairAndUninstallWithBackup(t *testing.T) {
	r := newRig(t)
	if _, err := r.install(minimal, nil); err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	// user data
	stepstest.Write(t, r.Home, ".config/serpantinum/commands/a.json", "{}", 0o644)
	stepstest.Write(t, r.Home, "Notes/n.md", "note", 0o644)
	r.out.Reset()
	if _, err := r.svc.RunPlain(context.Background(), tui.Request{Mode: tui.ModeRepair, Lang: "en"}, r.plainOpts(plain.PolicyAbort)); err != nil {
		t.Fatalf("repair: %v\n%s", err, r.out)
	}
	// uninstall keeping data
	r.out.Reset()
	if _, err := r.svc.RunPlain(context.Background(), tui.Request{Mode: tui.ModeUninstall, Lang: "en"}, r.plainOpts(plain.PolicyAbort)); err != nil {
		t.Fatalf("uninstall: %v\n%s", err, r.out)
	}
	if r.svc.Installed() != nil {
		t.Fatal("installed.toml must be gone")
	}
	if !exists(filepath.Join(r.Home, ".config/serpantinum/commands/a.json")) || !exists(filepath.Join(r.Home, "Notes/n.md")) {
		t.Fatal("data must stay")
	}
}

func TestUninstallRemoveDataMakesBackupFirst(t *testing.T) {
	r := newRig(t)
	if _, err := r.install(minimal, nil); err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	stepstest.Write(t, r.Home, ".config/serpantinum/commands/a.json", "{}", 0o644)
	res, err := r.svc.RunPlain(context.Background(), tui.Request{Mode: tui.ModeUninstall, Lang: "en", RemoveData: true}, r.plainOpts(plain.PolicyAbort))
	if err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	if res.BackupPath == "" {
		t.Fatal("backup path missing")
	}
	arch, _ := filepath.Glob(filepath.Join(r.Home, "serpantinum-backups", "serpantinum-backup-*"))
	if len(arch) != 1 {
		t.Fatalf("archives = %v", arch)
	}
	if exists(filepath.Join(r.Home, ".config/serpantinum/commands/a.json")) {
		t.Fatal("data must be removed after the backup")
	}
}

func TestReinstallBacksUpAndRestores(t *testing.T) {
	r := newRig(t)
	if _, err := r.install(minimal, nil); err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	stepstest.Write(t, r.Home, ".config/serpantinum/commands/mine.cmd.json", `{"x":1}`, 0o644)
	r.out.Reset()
	req := tui.Request{Mode: tui.ModeInstall, Modules: minimal, Lang: "en", Reinstall: true, Config: map[string]string{}}
	res, err := r.svc.RunPlain(context.Background(), req, r.plainOpts(plain.PolicyAbort))
	if err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	if res.BackupPath == "" || res.Restored == "" {
		t.Fatalf("result = %+v", res)
	}
	if b, _ := os.ReadFile(filepath.Join(r.Home, ".config/serpantinum/commands/mine.cmd.json")); string(b) != `{"x":1}` {
		t.Fatalf("data after restore: %q", b)
	}
}

func TestPlanForEveryMode(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	p, err := r.svc.Plan(ctx, tui.Request{Mode: tui.ModeInstall, Modules: minimal})
	if err != nil || len(p.Steps) < 10 || p.DownloadMiB <= 0 || p.ETA == nil {
		t.Fatalf("install plan: %v %d %v", err, len(p.Steps), p.DownloadMiB)
	}
	if _, err := r.svc.Plan(ctx, tui.Request{Mode: tui.ModeRepair}); err == nil {
		t.Fatal("repair without an installation must fail")
	}
	if _, err := r.install(minimal, nil); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{tui.ModeRepair, tui.ModeUninstall} {
		p, err := r.svc.Plan(ctx, tui.Request{Mode: mode})
		if err != nil || len(p.Steps) == 0 {
			t.Fatalf("%s: %v %d", mode, err, len(p.Steps))
		}
	}
	p, _ = r.svc.Plan(ctx, tui.Request{Mode: tui.ModeUninstall, RemoveData: true})
	if p.Steps[0].ID != "un.backup" {
		t.Fatalf("first uninstall step = %s", p.Steps[0].ID)
	}
}

func TestSSHKeyLine(t *testing.T) {
	r := newRig(t)
	k, err := r.svc.GenSSHKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := `restrict,command="/usr/local/sbin/serp-run" ssh-ed25519 FAKE serpantinum`
	if k.Line != want {
		t.Fatalf("line = %q", k.Line)
	}
	if k.Path != "~/.config/serpantinum/servers/id_serp" {
		t.Fatalf("path = %q", k.Path)
	}
	// second call reuses the key
	before, _ := os.ReadFile(filepath.Join(r.Home, ".config/serpantinum/servers/id_serp"))
	if _, err := r.svc.GenSSHKey(context.Background()); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(filepath.Join(r.Home, ".config/serpantinum/servers/id_serp"))
	if string(before) != string(after) {
		t.Fatal("the key must not be regenerated")
	}
	p, err := r.svc.SaveAuthorizedKeys(k.Line)
	if err != nil || p != "~/serp-authorized_keys.txt" {
		t.Fatalf("%v %q", err, p)
	}
	if b, _ := os.ReadFile(filepath.Join(r.Home, "serp-authorized_keys.txt")); strings.TrimSpace(string(b)) != want {
		t.Fatalf("file = %q", b)
	}
}

func TestConfigMapping(t *testing.T) {
	r := newRig(t)
	f := config.Defaults()
	f.Preset = "custom"
	f.Modules = []string{"core", "vpn"}
	f.Lang = "ru"
	f.Options.VPNMode = "all"
	f.Options.VPNKillswitch = true
	req, err := app.RequestFromConfig(&f, config.Resolved{config.SecVPNSubscription: "https://sub.invalid/X"}, r.svc.Set(), nil, "b.tar.zst")
	if err != nil {
		t.Fatal(err)
	}
	if req.Secrets["vpn.subscription"] != "https://sub.invalid/X" || req.Config["vpn.mode"] != "all" || req.Config["vpn.killswitch"] != "true" || req.Restore != "b.tar.zst" {
		t.Fatalf("req = %+v", req.Config)
	}
	back := app.ConfigFromRequest(req)
	data, err := back.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "sub.invalid") {
		t.Fatal("secrets must never be exported")
	}
	if _, err := config.Parse(data, config.ParseOptions{Known: []string{"core", "vpn"}}); err != nil {
		t.Fatalf("exported file does not parse: %v\n%s", err, data)
	}
	f.Modules = []string{"nope"}
	if _, err := app.RequestFromConfig(&f, nil, r.svc.Set(), nil, ""); err == nil {
		t.Fatal("unknown module must fail")
	}
}

func TestPresetFromConfigUsesDetectedHardware(t *testing.T) {
	r := newRig(t)
	f := config.Defaults()
	req, err := app.RequestFromConfig(&f, nil, r.svc.Set(), []string{"gpu:nvidia"}, "")
	if err != nil {
		t.Fatal(err)
	}
	if !contains(req.Modules, "nvidia") || contains(req.Modules, "sddm") {
		t.Fatalf("modules = %v", req.Modules)
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

func TestRunHonoursCancel(t *testing.T) {
	r := newRig(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := r.svc.RunPlain(ctx, tui.Request{Mode: tui.ModeInstall, Modules: minimal, Config: map[string]string{}}, r.plainOpts(plain.PolicyAbort))
	if err == nil {
		t.Fatal("a cancelled run must fail")
	}
	_ = time.Second
}

// uninstall must work when no payload can be found (the user deleted the
// unpacked release; only the installed state is needed to remove things).
func TestUninstallWithoutPayload(t *testing.T) {
	r := newRig(t)
	if _, err := r.install(minimal, nil); err != nil {
		t.Fatalf("%v\n%s", err, r.out)
	}
	cfg := r.Cfg
	cfg.Payload = filepath.Join(t.TempDir(), "gone")
	cfg.Exe, cfg.Cwd = "", t.TempDir()
	svc, err := app.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	r.out.Reset()
	if _, err := svc.RunPlain(context.Background(), tui.Request{Mode: tui.ModeUninstall, Lang: "en"}, r.plainOpts(plain.PolicyAbort)); err != nil {
		t.Fatalf("uninstall without payload: %v\n%s", err, r.out)
	}
	if svc.Installed() != nil {
		t.Fatal("installed.toml must be gone")
	}
}
