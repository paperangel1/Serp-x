package run

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestExecRunnerBasics(t *testing.T) {
	r := &ExecRunner{Redact: func(s string) string { return strings.ReplaceAll(s, "hunter2", "***") }}
	var lines []string
	res, err := r.Run(context.Background(), Cmd{
		Name: "sh", Args: []string{"-c", "echo out; echo err >&2; echo hunter2; cat"},
		Stdin:  "from-stdin",
		Env:    []string{"X_TEST=1"},
		OnLine: func(s, l string) { lines = append(lines, s+":"+l) },
	})
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("%v %+v", err, res)
	}
	if !strings.Contains(res.Stdout, "out\n") || !strings.Contains(res.Stdout, "from-stdin") || strings.Contains(res.Stdout, "hunter2") {
		t.Fatalf("stdout %q", res.Stdout)
	}
	if res.Stderr != "err\n" || len(lines) != 4 {
		t.Fatalf("%q %v", res.Stderr, lines)
	}
}

func TestExecRunnerExitCodeAndCancel(t *testing.T) {
	r := &ExecRunner{}
	res, err := r.Run(context.Background(), Cmd{Name: "sh", Args: []string{"-c", "echo boom >&2; exit 7"}})
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 7 || res.ExitCode != 7 || !strings.Contains(ee.Tail, "boom") {
		t.Fatalf("%v %+v", err, res)
	}
	if _, err := r.Run(context.Background(), Cmd{Name: "definitely-not-a-binary"}); err == nil {
		t.Fatal("want start error")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	st := time.Now()
	_, err = r.Run(ctx, Cmd{Name: "sleep", Args: []string{"10"}})
	if err == nil || time.Since(st) > 5*time.Second {
		t.Fatalf("cancel: %v after %v", err, time.Since(st))
	}
}

func TestWhitelist(t *testing.T) {
	w := Whitelist{RootFiles: []string{"/etc/sddm.conf.d", "/usr/local/bin/serp", "/usr/local/lib/serpantinum-x/helper"}, VPNScript: "/opt/x/x_vpn.sh",
		RootTrees: []string{"/usr/share/t/theme"}, RootGlobs: []string{"/etc/sddm.conf.backup.*"}}
	ok := []Cmd{
		{Name: "pacman", Args: []string{"-S", "--needed", "foo"}, Root: true},
		{Name: "systemctl", Args: []string{"enable", "sddm"}, Root: true},
		{Name: "rm", Args: []string{"-f", "/etc/sddm.conf.d/a.conf"}, Root: true},
		{Name: "install", Args: []string{"-m", "644", "/tmp/a", "/etc/sddm.conf.d/a.conf"}, Root: true},
		{Name: "bash", Args: []string{"/opt/x/x_vpn.sh", "setup"}, Root: true},
		{Name: "rm", Args: []string{"-rf", "/usr/share/t/theme"}, Root: true},
		{Name: "rm", Args: []string{"-f", "/etc/sddm.conf.backup.2026"}, Root: true},
		{Name: "ln", Args: []string{"-sf", "/home/u/.local/bin/x", "/usr/local/bin/serp"}, Root: true},
		{Name: "rc-update", Args: []string{"add", "sddm", "default"}, Root: true},
		{Name: "rmdir", Args: []string{"/usr/local/lib/serpantinum-x"}, Root: true},
	}
	bad := []Cmd{
		{Name: "rmdir", Args: []string{"/etc/sddm.conf.d"}, Root: true},
		{Name: "rmdir", Args: []string{"/usr/local/lib"}, Root: true},
		{Name: "rmdir", Args: []string{"-p", "/usr/local/lib/serpantinum-x"}, Root: true},
		{Name: "rm", Args: []string{"-rf", "/etc/sddm.conf.d"}, Root: true},
		{Name: "rm", Args: []string{"/etc/passwd"}, Root: true},
		{Name: "rm", Args: []string{"/etc/sddm.conf.d/../passwd"}, Root: true},
		{Name: "rm", Args: nil, Root: true},
		{Name: "install", Args: []string{"/tmp/a", "/etc/shadow"}, Root: true},
		{Name: "install", Args: []string{"-t", "/etc", "/tmp/a"}, Root: true},
		{Name: "bash", Args: []string{"-c", "id"}, Root: true},
		{Name: "sh", Args: []string{"-c", "id"}, Root: true},
		{Name: "rm", Args: []string{"-rf", "/usr/share/t/theme/sub"}, Root: true},
		{Name: "rm", Args: []string{"-rf", "/usr/share/t"}, Root: true},
		{Name: "ln", Args: []string{"-sf", "/x", "/usr/bin/sh"}, Root: true},
		{Name: "ln", Args: []string{"-s", "/x"}, Root: true},
		{Name: "chmod", Args: []string{"777", "/"}, Root: true},
	}
	for _, c := range ok {
		if err := w.Check(c); err != nil {
			t.Errorf("%s: %v", c, err)
		}
	}
	for _, c := range bad {
		if err := w.Check(c); !errors.Is(err, ErrNotWhitelisted) {
			t.Errorf("%s: want denial, got %v", c, err)
		}
	}
	// ExecRunner must refuse before ever calling sudo.
	r := &ExecRunner{White: w}
	if _, err := r.Run(context.Background(), bad[0]); !errors.Is(err, ErrNotWhitelisted) {
		t.Fatal(err)
	}
}

func TestFakeRunner(t *testing.T) {
	f := NewFake()
	f.OnPrefix("pacman -Qq", Reply{Result: Result{Stdout: "a\nb\n"}}, false)
	f.OnPrefix("pacman -S", Reply{Err: errors.New("db.lck")}, true)
	var got []string
	res, _ := f.Run(context.Background(), Cmd{Name: "pacman", Args: []string{"-Qq"}, OnLine: func(_, l string) { got = append(got, l) }})
	if res.Stdout != "a\nb\n" || len(got) != 2 {
		t.Fatalf("%+v %v", res, got)
	}
	if _, err := f.Run(context.Background(), Cmd{Name: "pacman", Args: []string{"-S", "x"}, Root: true}); err == nil {
		t.Fatal("first -S should fail")
	}
	if _, err := f.Run(context.Background(), Cmd{Name: "pacman", Args: []string{"-S", "x"}, Root: true}); err != nil {
		t.Fatal("once-rule must be consumed")
	}
	want := []string{"pacman -Qq", "sudo pacman -S x", "sudo pacman -S x"}
	c := f.Calls()
	if strings.Join(c, "|") != strings.Join(want, "|") {
		t.Fatalf("%v", c)
	}
	f.White = &Whitelist{}
	if _, err := f.Run(context.Background(), Cmd{Name: "rm", Args: []string{"/x"}, Root: true}); !errors.Is(err, ErrNotWhitelisted) {
		t.Fatal("fake must enforce whitelist when set")
	}
}

func TestKeepAlive(t *testing.T) {
	f := NewFake()
	stop := KeepAlive(context.Background(), f, 10*time.Millisecond, nil)
	time.Sleep(120 * time.Millisecond)
	stop()
	n := len(f.Calls())
	if n < 3 {
		t.Fatalf("only %d refreshes", n)
	}
	for _, c := range f.Calls() {
		if c != "sudo -n -v" {
			t.Fatalf("unexpected %q", c)
		}
	}
	time.Sleep(50 * time.Millisecond)
	if len(f.Calls()) != n {
		t.Fatal("kept running after stop")
	}
}

func TestKeepAliveFailure(t *testing.T) {
	f := NewFake()
	f.OnPrefix("sudo", Reply{Err: errors.New("password required")}, false)
	var failed atomic.Int32
	stop := KeepAlive(context.Background(), f, 5*time.Millisecond, func(error) { failed.Add(1) })
	time.Sleep(80 * time.Millisecond)
	stop()
	if failed.Load() != 1 || len(f.Calls()) != 1 {
		t.Fatalf("failed=%d calls=%d", failed.Load(), len(f.Calls()))
	}
}
