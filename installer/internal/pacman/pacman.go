// Package pacman parses pacman's output (sizes, progress, missing packages,
// lock state, keyring age). It never runs pacman itself: callers pass the
// output of run.Runner so everything is testable on recorded fixtures.
package pacman

import (
	"errors"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// SumDownloadSizes sums the output of `pacman -Sp --print-format '%s'` (one
// byte count per line) or of '%n %s' (name then bytes). Lines that are not
// sizes (warnings, errors) are ignored.
func SumDownloadSizes(out string) int64 {
	var total int64
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) == 0 || len(f) > 2 {
			continue
		}
		n, err := strconv.ParseInt(f[len(f)-1], 10, 64)
		if err != nil || n < 0 {
			continue
		}
		total += n
	}
	return total
}

// Missing parses `pacman -T pkg...`: the packages that are NOT installed.
func Missing(out string) []string {
	var res []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if l != "" && !strings.HasPrefix(l, "error:") && !strings.HasPrefix(l, "warning:") {
			res = append(res, l)
		}
	}
	return res
}

// Lines splits command output into trimmed non-empty lines (pacman -Qq, -Slq).
func Lines(out string) []string {
	var res []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			res = append(res, l)
		}
	}
	return res
}

// Set turns a list into a set.
func Set(l []string) map[string]bool {
	m := make(map[string]bool, len(l))
	for _, s := range l {
		m[s] = true
	}
	return m
}

// Added returns the entries of after that are not in before (sorted as in after).
func Added(before, after []string) []string {
	b := Set(before)
	var res []string
	for _, p := range after {
		if !b[p] {
			res = append(res, p)
		}
	}
	return res
}

// Phase of a pacman transaction.
type Phase string

const (
	PhaseDownload Phase = "download"
	PhaseInstall  Phase = "install"
	PhaseRemove   Phase = "remove"
	PhaseOther    Phase = "other"
)

// Progress is one parsed progress line.
type Progress struct {
	Phase   Phase
	Name    string  // package (or file) name
	Index   int     // (i/n) counter of installs, 0 for downloads
	Total   int     // n
	Percent float64 // 0..100 for downloads, -1 if unknown
}

var (
	reInstall  = regexp.MustCompile(`^\((\s*\d+)/(\d+)\)\s+(installing|upgrading|reinstalling|downgrading)\s+(\S+)`)
	reRemove   = regexp.MustCompile(`^\((\s*\d+)/(\d+)\)\s+removing\s+(\S+)`)
	reDownload = regexp.MustCompile(`^\s*(\S+)\s+[\d.,]+ [KMGT]?i?B\s+[\d.,]+ [KMGT]?i?B/s\s+\d\d:\d\d(?::\d\d)?\s+\[[#\-\s]*\]\s+(\d+)%`)
	reQuiet    = regexp.MustCompile(`^\s*(\S+)\s+[\d.,]+ [KMGT]?i?B\s+[\d.,]+ [KMGT]?i?B/s\s+\d\d:\d\d`)
)

// ParseProgress understands the lines pacman prints with --noconfirm in a
// non-tty/pty: "(12/63) installing foo" and the download bars.
func ParseProgress(line string) (Progress, bool) {
	line = strings.TrimRight(line, "\r\n ")
	if m := reInstall.FindStringSubmatch(line); m != nil {
		i, _ := strconv.Atoi(strings.TrimSpace(m[1]))
		n, _ := strconv.Atoi(m[2])
		return Progress{Phase: PhaseInstall, Name: m[4], Index: i, Total: n, Percent: -1}, true
	}
	if m := reRemove.FindStringSubmatch(line); m != nil {
		i, _ := strconv.Atoi(strings.TrimSpace(m[1]))
		n, _ := strconv.Atoi(m[2])
		return Progress{Phase: PhaseRemove, Name: m[3], Index: i, Total: n, Percent: -1}, true
	}
	if m := reDownload.FindStringSubmatch(line); m != nil {
		p, _ := strconv.ParseFloat(m[2], 64)
		return Progress{Phase: PhaseDownload, Name: m[1], Percent: p}, true
	}
	if m := reQuiet.FindStringSubmatch(line); m != nil {
		return Progress{Phase: PhaseDownload, Name: m[1], Percent: -1}, true
	}
	return Progress{}, false
}

// LockState describes /var/lib/pacman/db.lck.
type LockState int

const (
	LockNone  LockState = iota // no lock file
	LockBusy                   // lock file and a running pacman: wait
	LockStale                  // lock file and no pacman: offer to remove it
)

// CheckLock inspects lockPath; running reports whether a pacman process exists.
func CheckLock(lockPath string, running func() bool) (LockState, error) {
	if _, err := os.Stat(lockPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return LockNone, nil
		}
		return LockNone, err
	}
	if running != nil && running() {
		return LockBusy, nil
	}
	return LockStale, nil
}

var reField = regexp.MustCompile(`(?m)^(Build Date|Install Date|Required By)\s*:\s*(.*)$`)

// Field returns a "Name : value" field of `pacman -Qi` output.
func Field(qi, name string) string {
	for _, m := range reField.FindAllStringSubmatch(qi, -1) {
		if m[1] == name {
			return strings.TrimSpace(m[2])
		}
	}
	return ""
}

// BuildDate parses the "Build Date" of `pacman -Qi` (LC_ALL=C format).
func BuildDate(qi string) (time.Time, error) {
	v := Field(qi, "Build Date")
	if v == "" {
		return time.Time{}, errors.New("pacman: no Build Date")
	}
	for _, layout := range []string{"Mon 02 Jan 2006 03:04:05 PM MST", "Mon 02 Jan 2006 15:04:05 MST", "Mon 02 Jan 2006 03:04:05 PM -0700", "Mon 02 Jan 2006 15:04:05 -0700", "Mon 2 Jan 2006 03:04:05 PM MST"} {
		if t, err := time.Parse(layout, v); err == nil {
			return t, nil
		}
	}
	return time.Time{}, errors.New("pacman: cannot parse Build Date " + strconv.Quote(v))
}

// KeyringStale: the keyring package is older than maxAge (or its date is unknown).
func KeyringStale(qi string, now time.Time, maxAge time.Duration) bool {
	t, err := BuildDate(qi)
	if err != nil {
		return true
	}
	return now.Sub(t) > maxAge
}

// RequiredBy lists the packages that need a package ("None" -> empty).
func RequiredBy(qi string) []string {
	v := Field(qi, "Required By")
	if v == "" || v == "None" {
		return nil
	}
	return strings.Fields(v)
}
