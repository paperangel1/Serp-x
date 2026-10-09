package steps

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"serpx/installer/internal/pacman"
	"serpx/installer/internal/run"
)

// ---- pacman.conf: enable_multilib ----

var reMultilib = regexp.MustCompile(`^#\[multilib\]`)

// EnableMultilib is the sed of upstream enable_multilib:
// /^#\[multilib\]/{s/^#//;n;s/^#//}  (uncomment the header and the next line).
func EnableMultilib(conf string) (string, bool) {
	lines := strings.Split(conf, "\n")
	changed := false
	for i := 0; i < len(lines); i++ {
		if reMultilib.MatchString(lines[i]) {
			lines[i] = strings.TrimPrefix(lines[i], "#")
			changed = true
			if i+1 < len(lines) {
				i++
				lines[i] = strings.TrimPrefix(lines[i], "#")
			}
		}
	}
	return strings.Join(lines, "\n"), changed
}

type multilibStep struct{ Base }

func (multilibStep) Check(_ context.Context, e *Env) (bool, error) {
	b, err := readIfExists(e.Sys("/etc/pacman.conf"))
	if err != nil {
		return false, err
	}
	if b == nil { // upstream: only acts when /etc/pacman.conf exists
		return true, nil
	}
	_, changed := EnableMultilib(string(b))
	return !changed, nil
}

func (multilibStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	b, err := os.ReadFile(e.Sys("/etc/pacman.conf"))
	if err != nil {
		return err
	}
	nc, changed := EnableMultilib(string(b))
	if !changed {
		return nil
	}
	if err := e.rootInstallFile(ctx, "/etc/pacman.conf", []byte(nc), "644"); err != nil {
		return err
	}
	return e.best(ctx, true, "pacman", "-Sy", "--noconfirm")
}

func (s multilibStep) Verify(ctx context.Context, e *Env) error {
	// With the fake root the file is unchanged; the real one is re-read.
	b, err := readIfExists(e.Sys("/etc/pacman.conf"))
	if err != nil || b == nil {
		return err
	}
	if e.Rootfs == "" || e.Rootfs == "/" {
		if _, changed := EnableMultilib(string(b)); changed {
			return errors.New("multilib is still commented out in /etc/pacman.conf")
		}
	}
	return nil
}

// ---- bootstrap tools ----

type toolsStep struct{ Base }

// Upstream also installs fzf and pciutils for its bash UI; this installer has
// its own UI and reads PCI ids from sysfs, so they are not needed.
func (toolsStep) missing(ctx context.Context, e *Env) []string {
	var m []string
	for _, t := range []struct{ pkg, bin string }{{"jq", "jq"}, {"curl", "curl"}, {"git", "git"}, {"unzip", "unzip"}, {"fontconfig", "fc-cache"}} {
		if !e.lookPath(t.bin) {
			m = append(m, t.pkg)
		}
	}
	if !e.ok(ctx, "pacman", "-Qq", "base-devel") {
		m = append(m, "base-devel")
	}
	return m
}

func (s toolsStep) Check(ctx context.Context, e *Env) (bool, error) {
	return len(s.missing(ctx, e)) == 0, nil
}

func (s toolsStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	m := s.missing(ctx, e)
	if len(m) == 0 {
		return nil
	}
	_, err := e.exec(ctx, true, "pacman", append([]string{"-Sy", "--noconfirm", "--needed"}, m...)...)
	return err
}

// ---- remove quickshell-git ----

func removeQuickshellGit(ctx context.Context, e *Env) error {
	if !e.ok(ctx, "pacman", "-Qq", "quickshell-git") {
		return nil
	}
	// yay -R ... || sudo pacman -Rdd ... || true
	if e.lookPath("yay") && e.ok(ctx, "yay", "-R", "--noconfirm", "quickshell-git") {
		return nil
	}
	return e.best(ctx, true, "pacman", "-Rdd", "--noconfirm", "quickshell-git")
}

type cleanupStep struct{ Base }

func (cleanupStep) Check(ctx context.Context, e *Env) (bool, error) {
	return !e.ok(ctx, "pacman", "-Qq", "quickshell-git"), nil
}
func (cleanupStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	return removeQuickshellGit(ctx, e)
}

// ---- keyring ----

// KeyringMaxAge: older keyrings are refreshed first.
const KeyringMaxAge = 30 * 24 * time.Hour

type keyringStep struct{ Base }

func (keyringStep) Check(ctx context.Context, e *Env) (bool, error) {
	out, err := e.out(ctx, "pacman", "-Qi", "archlinux-keyring")
	if err != nil && out == "" {
		return false, nil // not installed (non-Arch derivative): refresh it
	}
	return !pacman.KeyringStale(out, e.now(), KeyringMaxAge), nil
}

func (keyringStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	_, err := e.exec(ctx, true, "pacman", "-Sy", "--noconfirm", "--needed", "archlinux-keyring")
	return err
}

// ---- full sync (upstream: first install, not a reinstall) ----

type syncStep struct{ Base }

func (syncStep) Check(_ context.Context, e *Env) (bool, error) {
	// Only the first install of a fresh/legacy system syncs; repair never does.
	return e.Mode == ModeRepair || e.Mode == ModeReconcile || e.Opts.Reinstall ||
		(e.Opts.InstallState != StateFresh && e.Opts.InstallState != StateLegacy), nil
}

func (syncStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	_, err := e.exec(ctx, true, "pacman", "-Syyu", "--noconfirm")
	return err
}

// ---- db.lck ----

// DBLockError: a stale /var/lib/pacman/db.lck blocks pacman.
type DBLockError struct{ Path string }

func (e *DBLockError) Error() string { return "pacman database is locked: " + e.Path }

const dbLock = "/var/lib/pacman/db.lck"

func (e *Env) checkLock(ctx context.Context) error {
	st, err := pacman.CheckLock(e.Sys(dbLock), func() bool { return e.ok(ctx, "pgrep", "-x", "pacman") })
	if err != nil {
		return err
	}
	switch st {
	case pacman.LockBusy:
		return errors.New("another pacman is running; wait for it to finish")
	case pacman.LockStale:
		return &DBLockError{Path: dbLock}
	}
	return nil
}

// ClearStaleLock removes a stale db.lck (after the user confirmed) and
// checks the database (`pacman -Dk`).
func ClearStaleLock(ctx context.Context, e *Env) error {
	if err := e.checkLock(ctx); err != nil {
		var le *DBLockError
		if !errors.As(err, &le) {
			return err
		}
	}
	if _, err := e.exec(ctx, true, "rm", "-f", dbLock); err != nil {
		return err
	}
	_, err := e.exec(ctx, false, "pacman", "-Dk")
	return err
}

// brokenPkg matches the lines of `pacman -Dk` about a half-written local db
// entry: error: 'source-highlight-3.1.9-19': description file is missing
var brokenPkg = regexp.MustCompile(`'([^']+)': (?:description|file list) file is missing|'([^']+)': file list is missing`)

// RecoverPacman repairs what a killed run leaves behind: a stale db.lck (no
// pacman process) and packages whose local db entry was cut short. Broken
// packages are installed again over their files. It is a no-op on a healthy
// system, so it is safe to call at the start of every resumed run.
func RecoverPacman(ctx context.Context, e *Env, rep Reporter) error {
	st, err := pacman.CheckLock(e.Sys(dbLock), func() bool { return e.ok(ctx, "pgrep", "-x", "pacman") })
	if err != nil {
		return err
	}
	switch st {
	case pacman.LockBusy:
		return errors.New("another pacman is running; wait for it to finish")
	case pacman.LockStale:
		rep.Log("removing the stale " + dbLock + " left by the interrupted run")
		if _, err := e.exec(ctx, true, "rm", "-f", dbLock); err != nil {
			return err
		}
	}
	res, _ := e.Runner.Run(ctx, run.Cmd{Name: "pacman", Args: []string{"-Dk"}})
	seen := map[string]bool{}
	var names []string
	for _, m := range brokenPkg.FindAllStringSubmatch(res.Stdout+"\n"+res.Stderr, -1) {
		full := m[1]
		if full == "" {
			full = m[2]
		}
		// name-version-release: cut the last two dash fields
		name := full
		for i := 0; i < 2; i++ {
			if k := strings.LastIndex(name, "-"); k > 0 {
				name = name[:k]
			}
		}
		if name != "" && !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return nil
	}
	rep.Log("reinstalling packages cut short by the interruption: " + strings.Join(names, " "))
	_, err = e.exec(ctx, true, "pacman", append([]string{"-S", "--noconfirm", "--overwrite", "*"}, names...)...)
	return err
}

// ---- installed-packages.txt ----

// RecordPackages appends "pkg<TAB>module" lines for new packages.
func (e *Env) RecordPackages(added []string, owner func(string) string) error {
	if len(added) == 0 {
		return nil
	}
	if err := os.MkdirAll(e.StateDir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(e.StateDir, "installed-packages.txt"), os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, p := range added {
		if _, err := fmt.Fprintf(f, "%s\t%s\n", p, owner(p)); err != nil {
			return err
		}
	}
	return f.Sync()
}

// InstalledPackages reads installed-packages.txt: package -> module.
func InstalledPackages(stateDir string) map[string]string {
	m := map[string]string{}
	f, err := os.Open(filepath.Join(stateDir, "installed-packages.txt"))
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if p, mod, ok := strings.Cut(sc.Text(), "\t"); ok {
			m[p] = mod
		}
	}
	return m
}

// owner returns the module that declares pkg (first in plan order), else "_dep".
func (e *Env) owner(pkg string) string {
	if e.Sel != nil && e.Set != nil {
		for _, id := range e.Sel.Modules {
			if m, ok := e.Set.Get(id); ok {
				for _, p := range append(append([]string(nil), m.Packages...), m.AUR...) {
					if p == pkg {
						return id
					}
				}
			}
		}
	}
	return "_dep"
}

// ---- repo packages (one transaction) ----

type repoStep struct {
	Base
	Pkgs []string
}

func (s repoStep) Check(ctx context.Context, e *Env) (bool, error) {
	out, _ := e.out(ctx, "pacman", append([]string{"-T"}, s.Pkgs...)...)
	return len(pacman.Missing(out)) == 0, nil
}

func (s repoStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	if err := e.checkLock(ctx); err != nil {
		return err
	}
	out, _ := e.out(ctx, "pacman", append([]string{"-T"}, s.Pkgs...)...)
	missing := pacman.Missing(out)
	if len(missing) == 0 {
		return nil
	}
	slq, _ := e.out(ctx, "pacman", "-Slq")
	inRepo := pacman.Set(pacman.Lines(slq))
	var repo, other []string
	for _, p := range missing {
		// pacman -T prints the dependency string; strip version constraints
		name := strings.FieldsFunc(p, func(r rune) bool { return r == '>' || r == '<' || r == '=' })[0]
		if inRepo[name] || len(inRepo) == 0 {
			repo = append(repo, name)
		} else {
			other = append(other, name)
		}
	}
	before := pacmanQq(ctx, e)
	if len(repo) > 0 {
		if sz, _ := e.out(ctx, "pacman", append([]string{"-Sp", "--needed", "--print-format", "%n %s"}, repo...)...); sz != "" {
			rep.Log(fmt.Sprintf("download size: %.1f MiB", float64(pacman.SumDownloadSizes(sz))/(1<<20)))
		}
		cmd := run.Cmd{Name: "pacman", Args: append([]string{"-S", "--noconfirm", "--needed"}, repo...), Root: true,
			OnLine: func(_ string, l string) {
				rep.Log(l)
				if p, ok := pacman.ParseProgress(l); ok {
					switch {
					case p.Phase == pacman.PhaseInstall && p.Total > 0:
						rep.Progress(float64(p.Index)/float64(p.Total), p.Name)
					case p.Percent >= 0:
						rep.Progress(p.Percent/100, p.Name)
					}
				}
			}}
		if _, err := e.Runner.Run(ctx, cmd); err != nil {
			return fmt.Errorf("pacman -S: %w", err)
		}
	}
	// Not in the sync databases: upstream install_pkg falls back to the AUR helper.
	for _, p := range other {
		if err := aurInstall(ctx, e, rep, p); err != nil {
			return err
		}
	}
	return e.RecordPackages(pacman.Added(before, pacmanQq(ctx, e)), e.owner)
}

func (s repoStep) Verify(ctx context.Context, e *Env) error {
	out, _ := e.out(ctx, "pacman", append([]string{"-T"}, s.Pkgs...)...)
	if m := pacman.Missing(out); len(m) > 0 {
		sort.Strings(m)
		return fmt.Errorf("packages still missing: %s", strings.Join(m, " "))
	}
	return nil
}

func pacmanQq(ctx context.Context, e *Env) []string {
	out, _ := e.out(ctx, "pacman", "-Qq")
	return pacman.Lines(out)
}

// ---- AUR ----

// SafeJobs is upstream's clamp(nproc/2, 1, 4).
func SafeJobs(nproc int) int {
	j := nproc / 2
	if j < 1 {
		j = 1
	}
	if j > 4 {
		j = 4
	}
	return j
}

func (e *Env) aurHelper() string {
	for _, h := range []string{"yay", "paru"} {
		if e.lookPath(h) {
			return h
		}
	}
	return ""
}

func aurInstall(ctx context.Context, e *Env, rep Reporter, pkg string) error {
	h := e.aurHelper()
	if h == "" {
		return fmt.Errorf("no AUR helper (yay/paru) to install %s", pkg)
	}
	j := SafeJobs(e.NProc)
	_, err := e.Runner.Run(ctx, run.Cmd{Name: h, Args: []string{"-S", "--noconfirm", "--needed", pkg},
		Env:    []string{fmt.Sprintf("CARGO_BUILD_JOBS=%d", j), fmt.Sprintf("MAKEFLAGS=-j%d", j)},
		OnLine: func(_ string, l string) { rep.Log(l) }})
	return err
}

type aurStep struct {
	Base
	Pkg string
}

func (s aurStep) Check(ctx context.Context, e *Env) (bool, error) {
	return e.ok(ctx, "pacman", "-Qq", s.Pkg), nil
}
func (s aurStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	before := pacmanQq(ctx, e)
	if err := aurInstall(ctx, e, rep, s.Pkg); err != nil {
		return err
	}
	return e.RecordPackages(pacman.Added(before, pacmanQq(ctx, e)), func(p string) string {
		if p == s.Pkg {
			return s.Mod
		}
		return "_dep"
	})
}
func (s aurStep) Verify(ctx context.Context, e *Env) error {
	if !e.ok(ctx, "pacman", "-Qq", s.Pkg) {
		return fmt.Errorf("%s is not installed", s.Pkg)
	}
	return nil
}

// aurHelperStep: yay-bin only when neither yay nor paru exists (upstream
// bootstrap_installer_deps).
type aurHelperStep struct{ Base }

func (aurHelperStep) Check(_ context.Context, e *Env) (bool, error) { return e.aurHelper() != "", nil }

func (aurHelperStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	build := filepath.Join(e.CacheDir(), "serpantinum-yay-bin")
	if err := os.RemoveAll(build); err != nil {
		return err
	}
	if err := os.MkdirAll(build, 0o755); err != nil {
		return err
	}
	defer os.RemoveAll(build)
	if _, err := e.exec(ctx, false, "git", "clone", "https://aur.archlinux.org/yay-bin.git", build); err != nil {
		return err
	}
	_, err := e.Runner.Run(ctx, run.Cmd{Name: "makepkg", Args: []string{"-si", "--noconfirm"}, Dir: build,
		OnLine: func(_ string, l string) { rep.Log(l) }})
	return err
}

func (aurHelperStep) Verify(_ context.Context, e *Env) error {
	if e.aurHelper() == "" {
		return errors.New("yay was not installed")
	}
	return nil
}
