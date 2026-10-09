package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/app"
	"serpx/installer/internal/app/apptest"
)

var testStart = time.Now()

const (
	fakeKey   = "AIzaFAKE0000000000000000000000000000"
	fakeToken = "FAKE-TOKEN-SECRET-0000"
)

// cli runs the program against the simulated machine.
type cli struct {
	t   *testing.T
	r   *apptest.Rig
	fin []string // final actions requested
	tty bool
	in  string
}

func newCLI(t *testing.T) *cli {
	c := &cli{t: t, r: apptest.New(t)}
	testConfig = func(cfg *app.Config) {
		g := cfg.Glyphs
		*cfg = c.r.Cfg
		cfg.Glyphs = g
	}
	finishHook = func(a string) error { c.fin = append(c.fin, a); return nil }
	stdin = strings.NewReader("")
	isTTY = func(any) bool { return c.tty }
	t.Cleanup(func() {
		testConfig = nil
		finishHook = realFinish
		stdin = os.Stdin
		isTTY = func(v any) bool { return false }
	})
	return c
}

func (c *cli) run(args ...string) (code int, out, errOut string) {
	var o, e bytes.Buffer
	if c.in != "" {
		stdin = strings.NewReader(c.in)
	}
	code = run(args, &o, &e, c.r.Getenv)
	return code, o.String(), e.String()
}

func (c *cli) must(args ...string) string {
	c.t.Helper()
	code, out, errOut := c.run(args...)
	if code != 0 {
		c.t.Fatalf("%v: exit %d\nstdout:\n%s\nstderr:\n%s", args, code, out, errOut)
	}
	return out
}

func (c *cli) installed() bool {
	_, err := os.Stat(filepath.Join(c.r.Home, ".local/state/serpantinum-installer/installed.toml"))
	return err == nil
}

func TestInstallPlainMinimal(t *testing.T) {
	c := newCLI(t)
	out := c.must("install", "--plain", "--yes", "--preset", "minimal")
	for _, want := range []string{"System check:", "Plan: ", "Installation finished.", "Log: "} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if !c.installed() {
		t.Fatal("installed.toml missing")
	}
	if len(c.fin) != 0 {
		t.Fatalf("no final action expected, got %v", c.fin)
	}
}

func TestInstallFromConfigWithSecretRefs(t *testing.T) {
	c := newCLI(t)
	keyFile := filepath.Join(c.r.Home, "gemini")
	os.WriteFile(keyFile, []byte(fakeKey+"\n"), 0o600)
	c.r.Env["SERP_TOKEN"] = fakeToken
	cfg := filepath.Join(c.r.Home, "my-setup.toml")
	os.WriteFile(cfg, []byte(`schema = 1
lang = "en"
preset = "custom"
modules = ["core", "ai-gemini", "servers"]
[secrets]
gemini_key = "file:`+keyFile+`"
remnawave_url = ""
remnawave_token = "env:SERP_TOKEN"
[run]
on_error = "abort"
finish = "reboot"
`), 0o600)
	out := c.must("install", "--config", cfg, "--yes", "--plain")
	for _, s := range []string{fakeKey, fakeToken} {
		if strings.Contains(out, s) {
			t.Fatalf("secret in the output")
		}
	}
	b, err := os.ReadFile(filepath.Join(c.r.Home, ".config/serpantinum/secrets/gemini_key"))
	if err != nil || strings.TrimSpace(string(b)) != fakeKey {
		t.Fatalf("gemini key not stored: %v", err)
	}
	b, err = os.ReadFile(filepath.Join(c.r.Home, ".config/serpantinum/secrets/remnawave_token"))
	if err != nil || strings.TrimSpace(string(b)) != fakeToken {
		t.Fatalf("token not stored: %v", err)
	}
	if len(c.fin) != 1 || c.fin[0] != "reboot" {
		t.Fatalf("finish = %v", c.fin)
	}
}

func TestConfigErrors(t *testing.T) {
	c := newCLI(t)
	cfg := filepath.Join(c.r.Home, "bad.toml")
	os.WriteFile(cfg, []byte("schema = 1\n[secrets]\ngemini_key = \""+fakeKey+"\"\n"), 0o600)
	code, out, errOut := c.run("install", "--config", cfg, "--yes", "--plain")
	if code != exitUsage {
		t.Fatalf("code %d\n%s\n%s", code, out, errOut)
	}
	if strings.Contains(out+errOut, fakeKey) {
		t.Fatal("a literal secret was echoed")
	}
	if c.installed() {
		t.Fatal("nothing may run on a bad config")
	}
	code, _, errOut = c.run("install", "--config", filepath.Join(c.r.Home, "nope.toml"), "--yes")
	if code != exitUsage || errOut == "" {
		t.Fatalf("missing file: %d %q", code, errOut)
	}
}

func TestModesNeedInstallation(t *testing.T) {
	c := newCLI(t)
	for _, m := range []string{"repair", "modules", "uninstall", "reconcile"} {
		code, _, errOut := c.run(m, "--plain", "--yes")
		if code != exitFailure || !strings.Contains(errOut, "Nothing is installed") {
			t.Errorf("%s: %d %q", m, code, errOut)
		}
	}
}

func TestRepairModulesReconcileUninstall(t *testing.T) {
	c := newCLI(t)
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	c.must("repair", "--plain", "--yes")
	c.must("reconcile", "--yes")
	if code, _, _ := c.run("modules", "--plain", "--yes"); code != exitUsage {
		t.Fatalf("modules without a list: %d", code)
	}
	out := c.must("modules", "--plain", "--yes", "--preset", "custom", "--modules", "core,emoji,hotkeys,tools")
	if !strings.Contains(out, "Plan: ") {
		t.Fatal(out)
	}
	b, _ := os.ReadFile(filepath.Join(c.r.Home, ".local/state/serpantinum-installer/installed.toml"))
	if !strings.Contains(string(b), "tools") {
		t.Fatalf("installed.toml:\n%s", b)
	}
	// uninstall needs --yes
	if code, _, errOut := c.run("uninstall", "--plain"); code != exitUsage || !strings.Contains(errOut, "--yes") {
		t.Fatalf("uninstall without --yes: %d %q", code, errOut)
	}
	c.must("uninstall", "--plain", "--yes")
	if c.installed() {
		t.Fatal("installed.toml must be gone")
	}
}

func TestBackupExportImport(t *testing.T) {
	c := newCLI(t)
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	os.MkdirAll(filepath.Join(c.r.Home, ".config/serpantinum/commands"), 0o755)
	os.WriteFile(filepath.Join(c.r.Home, ".config/serpantinum/commands/a.cmd.json"), []byte("{}"), 0o644)
	dir := filepath.Join(c.r.Home, "out")
	out := c.must("backup", "export", "--out", dir)
	if !strings.Contains(out, "Backup written: "+dir) {
		t.Fatal(out)
	}
	arch, _ := filepath.Glob(filepath.Join(dir, "serpantinum-backup-*"))
	if len(arch) != 1 {
		t.Fatalf("archives %v", arch)
	}
	os.Remove(filepath.Join(c.r.Home, ".config/serpantinum/commands/a.cmd.json"))
	out = c.must("backup", "import", arch[0])
	if !strings.Contains(out, "Files restored: ") {
		t.Fatal(out)
	}
	if _, err := os.Stat(filepath.Join(c.r.Home, ".config/serpantinum/commands/a.cmd.json")); err != nil {
		t.Fatalf("not restored: %v", err)
	}
	if code, _, _ := c.run("backup", "import"); code != exitUsage {
		t.Fatalf("import without a file: %d", code)
	}
}

func TestExportConfigHasNoSecrets(t *testing.T) {
	c := newCLI(t)
	c.must("install", "--plain", "--yes", "--preset", "custom", "--modules", "core,ai-gemini")
	os.WriteFile(filepath.Join(c.r.Home, ".config/serpantinum/secrets/gemini_key"), []byte(fakeKey), 0o600)
	out := c.must("export-config")
	if !strings.Contains(out, "schema = 1") || !strings.Contains(out, "ai-gemini") || strings.Contains(out, fakeKey) {
		t.Fatalf("export:\n%s", out)
	}
	file := filepath.Join(c.r.Home, "my.toml")
	c.must("export-config", "--out", file)
	if st, err := os.Stat(file); err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("file: %v %v", err, st)
	}
	// the file loads again
	c.must("install", "--config", file, "--yes", "--plain")
}

func TestInteractiveDetection(t *testing.T) {
	c := newCLI(t)
	c.tty = true
	var o options
	cx := &runCtx{o: &o, mode: "install", getenv: c.r.Getenv, stdout: os.Stdout}
	if !cx.interactive() {
		t.Fatal("a terminal must get the full-screen UI")
	}
	for name, mod := range map[string]func(){
		"--plain":  func() { o.plain = true },
		"--yes":    func() { o.yes = true },
		"--config": func() { o.config = "x" },
		"dumb":     func() { c.r.Env["TERM"] = "dumb" },
	} {
		o = options{}
		c.r.Env["TERM"] = "xterm-256color"
		mod()
		if cx.interactive() {
			t.Errorf("%s must select the plain output", name)
		}
	}
	o = options{}
	c.r.Env["TERM"] = "xterm-256color"
	c.tty = false
	if cx.interactive() {
		t.Error("no terminal: plain")
	}
}

func TestPlainAsksOnErrorWhenInteractiveInput(t *testing.T) {
	c := newCLI(t)
	c.r.Sim.FailOn("fc-cache", os.ErrPermission, -1)
	c.tty = true // stdin is a terminal: policy ask
	c.in = "s\n"
	out := c.must("install", "--plain", "--preset", "custom", "--modules", "core,emoji")
	if !strings.Contains(out, "Step emoji.cache failed") && !strings.Contains(out, "failed") {
		t.Fatalf("no question:\n%s", out)
	}
	if !strings.Contains(out, "Skipped: emoji") {
		t.Fatalf("skip not reported:\n%s", out)
	}
}

func TestStateStaysInTempHome(t *testing.T) {
	c := newCLI(t)
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	real, _ := os.UserHomeDir()
	if real == "" || real == c.r.Home {
		return
	}
	// the run must not have created the installer state under the real home
	if _, err := os.Stat(filepath.Join(real, ".local/state/serpantinum-installer/installed.toml")); err == nil {
		// it may exist from the user's real use: only fail if it is newer than the test
		st, _ := os.Stat(filepath.Join(real, ".local/state/serpantinum-installer/installed.toml"))
		if st != nil && st.ModTime().After(testStart) {
			t.Fatal("the real home was touched")
		}
	}
}

// --reinstall (config / plain mode) must make the automatic backup before redeploying.
func TestReinstallFlagMakesBackup(t *testing.T) {
	c := newCLI(t)
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	matches := func() []string {
		m, _ := filepath.Glob(filepath.Join(c.r.Home, "serpantinum-backups", "*.tar.zst"))
		return m
	}
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	if len(matches()) != 0 {
		t.Fatalf("plain update must not back up: %v", matches())
	}
	c.must("install", "--plain", "--yes", "--preset", "minimal", "--reinstall")
	if len(matches()) == 0 {
		t.Fatal("no backup archive after --reinstall")
	}
}

// An install over an original (upstream) Serpantinum install backs up first and converts it.
func TestInstallOverUpstreamBacksUp(t *testing.T) {
	c := newCLI(t)
	st := filepath.Join(c.r.Home, ".local/state/serpantinum")
	if err := os.MkdirAll(st, 0o755); err != nil {
		t.Fatal(err)
	}
	up := "SERPANTINUM_VERSION=\"2.2.4\"\nSERPANTINUM_COMMIT=\"fa37106\"\nSELECTED_COMPOSITORS=\"hyprland\"\n"
	if err := os.WriteFile(filepath.Join(st, "version"), []byte(up), 0o644); err != nil {
		t.Fatal(err)
	}
	c.must("install", "--plain", "--yes", "--preset", "minimal")
	m, _ := filepath.Glob(filepath.Join(c.r.Home, "serpantinum-backups", "*.tar.zst"))
	if len(m) == 0 {
		t.Fatal("no automatic backup over an upstream install")
	}
	b, _ := os.ReadFile(filepath.Join(st, "version"))
	if !strings.Contains(string(b), "SERPANTINUM_FORK_COMMIT") {
		t.Fatalf("version file not converted: %s", b)
	}
}
