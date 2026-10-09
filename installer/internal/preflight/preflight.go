// Package preflight runs the checks of screen I1 (plan 4.8). Every check is
// a function over injected inputs (os-release path, sysfs root, runner,
// network probe...), so tests use fake directories and never touch the host.
package preflight

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"serpx/installer/internal/journal"
	"serpx/installer/internal/run"
)

// Status of one check.
type Status int

const (
	OK Status = iota
	Warn
	Fail
)

func (s Status) String() string { return [...]string{"ok", "warn", "fail"}[s] }

// Check ids.
const (
	CheckArch     = "arch"
	CheckRoot     = "root"
	CheckSudo     = "sudo"
	CheckNet      = "net"
	CheckDisk     = "disk"
	CheckRAM      = "ram"
	CheckGPU      = "gpu"
	CheckAUR      = "aur"
	CheckInstall  = "install"
	CheckHypr     = "hypr"
	CheckResume   = "resume"
	CheckConsole  = "console"
	CheckKeyring  = "keyring"
	minRAMBytes   = 3584 << 20 // "4 GB" machines report ~3.8 GiB
	diskReserve   = 1 << 30
	keyringMaxAge = 30 * 24 * time.Hour
)

// Check is one result. Code + Args give the message in ru/en (Text).
type Check struct {
	ID     string
	Status Status
	Code   string
	Args   []any
}

// Text renders the message.
func (c Check) Text(lang string) string {
	m, ok := messages[c.Code]
	if !ok {
		return c.Code
	}
	f := m.ru
	if lang == "en" {
		f = m.en
	}
	return fmt.Sprintf(f, c.Args...)
}

// InstallKind is the kind of an already existing installation.
type InstallKind string

const (
	InstallNone     InstallKind = "none"
	InstallUpstream InstallKind = "upstream"
	InstallSerpX    InstallKind = "serp-x"
	InstallLegacy   InstallKind = "legacy"
)

// Console is the decision about the terminal.
type Console struct {
	Term    string
	Plain   bool   // TERM=dumb/empty: no full-screen UI
	Glyph   string // nerd | unicode | ascii
	Colors  int    // 0, 16, 256
	SetFont bool   // run `setfont cyr-sun16` (TERM=linux and ru)
	Lang    string // language to use ("" = unchanged)
}

// Facts are the detected values the rest of the installer needs.
type Facts struct {
	GPUs         []string // nvidia, amd, intel
	AURHelper    string   // yay | paru | "" (then step yay-bin)
	Install      InstallKind
	Version      string // SERPANTINUM_VERSION of an existing install
	HyprOldConf  bool   // hyprland.conf without hyprland.lua
	NeedsResume  bool
	KeyringStale bool
	NetSpeedBps  float64
	RAMBytes     uint64
	Console      Console
}

// Tags returns resolver detect tags ("gpu:nvidia").
func (f Facts) Tags() []string {
	var t []string
	for _, g := range f.GPUs {
		t = append(t, "gpu:"+g)
	}
	return t
}

// Report is the whole result.
type Report struct {
	Checks []Check
	Facts  Facts
}

// Failed lists blocking checks.
func (r Report) Failed() []Check {
	var out []Check
	for _, c := range r.Checks {
		if c.Status == Fail {
			out = append(out, c)
		}
	}
	return out
}

// OKToProceed is true when nothing blocks.
func (r Report) OKToProceed() bool { return len(r.Failed()) == 0 }

// Get returns a check by id.
func (r Report) Get(id string) (Check, bool) {
	for _, c := range r.Checks {
		if c.ID == id {
			return c, true
		}
	}
	return Check{}, false
}

// NetProbe is the network access (real: HTTPProbe).
type NetProbe interface {
	Head(ctx context.Context, url string) error
	Speed(ctx context.Context) (bytesPerSec float64, err error)
}

// Deps are the injected inputs.
type Deps struct {
	OSRelease   string // /etc/os-release
	SysRoot     string // /sys
	ProcMeminfo string // /proc/meminfo
	Home        string
	StateDir    string // ~/.local/state/serpantinum-installer
	Getenv      func(string) string
	Geteuid     func() int
	LookPath    func(string) (string, error)
	Statfs      func(path string) (freeBytes uint64, err error)
	Runner      run.Runner
	Net         NetProbe
	Now         func() time.Time
}

// RealDeps wires the host (used by the real binary; never by tests).
func RealDeps(runner run.Runner, net NetProbe) Deps {
	home, _ := os.UserHomeDir()
	return Deps{
		OSRelease: "/etc/os-release", SysRoot: "/sys", ProcMeminfo: "/proc/meminfo",
		Home: home, StateDir: filepath.Join(home, ".local", "state", "serpantinum-installer"),
		Getenv: os.Getenv, Geteuid: os.Geteuid, LookPath: lookPath, Statfs: statfsFree,
		Runner: runner, Net: net, Now: time.Now,
	}
}

func statfsFree(p string) (uint64, error) {
	for {
		var st syscall.Statfs_t
		err := syscall.Statfs(p, &st)
		if err == nil {
			return st.Bavail * uint64(st.Bsize), nil
		}
		parent := filepath.Dir(p)
		if parent == p || !errors.Is(err, fs.ErrNotExist) {
			return 0, err
		}
		p = parent // nearest existing parent (e.g. no /var/cache/pacman yet)
	}
}

// Options of one preflight run.
type Options struct {
	NeedBytes int64  // sum of installed sizes of the plan (0 = only the 1 GiB reserve)
	Lang      string // requested language ("" = ru)
	Glyphs    string // forced glyph mode ("" = auto)
	SkipNet   bool   // offline run / tests of other checks
	SkipSudo  bool   // do not run `sudo -v`
}

// Run executes all checks. It never aborts early: the UI shows every line.
func Run(ctx context.Context, d Deps, o Options) Report {
	var r Report
	add := func(id string, st Status, code string, args ...any) {
		r.Checks = append(r.Checks, Check{ID: id, Status: st, Code: code, Args: args})
	}

	// Arch-based
	id, like := parseOSRelease(d.OSRelease)
	_, pmErr := d.LookPath("pacman")
	switch {
	case !(isArch(id) || isArch(like)):
		add(CheckArch, Fail, "arch.notarch", id)
	case pmErr != nil:
		add(CheckArch, Fail, "arch.nopacman")
	default:
		add(CheckArch, OK, "arch.ok", id)
	}

	// not root
	if d.Geteuid() == 0 {
		add(CheckRoot, Fail, "root.root")
	} else {
		add(CheckRoot, OK, "root.ok")
	}

	// sudo
	switch {
	case o.SkipSudo:
		add(CheckSudo, OK, "sudo.skipped")
	default:
		if _, err := d.LookPath("sudo"); err != nil {
			add(CheckSudo, Fail, "sudo.missing")
		} else if _, err := d.Runner.Run(ctx, run.Cmd{Name: "sudo", Args: []string{"-v"}}); err != nil {
			add(CheckSudo, Fail, "sudo.denied")
		} else {
			add(CheckSudo, OK, "sudo.ok")
		}
	}

	// network
	if !o.SkipNet && d.Net != nil {
		var bad []string
		for _, h := range []string{"https://archlinux.org", "https://github.com"} {
			if err := d.Net.Head(ctx, h); err != nil {
				bad = append(bad, strings.TrimPrefix(h, "https://"))
			}
		}
		switch len(bad) {
		case 0:
			if sp, err := d.Net.Speed(ctx); err == nil && sp > 0 {
				r.Facts.NetSpeedBps = sp
				add(CheckNet, OK, "net.ok", fmt.Sprintf("%.1f", sp/1e6))
			} else {
				add(CheckNet, Warn, "net.nospeed")
			}
		case 1:
			// only github.com down: binaries (xray) cannot be fetched -> warn;
			// archlinux.org down means no packages -> fail.
			if bad[0] == "archlinux.org" {
				add(CheckNet, Fail, "net.down", strings.Join(bad, ", "))
			} else {
				add(CheckNet, Warn, "net.partial", bad[0])
			}
		default:
			add(CheckNet, Fail, "net.down", strings.Join(bad, ", "))
		}
	}

	// disk
	need := uint64(o.NeedBytes) + diskReserve
	if o.NeedBytes < 0 {
		need = diskReserve
	}
	var short []string
	for _, p := range []string{"/", "/var/cache/pacman", d.Home} {
		free, err := d.Statfs(p)
		if err != nil {
			short = append(short, fmt.Sprintf("%s: ?", p))
			continue
		}
		if free < need {
			short = append(short, fmt.Sprintf("%s: %d/%d MiB", p, free>>20, need>>20))
		}
	}
	if len(short) > 0 {
		add(CheckDisk, Fail, "disk.low", strings.Join(short, "; "))
	} else {
		add(CheckDisk, OK, "disk.ok", need>>20)
	}

	// RAM
	if mem, ok := readMemTotal(d.ProcMeminfo); ok {
		r.Facts.RAMBytes = mem
		if mem < minRAMBytes {
			add(CheckRAM, Warn, "ram.low", mem>>20)
		} else {
			add(CheckRAM, OK, "ram.ok", mem>>20)
		}
	} else {
		add(CheckRAM, Warn, "ram.unknown")
	}

	// GPU
	r.Facts.GPUs = DetectGPUs(d.SysRoot)
	switch {
	case contains(r.Facts.GPUs, "nvidia"):
		add(CheckGPU, Warn, "gpu.nvidia")
	case len(r.Facts.GPUs) == 0:
		add(CheckGPU, OK, "gpu.none")
	default:
		add(CheckGPU, OK, "gpu.ok", strings.Join(r.Facts.GPUs, ", "))
	}

	// AUR helper
	for _, h := range []string{"yay", "paru"} {
		if _, err := d.LookPath(h); err == nil {
			r.Facts.AURHelper = h
			break
		}
	}
	if r.Facts.AURHelper == "" {
		add(CheckAUR, OK, "aur.none")
	} else {
		add(CheckAUR, OK, "aur.ok", r.Facts.AURHelper)
	}

	// existing installation
	kind, ver := DetectInstall(d.Home)
	r.Facts.Install, r.Facts.Version = kind, ver
	if kind == InstallUpstream || kind == InstallSerpX {
		add(CheckInstall, OK, "install."+string(kind), ver)
	} else {
		add(CheckInstall, OK, "install."+string(kind))
	}

	// hyprland config
	conf := filepath.Join(d.Home, ".config", "hypr", "hyprland.conf")
	lua := filepath.Join(d.Home, ".config", "hypr", "hyprland.lua")
	if exists(conf) && !exists(lua) {
		r.Facts.HyprOldConf = true
		add(CheckHypr, Warn, "hypr.oldconf")
	} else {
		add(CheckHypr, OK, "hypr.ok")
	}

	// unfinished run
	if res, err := journal.NeedsResume(d.StateDir); err == nil && res {
		r.Facts.NeedsResume = true
		add(CheckResume, Warn, "resume.yes")
	} else {
		add(CheckResume, OK, "resume.no")
	}

	// console
	r.Facts.Console = DecideConsole(d, o)
	c := r.Facts.Console
	add(CheckConsole, OK, "console.ok", c.Term, c.Glyph, c.Colors)

	// keyring age
	r.Facts.KeyringStale = keyringStale(ctx, d)
	if r.Facts.KeyringStale {
		add(CheckKeyring, Warn, "keyring.stale")
	} else {
		add(CheckKeyring, OK, "keyring.ok")
	}
	return r
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// ---- os-release ----

func parseOSRelease(path string) (id, idLike string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"'`)
		switch k {
		case "ID":
			id = v
		case "ID_LIKE":
			idLike = v
		}
	}
	return
}

func isArch(v string) bool {
	for _, w := range strings.Fields(v) {
		if w == "arch" {
			return true
		}
	}
	return false
}

// ---- GPU ----

// DetectGPUs reads <sys>/bus/pci/devices/*/{vendor,class}; only display
// controllers (class 0x03xxxx) count. Result is sorted and unique.
func DetectGPUs(sysRoot string) []string {
	devs, _ := filepath.Glob(filepath.Join(sysRoot, "bus", "pci", "devices", "*"))
	set := map[string]bool{}
	for _, d := range devs {
		class := strings.TrimSpace(readFile(filepath.Join(d, "class")))
		if !strings.HasPrefix(strings.ToLower(class), "0x03") {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(readFile(filepath.Join(d, "vendor")))) {
		case "0x10de":
			set["nvidia"] = true
		case "0x1002":
			set["amd"] = true
		case "0x8086":
			set["intel"] = true
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func readFile(p string) string { b, _ := os.ReadFile(p); return string(b) }

// ---- RAM ----

func readMemTotal(path string) (uint64, bool) {
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fl := strings.Fields(sc.Text())
		if len(fl) >= 2 && fl[0] == "MemTotal:" {
			n, err := strconv.ParseUint(fl[1], 10, 64)
			if err != nil {
				return 0, false
			}
			return n << 10, true // kB
		}
	}
	return 0, false
}

// ---- existing installation ----

// DetectInstall: ~/.local/state/serpantinum/version without
// SERPANTINUM_FORK_COMMIT is upstream, with it our build; the old
// ~/.local/state/imperative-dots-version marker is legacy.
func DetectInstall(home string) (InstallKind, string) {
	st := filepath.Join(home, ".local", "state")
	if b, err := os.ReadFile(filepath.Join(st, "serpantinum", "version")); err == nil {
		kv := map[string]string{}
		for _, ln := range strings.Split(string(b), "\n") {
			if k, v, ok := strings.Cut(strings.TrimSpace(ln), "="); ok {
				kv[k] = strings.Trim(v, `"'`)
			}
		}
		if _, ok := kv["SERPANTINUM_FORK_COMMIT"]; ok {
			return InstallSerpX, kv["SERPANTINUM_VERSION"]
		}
		return InstallUpstream, kv["SERPANTINUM_VERSION"]
	}
	if exists(filepath.Join(st, "imperative-dots-version")) {
		return InstallLegacy, ""
	}
	return InstallNone, ""
}

// ---- console ----

// DecideConsole picks glyph mode, colors, font and language for the terminal.
func DecideConsole(d Deps, o Options) Console {
	term := d.Getenv("TERM")
	c := Console{Term: term, Glyph: "unicode", Colors: 256}
	lang := o.Lang
	if lang == "" {
		lang = "ru"
	}
	switch {
	case term == "" || term == "dumb":
		c.Plain, c.Glyph, c.Colors = true, "ascii", 0
	case term == "linux":
		c.Glyph, c.Colors = "ascii", 16
		if lang == "ru" {
			if _, err := d.LookPath("setfont"); err == nil {
				c.SetFont = true
			} else {
				lang = "en" // no Cyrillic font on the bare console
			}
		}
	case !strings.Contains(term, "256") && d.Getenv("COLORTERM") == "":
		c.Colors = 16
	}
	if d.Getenv("NO_COLOR") != "" {
		c.Colors = 0
	}
	if o.Glyphs != "" && !c.Plain && term != "linux" {
		c.Glyph = o.Glyphs
	}
	c.Lang = lang
	return c
}

// ApplyConsole runs `setfont cyr-sun16`; on failure the language falls back
// to English. It returns the language to use.
func ApplyConsole(ctx context.Context, r run.Runner, c Console) string {
	if !c.SetFont {
		return c.Lang
	}
	if _, err := r.Run(ctx, run.Cmd{Name: "setfont", Args: []string{"cyr-sun16"}}); err != nil {
		return "en"
	}
	return c.Lang
}

// ---- keyring ----

var buildDateRe = regexp.MustCompile(`(?m)^Build Date\s*:\s*(.+)$`)

// keyringStale: archlinux-keyring older than 30 days (or unreadable date:
// the keyring step is cheap, so unknown counts as stale).
func keyringStale(ctx context.Context, d Deps) bool {
	res, err := d.Runner.Run(ctx, run.Cmd{Name: "pacman", Args: []string{"-Qi", "archlinux-keyring"}, Env: []string{"LC_ALL=C"}})
	if err != nil {
		return true
	}
	m := buildDateRe.FindStringSubmatch(res.Stdout)
	if m == nil {
		return true
	}
	t, ok := parsePacmanDate(strings.TrimSpace(m[1]))
	if !ok {
		return true
	}
	return d.Now().Sub(t) > keyringMaxAge
}

func parsePacmanDate(s string) (time.Time, bool) {
	for _, l := range []string{"Mon 02 Jan 2006 03:04:05 PM MST", "Mon 02 Jan 2006 03:04:05 PM", "Mon 2 Jan 2006 03:04:05 PM MST",
		"Mon 02 Jan 2006 15:04:05 MST", "Mon 02 Jan 2006 15:04:05", "Mon Jan 2 15:04:05 2006", "Mon Jan _2 15:04:05 2006"} {
		if t, err := time.Parse(l, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
