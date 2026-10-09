// Package run is the command execution layer: a Runner interface, the real
// exec implementation with a sudo whitelist, a recording FakeRunner and the
// sudo keep-alive. See plan section 4.3.
//
// Not implemented here: pty mode (needs creack/pty, a new dependency that has
// to be approved by the coordinator). Output is line-streamed over pipes.
package run

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Cmd describes one command.
type Cmd struct {
	Name   string
	Args   []string
	Dir    string
	Env    []string // extra KEY=VAL appended to the environment
	Stdin  string
	Root   bool                             // run via `sudo -n`, whitelist enforced
	OnLine func(stream string, line string) // "stdout"/"stderr"; may be nil
}

// Result of a finished command.
type Result struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// ExitError is returned for a non-zero exit.
type ExitError struct {
	Cmd  string
	Code int
	Tail string
}

func (e *ExitError) Error() string {
	return fmt.Sprintf("%s: exit status %d: %s", e.Cmd, e.Code, e.Tail)
}

// ErrNotWhitelisted: a root command outside the allowed kinds.
var ErrNotWhitelisted = errors.New("run: root command not allowed")

// Runner executes commands.
type Runner interface {
	Run(ctx context.Context, c Cmd) (Result, error)
}

// String renders the command for logs (no env, no stdin).
func (c Cmd) String() string {
	s := c.Name
	if len(c.Args) > 0 {
		s += " " + strings.Join(c.Args, " ")
	}
	if c.Root {
		s = "sudo " + s
	}
	return s
}

// Whitelist decides whether a root command may run. Allowed kinds (plan 4.3):
// pacman, install, systemctl, rm (only RootFiles paths), bash <VPNScript>.
type Whitelist struct {
	RootFiles []string // absolute files or directory roots for `rm`
	VPNScript string   // absolute path of x_vpn.sh
	// RootGlobs are path.Match patterns for single files next to a root file
	// (e.g. /etc/sddm.conf.backup.*).
	RootGlobs []string
	// RootTrees are directories that `rm -r[f]` may remove as a whole (exact
	// path match). They are also allowed as targets of other commands.
	RootTrees []string
}

func (w Whitelist) Check(c Cmd) error {
	name := filepath.Base(c.Name)
	deny := func(why string) error { return fmt.Errorf("%w: %s (%s)", ErrNotWhitelisted, c.String(), why) }
	switch name {
	case "pacman", "systemctl":
		return nil
	case "rc-update", "rc-service", "dinitctl", "s6-rc-bundle-update":
		// init-system managers of non-systemd distros (upstream service.sh)
		return nil
	case "ln":
		// only `ln -s[f[n]] target dest` with dest inside root_files
		if len(c.Args) < 3 {
			return deny("ln: need flags, target, dest")
		}
		if f := c.Args[0]; f != "-s" && f != "-sf" && f != "-sfn" && f != "-fs" {
			return deny("ln flag")
		}
		if !w.under(c.Args[len(c.Args)-1]) {
			return deny("destination outside root_files")
		}
		return nil
	case "install":
		// `install` can write anywhere: restrict destinations to RootFiles
		// (the last non-flag argument is the destination).
		if len(c.Args) == 0 {
			return deny("no args")
		}
		dst := ""
		for i := 0; i < len(c.Args); i++ {
			a := c.Args[i]
			if a == "-t" || a == "--target-directory" {
				if i+1 < len(c.Args) {
					dst = c.Args[i+1]
				}
				break
			}
			if !strings.HasPrefix(a, "-") {
				dst = a
			} else if a == "-m" || a == "-o" || a == "-g" {
				i++
			}
		}
		if !w.under(dst) {
			return deny("destination outside root_files")
		}
		return nil
	case "rm":
		n := 0
		recursive := false
		for _, a := range c.Args {
			if strings.HasPrefix(a, "-") {
				switch a {
				case "-f", "--":
				case "-r", "-rf", "-fr":
					recursive = true
				default:
					return deny("flag")
				}
				continue
			}
			n++
			if recursive {
				if !w.tree(a) {
					return deny("recursive removal outside root_trees")
				}
			} else if !w.under(a) {
				return deny("path outside root_files")
			}
		}
		if n == 0 {
			return deny("no path")
		}
		return nil
	case "rmdir":
		// only the (empty) private directory of a root file, e.g. /usr/local/lib/serpantinum-xray;
		// rmdir never removes a directory that still has content
		if len(c.Args) != 1 || !filepath.IsAbs(c.Args[0]) || c.Args[0] != filepath.Clean(c.Args[0]) {
			return deny("rmdir: one clean absolute path")
		}
		if b := filepath.Base(c.Args[0]); !strings.HasPrefix(b, "serpantinum") && !strings.HasPrefix(b, "serp-") {
			return deny("rmdir: not a private directory")
		}
		for _, r := range w.RootFiles {
			if filepath.Dir(r) == c.Args[0] {
				return nil
			}
		}
		return deny("rmdir: not the directory of a root file")
	case "bash":
		if w.VPNScript != "" && len(c.Args) > 0 && c.Args[0] == w.VPNScript {
			return nil
		}
		return deny("only the vpn script")
	}
	return deny("unknown command")
}

func (w Whitelist) tree(p string) bool {
	for _, t := range w.RootTrees {
		if p == t && filepath.IsAbs(p) && p == filepath.Clean(p) {
			return true
		}
	}
	return false
}

func (w Whitelist) under(p string) bool {
	if !filepath.IsAbs(p) || p != filepath.Clean(p) {
		return false
	}
	for _, g := range w.RootGlobs {
		if ok, _ := filepath.Match(g, p); ok {
			return true
		}
	}
	for _, r := range append(append([]string(nil), w.RootFiles...), w.RootTrees...) {
		if p == r || strings.HasPrefix(p, strings.TrimSuffix(r, "/")+"/") {
			return true
		}
	}
	return false
}

// ExecRunner is the real Runner.
type ExecRunner struct {
	White Whitelist
	// Redact is applied to captured output and OnLine lines (e.g. xlog.Redact).
	Redact func(string) string
}

const tailMax = 400

func (r *ExecRunner) Run(ctx context.Context, c Cmd) (Result, error) {
	name, args := c.Name, c.Args
	if c.Root {
		if err := r.White.Check(c); err != nil {
			return Result{ExitCode: -1}, err
		}
		args = append([]string{"-n", "--", name}, args...)
		name = "sudo"
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = c.Dir
	cmd.Env = append(os.Environ(), c.Env...)
	if c.Stdin != "" {
		cmd.Stdin = strings.NewReader(c.Stdin)
	}
	cmd.WaitDelay = 2 * time.Second
	so, err := cmd.StdoutPipe()
	if err != nil {
		return Result{ExitCode: -1}, err
	}
	se, err := cmd.StderrPipe()
	if err != nil {
		return Result{ExitCode: -1}, err
	}
	if err := cmd.Start(); err != nil {
		return Result{ExitCode: -1}, err
	}
	var outB, errB bytes.Buffer
	var wg sync.WaitGroup
	var mu sync.Mutex
	pump := func(rd io.Reader, stream string, buf *bytes.Buffer) {
		defer wg.Done()
		sc := bufio.NewScanner(rd)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		for sc.Scan() {
			l := sc.Text()
			if r.Redact != nil {
				l = r.Redact(l)
			}
			mu.Lock()
			buf.WriteString(l + "\n")
			if c.OnLine != nil {
				c.OnLine(stream, l)
			}
			mu.Unlock()
		}
		io.Copy(io.Discard, rd)
	}
	wg.Add(2)
	go pump(so, "stdout", &outB)
	go pump(se, "stderr", &errB)
	wg.Wait()
	werr := cmd.Wait()
	res := Result{Stdout: outB.String(), Stderr: errB.String()}
	if werr == nil {
		return res, nil
	}
	var ee *exec.ExitError
	if errors.As(werr, &ee) {
		res.ExitCode = ee.ExitCode()
		if ctx.Err() != nil {
			return res, ctx.Err()
		}
		t := strings.TrimSpace(res.Stderr)
		if len(t) > tailMax {
			t = t[len(t)-tailMax:]
		}
		return res, &ExitError{Cmd: c.String(), Code: res.ExitCode, Tail: t}
	}
	res.ExitCode = -1
	return res, werr
}

// ---- FakeRunner ----

// Call is a recorded invocation.
type Call struct{ Cmd Cmd }

// Reply is a canned answer.
type Reply struct {
	Result Result
	Err    error
}

// FakeRunner records calls and answers from rules (first match wins, a
// matched rule with Once is consumed); default is success.
type FakeRunner struct {
	mu    sync.Mutex
	calls []Cmd
	rules []fakeRule
	White *Whitelist // optional: enforce the whitelist like ExecRunner
}

type fakeRule struct {
	match func(Cmd) bool
	reply Reply
	once  bool
	used  bool
}

func NewFake() *FakeRunner { return &FakeRunner{} }

// On adds a rule; once=true consumes it after the first match.
func (f *FakeRunner) On(match func(Cmd) bool, reply Reply, once bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rules = append(f.rules, fakeRule{match: match, reply: reply, once: once})
}

// OnPrefix matches by the rendered command prefix (without "sudo ").
func (f *FakeRunner) OnPrefix(prefix string, reply Reply, once bool) {
	f.On(func(c Cmd) bool {
		c.Root = false
		return strings.HasPrefix(c.String(), prefix)
	}, reply, once)
}

func (f *FakeRunner) Run(ctx context.Context, c Cmd) (Result, error) {
	if err := ctx.Err(); err != nil {
		return Result{ExitCode: -1}, err
	}
	if c.Root && f.White != nil {
		if err := f.White.Check(c); err != nil {
			return Result{ExitCode: -1}, err
		}
	}
	f.mu.Lock()
	f.calls = append(f.calls, c)
	var rep Reply
	for i := range f.rules {
		ru := &f.rules[i]
		if ru.used || !ru.match(c) {
			continue
		}
		rep = ru.reply
		if ru.once {
			ru.used = true
		}
		break
	}
	f.mu.Unlock()
	if c.OnLine != nil {
		for _, l := range strings.Split(strings.TrimRight(rep.Result.Stdout, "\n"), "\n") {
			if l != "" {
				c.OnLine("stdout", l)
			}
		}
	}
	return rep.Result, rep.Err
}

// Calls returns recorded commands as rendered strings.
// Cmds returns the recorded commands with their environment.
func (f *FakeRunner) Cmds() []Cmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Cmd(nil), f.calls...)
}

func (f *FakeRunner) Calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.calls))
	for i, c := range f.calls {
		out[i] = c.String()
	}
	return out
}

// Recorded returns the raw recorded commands.
func (f *FakeRunner) Recorded() []Cmd {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Cmd(nil), f.calls...)
}

// ---- sudo keep-alive ----

// KeepAlive runs `sudo -n -v` every interval until stop is called or ctx ends.
// onFail (may be nil) is called once if a refresh fails; the loop then stops.
func KeepAlive(ctx context.Context, r Runner, interval time.Duration, onFail func(error)) (stop func()) {
	ctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				// sudo -v itself is not a Root command: run it directly.
				if _, err := r.Run(ctx, Cmd{Name: "sudo", Args: []string{"-n", "-v"}}); err != nil {
					if ctx.Err() == nil && onFail != nil {
						onFail(err)
					}
					return
				}
			}
		}
	}()
	return func() { cancel(); <-done }
}
