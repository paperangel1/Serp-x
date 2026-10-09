package fsx

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setup(t *testing.T) (*FS, string, string) {
	t.Helper()
	home := t.TempDir()
	state := filepath.Join(t.TempDir(), "state")
	f, err := New(Config{Allowed: []string{filepath.Join(home, ".config/serp"), filepath.Join(home, ".bashrc")}, StateDir: state, Run: "r1"})
	if err != nil {
		t.Fatal(err)
	}
	return f, home, state
}

func TestOutsideAllowedRejected(t *testing.T) {
	f, home, _ := setup(t)
	bad := []string{
		filepath.Join(home, "other.txt"),
		filepath.Join(home, ".config/serp/../evil"),
		filepath.Join(home, ".config/serpent/x"), // prefix-but-not-child
		"/etc/passwd",
		"relative/path",
	}
	for _, p := range bad {
		if err := f.Write("m", p, []byte("x"), 0o644); !errors.Is(err, ErrNotAllowed) {
			t.Errorf("%s: err=%v", p, err)
		}
	}
	if _, err := os.Stat(filepath.Join(home, "other.txt")); err == nil {
		t.Fatal("file written")
	}
	// symlink escape
	outside := t.TempDir()
	os.MkdirAll(filepath.Join(home, ".config"), 0o755)
	os.Symlink(outside, filepath.Join(home, ".config/serp"))
	if err := f.Write("m", filepath.Join(home, ".config/serp/x"), []byte("x"), 0o644); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("symlink escape: %v", err)
	}
}

func TestWriteCreatesAndRollbackRemoves(t *testing.T) {
	f, home, state := setup(t)
	p := filepath.Join(home, ".config/serp/a/b.conf")
	if err := f.Write("mod", p, []byte("new"), 0o640); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "new" {
		t.Fatal("content")
	}
	if !f.Owned()[p] {
		t.Fatal("not owned")
	}
	o, _ := os.ReadFile(filepath.Join(state, "owned-files.txt"))
	if !strings.Contains(string(o), p) {
		t.Fatal("owned-files.txt")
	}
	if err := f.Rollback("mod"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("still there")
	}
	if f.Owned()[p] {
		t.Fatal("still owned")
	}
	if err := f.Rollback("mod"); err != nil { // idempotent
		t.Fatal(err)
	}
}

func TestForeignFileBackedUpAndRestored(t *testing.T) {
	f, home, state := setup(t)
	p := filepath.Join(home, ".bashrc")
	os.WriteFile(p, []byte("user data"), 0o600)
	var hook string
	f.cfg.OnBackup = func(path, b string) { hook = b }

	if err := f.Write("shell", p, []byte("ours"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := f.Write("shell", p, []byte("ours2"), 0o644); err != nil { // second write: no re-backup of our content
		t.Fatal(err)
	}
	if hook == "" || !strings.HasPrefix(hook, state) {
		t.Fatalf("backup hook %q", hook)
	}
	if b, _ := os.ReadFile(hook); string(b) != "user data" {
		t.Fatalf("backup content %q", b)
	}
	if n := len(f.Changes()); n != 1 {
		t.Fatalf("changes=%d", n)
	}
	if err := f.Rollback("shell"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	fi, _ := os.Stat(p)
	if string(b) != "user data" || fi.Mode().Perm() != 0o600 {
		t.Fatalf("restore: %q %v", b, fi.Mode())
	}
}

func TestOwnedFileNotBackedUp(t *testing.T) {
	f, home, _ := setup(t)
	p := filepath.Join(home, ".config/serp/own.conf")
	f.Write("m", p, []byte("v1"), 0o644)
	// new FS instance = new run; file is owned from the previous run
	f2, _ := New(Config{Allowed: f.cfg.Allowed, StateDir: f.cfg.StateDir, Run: "r2"})
	if err := f2.Write("m", p, []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}
	if len(f2.Changes()) != 0 {
		t.Fatal("owned file was backed up")
	}
}

func TestResumeKeepsChangeLog(t *testing.T) {
	f, home, _ := setup(t)
	p := filepath.Join(home, ".bashrc")
	os.WriteFile(p, []byte("orig"), 0o644)
	f.Write("m", p, []byte("x"), 0o644)
	// process "restarts": same run id
	f2, err := New(f.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := f2.Rollback("m"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "orig" {
		t.Fatalf("%q", b)
	}
	// and the undone state survives another restart
	f3, _ := New(f.cfg)
	if err := f3.Write("m", p, []byte("y"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := f3.Rollback("m"); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "orig" {
		t.Fatalf("second cycle %q", b)
	}
}

func TestSymlinkAndRemove(t *testing.T) {
	f, home, _ := setup(t)
	p := filepath.Join(home, ".config/serp/link")
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte("mine"), 0o644)
	if err := f.Symlink("m", p, "/opt/target"); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.Readlink(p); got != "/opt/target" {
		t.Fatal(got)
	}
	f.Rollback("m")
	if b, _ := os.ReadFile(p); string(b) != "mine" {
		t.Fatalf("%q", b)
	}
	if err := f.Remove("rm", p); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err == nil {
		t.Fatal("not removed")
	}
	f.Rollback("rm")
	if b, _ := os.ReadFile(p); string(b) != "mine" {
		t.Fatalf("remove rollback %q", b)
	}
}
