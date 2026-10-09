// Package stepstest builds fake environments for step and engine tests: a
// temp HOME, a temp "root filesystem", a payload fixture, a pacman/systemd
// simulator behind run.FakeRunner and a fake downloader. Nothing here ever
// executes a real command.
package stepstest

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"serpx/installer"
	"serpx/installer/internal/fsx"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
)

// Sim is a run.Runner that records every call (like FakeRunner, whitelist
// included) and simulates the parts of pacman, systemctl, install, rm, ln,
// ssh-keygen and test that the steps rely on.
type Sim struct {
	*run.FakeRunner
	Rootfs string

	mu        sync.Mutex
	Installed map[string]bool
	Repo      map[string]bool // packages in the sync databases
	Enabled   map[string]bool
	// KeyringBuilt is the Build Date shown for archlinux-keyring.
	KeyringBuilt time.Time
	Lock         bool     // /var/lib/pacman/db.lck exists
	Broken       []string // name-ver-rel entries `pacman -Dk` reports as cut short
	fail         []failRule
}

type failRule struct {
	prefix string
	err    error
	times  int // <0: always
}

// NewSim returns a simulator rooted at rootfs.
func NewSim(rootfs string) *Sim {
	return &Sim{FakeRunner: run.NewFake(), Rootfs: rootfs, Installed: map[string]bool{}, Repo: map[string]bool{}, Enabled: map[string]bool{},
		KeyringBuilt: time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}
}

// FailOn makes commands whose rendered form (without "sudo ") starts with
// prefix fail `times` times (-1 = always).
func (s *Sim) FailOn(prefix string, err error, times int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail = append(s.fail, failRule{prefix, err, times})
}

func exitErr(c run.Cmd, code int) error { return &run.ExitError{Cmd: c.String(), Code: code} }

func (s *Sim) path(p string) string { return filepath.Join(s.Rootfs, p) }

// Run implements run.Runner.
func (s *Sim) Run(ctx context.Context, c run.Cmd) (run.Result, error) {
	if _, err := s.FakeRunner.Run(ctx, c); err != nil { // records, enforces whitelist/ctx
		return run.Result{ExitCode: -1}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	plain := c
	plain.Root = false
	text := plain.String()
	for i := range s.fail {
		f := &s.fail[i]
		if strings.HasPrefix(text, f.prefix) && f.times != 0 {
			if f.times > 0 {
				f.times--
			}
			return run.Result{ExitCode: 1}, f.err
		}
	}
	res, err := s.handle(c)
	if c.OnLine != nil {
		for _, l := range strings.Split(strings.TrimRight(res.Stdout, "\n"), "\n") {
			if l != "" {
				c.OnLine("stdout", l)
			}
		}
	}
	return res, err
}

func nonFlags(args []string) []string {
	var out []string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			out = append(out, a)
		}
	}
	return out
}

func (s *Sim) handle(c run.Cmd) (run.Result, error) {
	ok := run.Result{}
	switch filepath.Base(c.Name) {
	case "pacman":
		return s.pacman(c)
	case "yay", "paru":
		for _, p := range nonFlags(c.Args) {
			if len(c.Args) > 0 && strings.HasPrefix(c.Args[0], "-R") {
				delete(s.Installed, p)
			} else {
				s.Installed[p] = true
			}
		}
	case "systemctl":
		return s.systemctl(c)
	case "pgrep":
		return run.Result{ExitCode: 1}, exitErr(c, 1)
	case "test":
		if len(c.Args) == 2 && c.Args[0] == "-f" {
			if _, err := os.Stat(c.Args[1]); err != nil {
				return run.Result{ExitCode: 1}, exitErr(c, 1)
			}
		}
	case "ssh-keygen":
		for i, a := range c.Args {
			if a == "-f" && i+1 < len(c.Args) {
				os.WriteFile(c.Args[i+1], []byte("PRIVATE-FAKE\n"), 0o600)
				os.WriteFile(c.Args[i+1]+".pub", []byte("ssh-ed25519 FAKE serpantinum\n"), 0o644)
			}
		}
	case "install":
		return ok, s.install(c)
	case "rm":
		rec := false
		for _, a := range c.Args {
			if a == "-r" || a == "-rf" || a == "-fr" {
				rec = true
			}
		}
		for _, p := range nonFlags(c.Args) {
			if rec {
				os.RemoveAll(s.path(p))
			} else {
				os.Remove(s.path(p))
			}
		}
	case "ln":
		a := nonFlags(c.Args)
		if len(a) == 2 {
			os.MkdirAll(filepath.Dir(s.path(a[1])), 0o755)
			os.Remove(s.path(a[1]))
			os.Symlink(a[0], s.path(a[1]))
		}
	}
	return ok, nil
}

func (s *Sim) install(c run.Cmd) error {
	mode := os.FileMode(0o755)
	var args []string
	dirOnly := false
	target := ""
	for i := 0; i < len(c.Args); i++ {
		switch a := c.Args[i]; a {
		case "-d":
			dirOnly = true
		case "-m":
			i++
			var m uint32
			fmt.Sscanf(c.Args[i], "%o", &m)
			mode = os.FileMode(m)
		case "-t":
			i++
			target = c.Args[i]
		case "-D":
		default:
			args = append(args, a)
		}
	}
	switch {
	case dirOnly:
		return os.MkdirAll(s.path(args[len(args)-1]), 0o755)
	case target != "":
		os.MkdirAll(s.path(target), 0o755)
		for _, f := range args {
			if err := s.copy1(f, filepath.Join(s.path(target), filepath.Base(f)), mode); err != nil {
				return err
			}
		}
	default:
		dst := s.path(args[len(args)-1])
		os.MkdirAll(filepath.Dir(dst), 0o755)
		return s.copy1(args[0], dst, mode)
	}
	return nil
}

func (s *Sim) copy1(src, dst string, mode os.FileMode) error {
	b, err := os.ReadFile(src)
	if err != nil && filepath.IsAbs(src) { // a system path: look in the fake root
		b, err = os.ReadFile(s.path(src))
	}
	if err != nil {
		return err
	}
	os.Remove(dst)
	return os.WriteFile(dst, b, mode)
}

func (s *Sim) systemctl(c run.Cmd) (run.Result, error) {
	args := nonFlags(c.Args)
	if len(args) < 1 {
		return run.Result{}, nil
	}
	switch args[0] {
	case "is-enabled":
		if len(args) > 1 && s.Enabled[args[1]] {
			return run.Result{}, nil
		}
		return run.Result{ExitCode: 1}, exitErr(c, 1)
	case "enable":
		for _, u := range args[1:] {
			s.Enabled[u] = true
		}
	case "disable":
		for _, u := range args[1:] {
			delete(s.Enabled, u)
		}
	}
	return run.Result{}, nil
}

func (s *Sim) pacman(c run.Cmd) (run.Result, error) {
	if len(c.Args) == 0 {
		return run.Result{}, nil
	}
	op := c.Args[0]
	pk := nonFlags(c.Args[1:])
	switch {
	case op == "-Dk" && len(s.Broken) > 0:
		var l []string
		for _, b := range s.Broken {
			l = append(l, "error: '"+b+"': description file is missing", "error: '"+b+"': file list is missing")
		}
		return run.Result{Stderr: strings.Join(l, "\n") + "\n", ExitCode: 1}, exitErr(c, 1)
	case op == "-T":
		var miss []string
		for _, p := range pk {
			if !s.Installed[p] {
				miss = append(miss, p)
			}
		}
		if len(miss) > 0 {
			return run.Result{Stdout: strings.Join(miss, "\n") + "\n", ExitCode: 127}, exitErr(c, 127)
		}
	case op == "-Slq":
		var l []string
		for p := range s.Repo {
			l = append(l, p)
		}
		sort.Strings(l)
		return run.Result{Stdout: strings.Join(l, "\n") + "\n"}, nil
	case op == "-Qq":
		if len(pk) == 0 {
			var l []string
			for p, ok := range s.Installed {
				if ok {
					l = append(l, p)
				}
			}
			sort.Strings(l)
			return run.Result{Stdout: strings.Join(l, "\n") + "\n"}, nil
		}
		if !s.Installed[pk[0]] {
			return run.Result{ExitCode: 1}, exitErr(c, 1)
		}
	case op == "-Qi":
		if len(pk) == 0 || (!s.Installed[pk[0]] && pk[0] != "archlinux-keyring") {
			return run.Result{ExitCode: 1}, exitErr(c, 1)
		}
		built := s.KeyringBuilt.Format("Mon 02 Jan 2006 03:04:05 PM MST")
		return run.Result{Stdout: fmt.Sprintf("Name : %s\nBuild Date : %s\nRequired By : None\n", pk[0], built)}, nil
	case op == "-Sp":
		var l []string
		for _, p := range pk {
			l = append(l, p+" 1048576")
		}
		return run.Result{Stdout: strings.Join(l, "\n") + "\n"}, nil
	case strings.HasPrefix(op, "-R"):
		for _, p := range pk {
			delete(s.Installed, p)
		}
	case strings.HasPrefix(op, "-S"):
		for _, p := range pk {
			s.Installed[p] = true
		}
	}
	return run.Result{}, nil
}

// HasCall reports whether a recorded call starts with prefix (rendered with sudo).
func (s *Sim) HasCall(prefix string) bool {
	for _, c := range s.Calls() {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

// CallsWith returns the recorded calls that start with prefix.
func (s *Sim) CallsWith(prefix string) []string {
	var out []string
	for _, c := range s.Calls() {
		if strings.HasPrefix(c, prefix) {
			out = append(out, c)
		}
	}
	return out
}

// ---- downloader ----

// FakeDL serves canned bodies by URL.
type FakeDL struct {
	mu    sync.Mutex
	Files map[string][]byte
	Err   map[string]error
	Log   []string
}

func (d *FakeDL) Download(_ context.Context, url, dst string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.Log = append(d.Log, url)
	if err := d.Err[url]; err != nil {
		return err
	}
	b, ok := d.Files[url]
	if !ok {
		return fmt.Errorf("fake: no file for %s", url)
	}
	return os.WriteFile(dst, b, 0o600)
}

// ---- environment ----

// Fixture is a ready test environment.
type Fixture struct {
	Env *steps.Env
	Sim *Sim
	DL  *FakeDL
	Cat *i18n.Catalog
	// Bins are the executables LookPath finds.
	Bins map[string]bool
	Rep  *Recorder
}

// Recorder is a Reporter that keeps what it saw.
type Recorder struct {
	mu    sync.Mutex
	Logs  []string
	Warns []string
}

func (r *Recorder) Log(m string)             { r.mu.Lock(); r.Logs = append(r.Logs, m); r.mu.Unlock() }
func (r *Recorder) Warn(m string)            { r.mu.Lock(); r.Warns = append(r.Warns, m); r.mu.Unlock() }
func (r *Recorder) Progress(float64, string) {}

// New builds the fixture; the manifests are the real embedded ones.
func New(t testing.TB) *Fixture {
	t.Helper()
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		t.Fatal(err)
	}
	cat, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		t.Fatal(err)
	}
	home, root := t.TempDir(), t.TempDir()
	sim := NewSim(root)
	dl := &FakeDL{Files: map[string][]byte{}, Err: map[string]error{}}
	f := &Fixture{Sim: sim, DL: dl, Cat: cat, Rep: &Recorder{},
		Bins: map[string]bool{"jq": true, "curl": true, "git": true, "unzip": true, "fc-cache": true, "systemctl": true, "yay": true}}
	env := &steps.Env{
		Home: home, Payload: MakePayload(t), StateDir: filepath.Join(home, ".local/state/serpantinum-installer"), Rootfs: root,
		Run: "20261008-1200", Mode: steps.ModeInstall, Version: "2.2.4-s3", Commit: "abc1234",
		Runner: sim, DL: dl, Set: set, Rep: f.Rep, NProc: 8,
		Getenv: func(k string) string { return map[string]string{"LANG": "ru_RU.UTF-8", "HOME": home}[k] },
		LookPath: func(n string) (string, error) {
			if f.Bins[n] {
				return "/usr/bin/" + n, nil
			}
			return "", fmt.Errorf("not found: %s", n)
		},
		Now:  func() time.Time { return time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC) },
		Opts: steps.Options{Compositors: []string{"hyprland"}, InstallState: steps.StateFresh},
	}
	f.Env = env
	os.MkdirAll(env.StateDir, 0o700)
	os.MkdirAll(filepath.Join(root, "run/systemd/system"), 0o755)
	return f
}

// Select resolves the modules, attaches fsx and arms the sudo whitelist.
func (f *Fixture) Select(t testing.TB, ids ...string) *resolve.Selection {
	t.Helper()
	sel, err := resolve.New(f.Env.Set).Resolve(ids)
	if err != nil {
		t.Fatal(err)
	}
	f.Env.Sel = sel
	fx, err := fsx.New(fsx.Config{Allowed: f.Env.Allowed(), StateDir: f.Env.StateDir, Run: f.Env.Run})
	if err != nil {
		t.Fatal(err)
	}
	f.Env.FS = fx
	w := f.Env.Whitelist()
	f.Sim.White = &w
	return sel
}

// Write creates a file (and its directories) under base.
func Write(t testing.TB, base, rel, content string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(base, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	return p
}

// MakePayload writes a small but complete payload tree.
func MakePayload(t testing.TB) string {
	t.Helper()
	p := t.TempDir()
	w := func(rel, c string, m os.FileMode) { Write(t, p, rel, c, m) }
	w("version.txt", "2.2.4\n", 0o644)
	w("bin/serpantinum", "#!/bin/sh\necho serpantinum\n", 0o755)
	w("bin/serpantinumd", "#!/bin/sh\necho d\n", 0o755)
	w("bin/serpantinum-x", "#!/bin/sh\necho x\n", 0o755)
	w("src/scripts/location.sh", "#!/bin/sh\n", 0o644)
	w("src/scripts/foo.sh", "#!/bin/sh\n", 0o644)
	w("src/scripts/__pycache__/x.pyc", "bytecode", 0o644)
	w("src/scripts/custom/vpn/x_vpn.sh", "#!/bin/sh\n", 0o644)
	w("src/scripts/custom/x_keybinds.sh", "#!/bin/sh\n", 0o644)
	w("src/assets/languages/en.json", "{}", 0o644)
	w("src/assets/languages/ru.json", "{}", 0o644)
	w("src/assets/custom-desktop/serpantinum-commands.desktop", "[Desktop Entry]\nExec=@HOME@/.local/bin/serpantinum ipc call xcmd open\n", 0o644)
	w("src/assets/custom-desktop/serpantinum-commands-palette.desktop", "[Desktop Entry]\nExec=@HOME@/.local/bin/serpantinum ipc call xcmd palette\n", 0o644)
	w("config/serpantinum/settings.json", `{"general":{"language":"en","theme":"dark"},"bar":{"height":30}}`, 0o644)
	w("config/kitty/kitty.conf", "font_size 12\n", 0o644)
	w("config/cava/config", "[general]\n", 0o644)
	w("config/fastfetch/config.jsonc", "{}", 0o644)
	w("config/sddm/themes/material-you/theme.conf", "[General]\n", 0o644)
	w("config/sddm/themes/material-you/Main.qml", "Item {}", 0o644)
	w("config/sddm/themes/material-you/font/Google.ttf", "ttf", 0o644)
	w("compositors/hyprland/hyprland.lua", "require(\"config/variables\")\nrequire(\"config/env\")\n", 0o644)
	w("compositors/hyprland/config/env.lua", "hl.env(\"A\", \"b\")\n", 0o644)
	return p
}

// Tree lists files (relative, with symlinks marked) under dir for golden checks.
func Tree(t testing.TB, dir string) []string {
	t.Helper()
	var out []string
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			out = append(out, rel+" -> link")
		case !d.IsDir():
			out = append(out, rel)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// ClearRules removes every FailOn rule and canned FakeRunner reply.
func (s *Sim) ClearRules() {
	s.mu.Lock()
	s.fail = nil
	s.mu.Unlock()
}

// CloneEnv copies an Env (for tests that run a mode twice with different Setup).
func CloneEnv(e *steps.Env) *steps.Env { c := *e; return &c }
