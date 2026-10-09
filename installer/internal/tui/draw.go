package tui

import (
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func width(s string) int { return lipgloss.Width(s) }

// padTo pads (or cuts) s to exactly w columns.
func padTo(s string, w int) string {
	n := width(s)
	if n > w {
		return ansi.Truncate(s, w, "")
	}
	return s + strings.Repeat(" ", w-n)
}

func (m *Model) ell() string {
	if m.g.Mode == GlyphASCII {
		return "~"
	}
	return "…"
}

// trunc cuts s to w columns with an ellipsis.
func (m *Model) trunc(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if width(s) <= w {
		return s
	}
	return ansi.Truncate(s, w, m.ell())
}

// wrap word-wraps plain text to w columns.
func wrap(s string, w int) []string {
	if w < 4 {
		w = 4
	}
	var out []string
	for _, para := range strings.Split(s, "\n") {
		if para == "" {
			out = append(out, "")
			continue
		}
		out = append(out, strings.Split(ansi.Wrap(para, w, ""), "\n")...)
	}
	return out
}

// vfit makes lines exactly h rows (cut or pad with empty lines).
func vfit(lines []string, h int) []string {
	if h < 0 {
		h = 0
	}
	if len(lines) > h {
		return lines[:h]
	}
	for len(lines) < h {
		lines = append(lines, "")
	}
	return lines
}

// box draws a titled frame of exactly w columns; h = 0 sizes it to the body.
func (m *Model) box(title string, body []string, w, h int, focus bool) []string {
	if w < 6 {
		w = 6
	}
	bs := m.st.Border
	if focus {
		bs = m.st.BorderFocus
	}
	if h == 0 {
		h = len(body) + 2
	}
	g := m.g
	iw := w - 4
	var top string
	if title != "" {
		t := " " + m.trunc(title, w-6) + " "
		rest := w - 3 - width(t)
		if rest < 0 {
			rest = 0
		}
		top = bs.Render(g.TL+g.H) + m.st.Title.Render(t) + bs.Render(strings.Repeat(g.H, rest)+g.TR)
	} else {
		top = bs.Render(g.TL + strings.Repeat(g.H, w-2) + g.TR)
	}
	out := []string{top}
	for _, ln := range vfit(body, h-2) {
		out = append(out, bs.Render(g.V)+" "+padTo(m.trunc(ln, iw), iw)+" "+bs.Render(g.V))
	}
	out = append(out, bs.Render(g.BL+strings.Repeat(g.H, w-2)+g.BR))
	return out
}

// cols places two blocks side by side.
func cols(l []string, lw int, r []string, rw int, gap int) []string {
	n := max(len(l), len(r))
	out := make([]string, n)
	sp := strings.Repeat(" ", gap)
	for i := 0; i < n; i++ {
		a, b := "", ""
		if i < len(l) {
			a = l[i]
		}
		if i < len(r) {
			b = r[i]
		}
		out[i] = padTo(a, lw) + sp + padTo(b, rw)
	}
	return out
}

// pill renders a highlighted label (current stage, selected preset, ...).
func (m *Model) pill(s string) string {
	g := m.g
	if g.CapL != "" {
		return m.st.PillCap.Render(g.CapL) + m.st.Pill.Render(s) + m.st.PillCap.Render(g.CapR)
	}
	return m.st.Pill.Render(" " + s + " ")
}

// button renders a button; focus makes it a pill.
func (m *Model) button(label string, focus bool) string {
	if focus {
		return m.pill(label)
	}
	return m.st.Key.Render(" " + label + " ")
}

// key renders one footer hint: "Enter далее".
func (m *Model) key(k, label string) string {
	return m.st.Key.Render(" "+k+" ") + " " + m.st.Dim.Render(label)
}

func (m *Model) hints(pairs ...string) string {
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, m.key(pairs[i], pairs[i+1]))
	}
	return strings.Join(parts, "  ")
}

// sizeText: "963 МиБ" / "1.36 ГиБ" / "-" for zero.
func (m *Model) sizeText(mib float64) string {
	switch {
	case mib <= 0:
		return m.dash()
	case mib >= 1024:
		return fmtF(mib/1024, 2) + " " + m.t("u.gib")
	case mib < 10:
		return fmtF(mib, 1) + " " + m.t("u.mib")
	}
	return fmtF(mib, 0) + " " + m.t("u.mib")
}

// durText: "8 мин" / "5 с" / "-".
func (m *Model) durText(sec int) string {
	switch {
	case sec <= 0:
		return m.dash()
	case sec < 60:
		return itoa(sec) + " " + m.t("u.sec")
	}
	return itoa((sec+30)/60) + " " + m.t("u.min")
}
