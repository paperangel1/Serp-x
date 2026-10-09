package xlog_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/xlog"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

var fixed = func() time.Time {
	return time.Date(2026, 10, 7, 19, 5, 2, 0, time.FixedZone("", 3*3600))
}

func newLog(t *testing.T, extra map[string]string, opts ...xlog.Option) (*xlog.Logger, string) {
	t.Helper()
	home := t.TempDir()
	e := map[string]string{"HOME": home}
	for k, v := range extra {
		e[k] = v
	}
	l := xlog.New("installer", env(e), append([]xlog.Option{xlog.WithClock(fixed)}, opts...)...)
	return l, home
}

func read(t *testing.T, l *xlog.Logger) string {
	t.Helper()
	b, err := os.ReadFile(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestLineFormatMatchesXlogPy(t *testing.T) {
	l, home := newLog(t, nil)
	l.Info("step done", "step", "pkg.repo", "note", "two words", "n", 3)
	got := read(t, l)
	want := `2026-10-07T19:05:02+03:00 INFO installer step done step=pkg.repo note="two words" n=3` + "\n"
	if got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
	if l.Path() != filepath.Join(home, ".local/state/serpantinum/logs/installer.log") {
		t.Errorf("path %s", l.Path())
	}
	re := regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d (DEBUG|INFO|WARN|ERROR) installer .+`)
	if !re.MatchString(got) {
		t.Error("format regexp")
	}
}

func TestPermissionsAndEnvDirs(t *testing.T) {
	state := t.TempDir()
	l, _ := newLog(t, map[string]string{"XDG_STATE_HOME": state})
	l.Info("x")
	if l.Path() != filepath.Join(state, "serpantinum/logs/installer.log") {
		t.Errorf("path %s", l.Path())
	}
	d, _ := os.Stat(filepath.Dir(l.Path()))
	f, _ := os.Stat(l.Path())
	if d.Mode().Perm() != 0o700 || f.Mode().Perm() != 0o600 {
		t.Errorf("modes %v %v", d.Mode().Perm(), f.Mode().Perm())
	}
	dir := t.TempDir()
	l2, _ := newLog(t, map[string]string{"SERPANTINUM_LOG_DIR": dir})
	if l2.Path() != filepath.Join(dir, "installer.log") {
		t.Errorf("path %s", l2.Path())
	}
}

func TestLevels(t *testing.T) {
	l, _ := newLog(t, nil)
	l.Debug("hidden")
	l.Warn("w")
	l.Error("e")
	got := read(t, l)
	if strings.Contains(got, "hidden") || !strings.Contains(got, " WARN installer w") || !strings.Contains(got, " ERROR installer e") {
		t.Errorf("%q", got)
	}
	d, _ := newLog(t, map[string]string{"XLOG_LEVEL": "debug"})
	d.Debug("shown")
	if !strings.Contains(read(t, d), "DEBUG installer shown") {
		t.Error("XLOG_LEVEL=debug ignored")
	}
}

func TestLevelFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".level"), []byte("error\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	l := xlog.New("installer", env(map[string]string{"SERPANTINUM_LOG_DIR": dir}))
	l.Warn("no")
	l.Error("yes")
	b, _ := os.ReadFile(l.Path())
	if strings.Contains(string(b), "no") || !strings.Contains(string(b), "yes") {
		t.Errorf("%q", b)
	}
}

func TestMultilineIsIndented(t *testing.T) {
	l, _ := newLog(t, nil)
	l.Error("boom\nline2\nline3")
	if !strings.HasSuffix(read(t, l), "boom\n    line2\n    line3\n") {
		t.Errorf("%q", read(t, l))
	}
}

func TestRotation(t *testing.T) {
	l, _ := newLog(t, nil, xlog.WithMaxBytes(200))
	for i := 0; i < 40; i++ {
		l.Info("filler line to grow the file", "i", i)
	}
	dir := filepath.Dir(l.Path())
	for _, n := range []string{"installer.log", "installer.log.1", "installer.log.2"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Errorf("missing %s", n)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "installer.log.3")); err == nil {
		t.Error("more than 3 files kept")
	}
}

func TestRedactionOfRegisteredSecretsAndPatterns(t *testing.T) {
	l, _ := newLog(t, nil)
	const gem = "AIzaFAKEfakeFAKEfakeFAKEfakeFAKE12345"
	const tok = "tok-FAKE-9f8e7d6c5b4a"
	const sub = "https://panel.example.invalid/sub/FAKEFAKEFAKE"
	l.AddSecret(tok)
	l.AddSecret(sub)
	l.Info("got "+gem+" and "+tok, "url", sub, "gemini", gem)
	l.Info("vless://11111111-2222-3333-4444-555555555555@h.example:443?x=1#n")
	l.Info("header Authorization: Bearer abcdef0123456789xyz")
	l.Info("config", "remnawave_token", "plainvalue123")
	l.Info("password=hunter2hunter2 next")
	l.Error("key dump\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAFAKE\n-----END OPENSSH PRIVATE KEY-----")
	got := read(t, l)
	for _, leak := range []string{gem, tok, sub, "11111111-2222", "abcdef0123456789xyz", "plainvalue123", "hunter2hunter2", "AAAAFAKE", "BEGIN OPENSSH"} {
		if strings.Contains(got, leak) {
			t.Errorf("leaked %q in:\n%s", leak, got)
		}
	}
	if !strings.Contains(got, xlog.Redacted) {
		t.Error("no redaction marker")
	}
	if !strings.Contains(got, "next") {
		t.Error("over-redacted the rest of the line")
	}
}

func TestShortSecretsIgnoredAndNoPanicOnBadDir(t *testing.T) {
	l, _ := newLog(t, nil)
	l.AddSecret("ab")
	l.Info("about the lab")
	if !strings.Contains(read(t, l), "about the lab") {
		t.Error("short secret shredded the log")
	}
	f := filepath.Join(t.TempDir(), "file")
	_ = os.WriteFile(f, nil, 0o600)
	bad := xlog.New("installer", env(nil), xlog.WithDir(filepath.Join(f, "sub"))) // parent is a file
	bad.Info("must not panic")
}

func TestBadModuleNameFallsBackToMisc(t *testing.T) {
	l := xlog.New("../evil", env(map[string]string{"HOME": t.TempDir()}))
	if filepath.Base(l.Path()) != "misc.log" {
		t.Error(l.Path())
	}
}
