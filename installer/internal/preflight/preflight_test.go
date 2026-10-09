package preflight

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/journal"
	"serpx/installer/internal/run"
)

var fixedNow = time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)

type fakeNet struct {
	down  map[string]bool
	speed float64
}

func (f fakeNet) Head(_ context.Context, u string) error {
	for h := range f.down {
		if strings.Contains(u, h) {
			return errors.New("down")
		}
	}
	return nil
}
func (f fakeNet) Speed(context.Context) (float64, error) {
	if f.speed == 0 {
		return 0, errors.New("x")
	}
	return f.speed, nil
}

type env struct {
	d    Deps
	home string
	sys  string
	fr   *run.FakeRunner
	free map[string]uint64
	bins map[string]bool
	vars map[string]string
	uid  int
}

func w(t *testing.T, p, s string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func gpu(t *testing.T, sys, addr, vendor, class string) {
	w(t, filepath.Join(sys, "bus/pci/devices", addr, "vendor"), vendor+"\n")
	w(t, filepath.Join(sys, "bus/pci/devices", addr, "class"), class+"\n")
}

func newEnv(t *testing.T) *env {
	root := t.TempDir()
	e := &env{home: filepath.Join(root, "home"), sys: filepath.Join(root, "sys"), fr: run.NewFake(),
		free: map[string]uint64{}, bins: map[string]bool{"pacman": true, "sudo": true, "yay": true, "setfont": true},
		vars: map[string]string{"TERM": "xterm-256color"}, uid: 1000}
	os.MkdirAll(e.home, 0o755)
	osr := filepath.Join(root, "os-release")
	w(t, osr, "NAME=\"Arch Linux\"\nID=arch\n")
	mem := filepath.Join(root, "meminfo")
	w(t, mem, "MemTotal:       16000000 kB\nMemFree: 1 kB\n")
	for _, p := range []string{"/", "/var/cache/pacman", e.home} {
		e.free[p] = 50 << 30
	}
	e.fr.OnPrefix("pacman -Qi archlinux-keyring", run.Reply{Result: run.Result{Stdout: "Name : archlinux-keyring\nBuild Date     : Tue 29 Sep 2026 10:00:00 AM UTC\n"}}, false)
	e.d = Deps{
		OSRelease: osr, SysRoot: e.sys, ProcMeminfo: mem, Home: e.home, StateDir: filepath.Join(e.home, "state"),
		Getenv:  func(k string) string { return e.vars[k] },
		Geteuid: func() int { return e.uid },
		LookPath: func(n string) (string, error) {
			if e.bins[n] {
				return "/usr/bin/" + n, nil
			}
			return "", errors.New("not found")
		},
		Statfs: func(p string) (uint64, error) { return e.free[p], nil },
		Runner: e.fr, Net: fakeNet{speed: 5e6}, Now: func() time.Time { return fixedNow },
	}
	return e
}

func (e *env) run(t *testing.T, o Options) Report { return Run(context.Background(), e.d, o) }

func st(t *testing.T, r Report, id string) Status {
	c, ok := r.Get(id)
	if !ok {
		t.Fatalf("no check %s", id)
	}
	return c.Status
}

func TestHappyPath(t *testing.T) {
	e := newEnv(t)
	gpu(t, e.sys, "0000:01:00.0", "0x1002", "0x030000")
	r := e.run(t, Options{NeedBytes: 2 << 30})
	if !r.OKToProceed() {
		t.Fatalf("%+v", r.Failed())
	}
	if len(r.Checks) != 13 {
		t.Fatalf("%d checks", len(r.Checks))
	}
	if r.Facts.GPUs[0] != "amd" || r.Facts.AURHelper != "yay" || r.Facts.NetSpeedBps != 5e6 || r.Facts.Install != InstallNone || r.Facts.KeyringStale {
		t.Fatalf("%+v", r.Facts)
	}
	for _, c := range r.Checks {
		if c.Text("ru") == "" || c.Text("en") == c.Code || strings.Contains(c.Text("en"), "%!") {
			t.Errorf("bad message %+v: %q", c, c.Text("en"))
		}
	}
	if got := e.fr.Calls(); got[0] != "sudo -v" {
		t.Fatalf("calls %v", got)
	}
}

func TestEveryMessageCodeFormats(t *testing.T) {
	for code, m := range messages {
		if m.ru == "" || m.en == "" {
			t.Errorf("%s empty", code)
		}
		if strings.Count(m.ru, "%") != strings.Count(m.en, "%") {
			t.Errorf("%s: placeholder mismatch", code)
		}
	}
}

func TestGPUDetect(t *testing.T) {
	e := newEnv(t)
	gpu(t, e.sys, "0000:00:02.0", "0x8086", "0x030000")
	gpu(t, e.sys, "0000:01:00.0", "0x10de", "0x030200")
	gpu(t, e.sys, "0000:00:1f.3", "0x8086", "0x040300") // audio, not a display
	gpu(t, e.sys, "0000:02:00.0", "0x10de", "0x040300") // nvidia HDMI audio
	r := e.run(t, Options{})
	if strings.Join(r.Facts.GPUs, ",") != "intel,nvidia" {
		t.Fatalf("%v", r.Facts.GPUs)
	}
	if st(t, r, CheckGPU) != Warn || strings.Join(r.Facts.Tags(), ",") != "gpu:intel,gpu:nvidia" {
		t.Fatalf("%v", r.Facts.Tags())
	}
	e2 := newEnv(t)
	if r := e2.run(t, Options{}); r.Facts.GPUs == nil || len(r.Facts.GPUs) != 0 || st(t, r, CheckGPU) != OK {
		t.Fatal("no gpu must be ok (VM)")
	}
}

func TestArchChecks(t *testing.T) {
	e := newEnv(t)
	w(t, e.d.OSRelease, "ID=manjaro\nID_LIKE=\"arch\"\n")
	if st(t, e.run(t, Options{}), CheckArch) != OK {
		t.Fatal("ID_LIKE=arch must pass")
	}
	w(t, e.d.OSRelease, "ID=ubuntu\nID_LIKE=debian\n")
	r := e.run(t, Options{})
	if st(t, r, CheckArch) != Fail || r.OKToProceed() {
		t.Fatal("ubuntu must fail")
	}
	w(t, e.d.OSRelease, "ID=arch\n")
	delete(e.bins, "pacman")
	if c, _ := e.run(t, Options{}).Get(CheckArch); c.Code != "arch.nopacman" {
		t.Fatal(c)
	}
}

func TestRootAndSudo(t *testing.T) {
	e := newEnv(t)
	e.uid = 0
	if st(t, e.run(t, Options{}), CheckRoot) != Fail {
		t.Fatal("root must fail")
	}
	e = newEnv(t)
	e.fr.OnPrefix("sudo -v", run.Reply{Err: errors.New("denied")}, false)
	if st(t, e.run(t, Options{}), CheckSudo) != Fail {
		t.Fatal("sudo denied")
	}
	e = newEnv(t)
	delete(e.bins, "sudo")
	if c, _ := e.run(t, Options{}).Get(CheckSudo); c.Code != "sudo.missing" {
		t.Fatal(c)
	}
	e = newEnv(t)
	e.run(t, Options{SkipSudo: true})
	for _, c := range e.fr.Calls() {
		if strings.HasPrefix(c, "sudo") {
			t.Fatal("sudo ran despite SkipSudo")
		}
	}
}

func TestNetwork(t *testing.T) {
	e := newEnv(t)
	e.d.Net = fakeNet{down: map[string]bool{"archlinux.org": true, "github.com": true}}
	r := e.run(t, Options{})
	if st(t, r, CheckNet) != Fail || r.OKToProceed() {
		t.Fatal("no network must fail")
	}
	e.d.Net = fakeNet{down: map[string]bool{"github.com": true}}
	if st(t, e.run(t, Options{}), CheckNet) != Warn {
		t.Fatal("github only: warn")
	}
	e.d.Net = fakeNet{down: map[string]bool{"archlinux.org": true}}
	if st(t, e.run(t, Options{}), CheckNet) != Fail {
		t.Fatal("archlinux.org down: fail")
	}
	e.d.Net = fakeNet{}
	if st(t, e.run(t, Options{}), CheckNet) != Warn {
		t.Fatal("no speed: warn")
	}
	e.d.Net = fakeNet{down: map[string]bool{"archlinux.org": true, "github.com": true}}
	if _, ok := e.run(t, Options{SkipNet: true}).Get(CheckNet); ok {
		t.Fatal("SkipNet still checked")
	}
}

func TestDisk(t *testing.T) {
	e := newEnv(t)
	e.free["/var/cache/pacman"] = 1 << 30 // need 3 GiB
	r := e.run(t, Options{NeedBytes: 2 << 30})
	c, _ := r.Get(CheckDisk)
	if c.Status != Fail || !strings.Contains(c.Text("en"), "/var/cache/pacman: 1024/3072 MiB") || strings.Contains(c.Text("en"), "home") {
		t.Fatalf("%v", c.Text("en"))
	}
	e.free["/var/cache/pacman"] = 3 << 30
	if st(t, e.run(t, Options{NeedBytes: 2 << 30}), CheckDisk) != OK {
		t.Fatal("exact fit")
	}
}

func TestRAM(t *testing.T) {
	e := newEnv(t)
	w(t, e.d.ProcMeminfo, "MemTotal:        2048000 kB\n")
	if st(t, e.run(t, Options{}), CheckRAM) != Warn {
		t.Fatal("2 GB must warn")
	}
	w(t, e.d.ProcMeminfo, "MemTotal:        3900000 kB\n") // a "4 GB" machine
	if st(t, e.run(t, Options{}), CheckRAM) != OK {
		t.Fatal("4 GB machine must pass")
	}
	os.Remove(e.d.ProcMeminfo)
	if st(t, e.run(t, Options{}), CheckRAM) != Warn {
		t.Fatal("unknown: warn")
	}
}

func TestInstallKinds(t *testing.T) {
	e := newEnv(t)
	check := func(want InstallKind, ver string) {
		t.Helper()
		r := e.run(t, Options{})
		if r.Facts.Install != want || r.Facts.Version != ver {
			t.Fatalf("got %s %q, want %s %q", r.Facts.Install, r.Facts.Version, want, ver)
		}
	}
	check(InstallNone, "")
	w(t, e.home+"/.local/state/imperative-dots-version", "1.0\n")
	check(InstallLegacy, "")
	w(t, e.home+"/.local/state/serpantinum/version", "SERPANTINUM_VERSION=2.2.4\nSERPANTINUM_COMMIT=abc\n")
	check(InstallUpstream, "2.2.4")
	w(t, e.home+"/.local/state/serpantinum/version", "SERPANTINUM_VERSION=2.2.4-s3\nSERPANTINUM_COMMIT=abc\nSERPANTINUM_FORK_COMMIT=def\n")
	check(InstallSerpX, "2.2.4-s3")
}

func TestHyprAURResumeKeyring(t *testing.T) {
	e := newEnv(t)
	w(t, e.home+"/.config/hypr/hyprland.conf", "x")
	r := e.run(t, Options{})
	if st(t, r, CheckHypr) != Warn || !r.Facts.HyprOldConf {
		t.Fatal("old conf")
	}
	w(t, e.home+"/.config/hypr/hyprland.lua", "x")
	if st(t, e.run(t, Options{}), CheckHypr) != OK {
		t.Fatal("lua present")
	}

	delete(e.bins, "yay")
	e.bins["paru"] = true
	if e.run(t, Options{}).Facts.AURHelper != "paru" {
		t.Fatal("paru")
	}
	delete(e.bins, "paru")
	r = e.run(t, Options{})
	if r.Facts.AURHelper != "" {
		t.Fatal("none")
	}
	if c, _ := r.Get(CheckAUR); c.Code != "aur.none" {
		t.Fatal(c)
	}

	// unfinished journal
	os.MkdirAll(e.d.StateDir, 0o700)
	w(t, e.d.StateDir+"/"+journal.FilePlan, "{}")
	w(t, e.d.StateDir+"/"+journal.FileJournal, "")
	if !e.run(t, Options{}).Facts.NeedsResume {
		t.Fatal("resume expected")
	}

	// keyring: 40 days old, then garbage
	e.fr = run.NewFake()
	e.d.Runner = e.fr
	e.fr.OnPrefix("pacman -Qi archlinux-keyring", run.Reply{Result: run.Result{Stdout: "Build Date     : Mon 24 Aug 2026 10:00:00 AM UTC\n"}}, false)
	if !e.run(t, Options{}).Facts.KeyringStale {
		t.Fatal("stale keyring")
	}
	e.fr = run.NewFake()
	e.d.Runner = e.fr
	e.fr.OnPrefix("pacman -Qi archlinux-keyring", run.Reply{Result: run.Result{Stdout: "Build Date : gibberish\n"}}, false)
	if !e.run(t, Options{}).Facts.KeyringStale {
		t.Fatal("unparsable counts as stale")
	}
	for _, c := range e.fr.Recorded() {
		if c.Name == "pacman" && (len(c.Env) != 1 || c.Env[0] != "LC_ALL=C" || c.Root) {
			t.Fatalf("pacman call %+v", c)
		}
	}
}

func TestConsole(t *testing.T) {
	e := newEnv(t)
	e.vars["TERM"] = "linux"
	c := e.run(t, Options{Lang: "ru"}).Facts.Console
	if c.Glyph != "ascii" || c.Colors != 16 || !c.SetFont || c.Lang != "ru" || c.Plain {
		t.Fatalf("%+v", c)
	}
	delete(e.bins, "setfont")
	if c := e.run(t, Options{Lang: "ru"}).Facts.Console; c.SetFont || c.Lang != "en" {
		t.Fatalf("no setfont => en: %+v", c)
	}
	e.bins["setfont"] = true
	if c := e.run(t, Options{Lang: "en"}).Facts.Console; c.SetFont {
		t.Fatal("en needs no font")
	}
	e.vars["TERM"] = "dumb"
	if c := e.run(t, Options{}).Facts.Console; !c.Plain || c.Colors != 0 {
		t.Fatalf("%+v", c)
	}
	e.vars["TERM"] = "xterm-256color"
	if c := e.run(t, Options{Glyphs: "nerd"}).Facts.Console; c.Glyph != "nerd" || c.Colors != 256 {
		t.Fatalf("%+v", c)
	}
	e.vars["NO_COLOR"] = "1"
	if c := e.run(t, Options{}).Facts.Console; c.Colors != 0 {
		t.Fatal("NO_COLOR")
	}
}

func TestApplyConsole(t *testing.T) {
	fr := run.NewFake()
	if l := ApplyConsole(context.Background(), fr, Console{SetFont: true, Lang: "ru"}); l != "ru" || fr.Calls()[0] != "setfont cyr-sun16" {
		t.Fatal(l, fr.Calls())
	}
	fr = run.NewFake()
	fr.OnPrefix("setfont", run.Reply{Err: errors.New("no")}, false)
	if ApplyConsole(context.Background(), fr, Console{SetFont: true, Lang: "ru"}) != "en" {
		t.Fatal("fallback to en")
	}
	if ApplyConsole(context.Background(), fr, Console{Lang: "ru"}) != "ru" {
		t.Fatal("no font needed")
	}
}

func TestHTTPProbe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/bad" {
			w.WriteHeader(503)
			return
		}
		w.Write(make([]byte, 2<<20))
	}))
	defer srv.Close()
	p := HTTPProbe{SpeedURL: srv.URL + "/f"}
	if err := p.Head(context.Background(), srv.URL); err != nil {
		t.Fatal(err)
	}
	if err := p.Head(context.Background(), srv.URL+"/bad"); err == nil {
		t.Fatal("503 must fail")
	}
	if sp, err := p.Speed(context.Background()); err != nil || sp <= 0 {
		t.Fatalf("%v %v", sp, err)
	}
	if err := p.Head(context.Background(), "http://127.0.0.1:1"); err == nil {
		t.Fatal("closed port")
	}
}
