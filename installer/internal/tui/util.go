package tui

import (
	"errors"

	"fmt"
	"serpx/installer/internal/resolve"
	"strconv"
	"strings"
	"time"
)

func itoa(n int) string { return strconv.Itoa(n) }

func fmtF(f float64, prec int) string { return strconv.FormatFloat(f, 'f', prec, 64) }

func (m *Model) dash() string {
	if m.g.Mode == GlyphASCII {
		return "-"
	}
	return "—"
}

// clock renders mm:ss (h:mm:ss over an hour).
func clock(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	s := int(d.Seconds())
	if s >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", s/3600, s/60%60, s%60)
	}
	return fmt.Sprintf("%02d:%02d", s/60, s%60)
}

// spent renders "13 мин 48 с".
func (m *Model) spent(d time.Duration) string {
	s := int(d.Seconds())
	if s < 60 {
		return fmt.Sprintf("%d %s", s, m.t("u.sec"))
	}
	return fmt.Sprintf("%d %s %d %s", s/60, m.t("u.min"), s%60, m.t("u.sec"))
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func without(l []string, s string) []string {
	var out []string
	for _, x := range l {
		if x != s {
			out = append(out, x)
		}
	}
	return out
}

func indexOf(l []string, s string) int {
	for i, x := range l {
		if x == s {
			return i
		}
	}
	return -1
}

func clampInt(v, lo, hi int) int {
	if hi < lo {
		return lo
	}
	return min(max(v, lo), hi)
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func joinNonEmpty(sep string, parts ...string) string {
	var out []string
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, sep)
}

func padLeft(s string, w int) string {
	if n := width(s); n < w {
		return strings.Repeat(" ", w-n) + s
	}
	return s
}

func padRight(s string, w int) string {
	if n := width(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}

func secDur(s int) time.Duration { return time.Duration(s) * time.Second }

// scrollTo returns at most h lines of body keeping line cur visible.
func scrollTo(body []string, cur, h int) []string {
	if h <= 0 || len(body) <= h {
		return body
	}
	start := cur - h/2
	start = clampInt(start, 0, len(body)-h)
	return body[start : start+h]
}

func asConflict(err error, target **resolve.ConflictError) bool { return errors.As(err, target) }
