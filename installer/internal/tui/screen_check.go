package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/preflight"
)

// chkState is screen I1.
type chkState struct {
	done   bool
	report preflight.Report
	detail bool // L: full texts instead of one line each
}

func (m *Model) onCheck(msg checkDoneMsg) {
	m.chk.done = true
	m.chk.report = msg.report
	m.md.init(m)
}

// canProceed: preflight finished and nothing blocks.
func (m *Model) canProceed() bool { return m.chk.done && m.chk.report.OKToProceed() }

func (m *Model) checkKey(k tea.KeyPressMsg) tea.Cmd {
	switch strings.ToLower(k.String()) {
	case "enter":
		if m.canProceed() {
			m.afterCheck()
		}
	case "up", "down", "left", "right":
		if m.lang == "ru" {
			m.lang = "en"
		} else {
			m.lang = "ru"
		}
	case "l":
		m.chk.detail = !m.chk.detail
	case "q", "esc":
		return m.quitNow(ActionExit)
	}
	return nil
}

// afterCheck decides between the mode screen and the module screen.
func (m *Model) afterCheck() {
	f := m.chk.report.Facts
	m.md.mode = ModeInstall
	if opt := m.startOption(); opt != "" {
		m.modeApply(opt)
		return
	}
	if len(m.md.opts) > 0 {
		m.go2(ScrMode)
		return
	}
	_ = f
	m.mod.enter(m)
	m.go2(ScrModules)
}

func (m *Model) checkFooter() string {
	return m.hints("Enter", m.t("f.continue"), "F2", m.t("f.lang"), "L", m.t("f.details"), "q", m.t("f.quit"))
}

// logo is the small SERP-X banner.
func (m *Model) logo() []string {
	if m.g.Mode == GlyphASCII {
		return []string{"", m.st.AccentB.Render("S E R P - X"), ""}
	}
	r1 := "┌─╴ ┌─╴ ┌─╮ ┌─╮     ╲ ╱"
	r2 := "└─┐ ├─╴ ├┬╯ ├─╯ ──   ╳ "
	r3 := "╶─┘ └─╴ ╵╰  ╵        ╱ ╲"
	return []string{m.st.AccentB.Render(r1), m.st.AccentB.Render(r2), m.st.AccentB.Render(r3)}
}

func (m *Model) statusMark(c preflight.Check) string {
	switch {
	case c.Status == preflight.Fail:
		return m.st.Bad.Render(m.g.Cross)
	case c.Status == preflight.Warn:
		return m.st.Warn.Render(m.g.Warn)
	case c.ID == preflight.CheckAUR && c.Code == "aur.none", c.ID == preflight.CheckResume && c.Code == "resume.yes":
		return m.st.Text.Render(m.g.Empty)
	case c.ID == preflight.CheckInstall && c.Code != "install.none":
		return m.st.Accent.Render(m.g.Full)
	}
	return m.st.OK.Render(m.g.Check)
}

func (m *Model) checkView(w, h int) []string {
	lw := 36
	if w < 90 {
		lw = 30
	}
	rw := w - lw - 2
	var out []string
	logo := m.logo()
	intro := []string{m.st.Text.Bold(true).Render(m.t("i1.title"))}
	for _, ln := range wrap(m.t("i1.intro"), w-30) {
		intro = append(intro, m.st.Text.Render(ln))
	}
	out = append(out, cols(logo, 28, intro, w-30, 0)...)
	out = append(out, "")

	radio := func(on bool, name, hint string) string {
		if on {
			return m.st.Accent.Render(m.g.Radio) + " " + m.st.Text.Bold(true).Render(name) + m.st.Dim.Render(hint)
		}
		return m.st.Dim.Render(m.g.RadioOff) + " " + m.st.Text.Render(name)
	}
	langBody := []string{"", radio(m.lang == "ru", "Русский", ""), radio(m.lang == "en", "English", ""), "", m.st.Dim.Render("F2 " + m.g.Sep + " " + m.t("i1.f2"))}
	nextBody := []string{""}
	for i, k := range []string{"i1.n1", "i1.n2", "i1.n3", "i1.n4"} {
		for j, ln := range wrap(m.t(k), lw-8) {
			pre := "   "
			if j == 0 {
				pre = itoa(i+1) + ". "
			}
			nextBody = append(nextBody, pre+ln)
		}
	}
	rest := h - len(out)
	langH := 7
	left := m.box(m.t("i1.lang"), langBody, lw, langH, false)
	left = append(left, m.box(m.t("i1.next"), nextBody, lw, max(rest-langH, 4), false)...)

	var chk []string
	if !m.chk.done {
		chk = []string{"", m.st.Dim.Render(m.spinner() + " " + m.t("i1.checking"))}
	} else {
		chk = append(chk, "")
		for _, c := range m.chk.report.Checks {
			txt := c.Text(m.lang)
			if m.chk.detail {
				for j, ln := range wrap(txt, rw-8) {
					if j == 0 {
						chk = append(chk, m.statusMark(c)+" "+ln)
					} else {
						chk = append(chk, "  "+ln)
					}
				}
			} else {
				chk = append(chk, m.statusMark(c)+" "+m.trunc(txt, rw-8))
			}
		}
		chk = append(chk, "", m.verdict())
	}
	right := m.box(m.t("i1.check"), chk, rw, rest, false)
	out = append(out, cols(left, lw, right, rw, 2)...)
	return out
}

func (m *Model) verdict() string {
	r := m.chk.report
	warns, fails := 0, len(r.Failed())
	for _, c := range r.Checks {
		if c.Status == preflight.Warn {
			warns++
		}
	}
	lbl := m.st.Dim.Render(m.t("i1.total") + " ")
	switch {
	case fails > 0:
		return lbl + m.st.Bad.Bold(true).Render(m.t("i1.blocked", fails))
	case warns > 0:
		return lbl + m.st.OK.Bold(true).Render(m.t("i1.can")) + m.st.Warn.Render(" "+m.g.Bullet+" "+m.t("i1.warns", warns))
	}
	return lbl + m.st.OK.Bold(true).Render(m.t("i1.can"))
}

func (m *Model) spinner() string {
	s := m.g.Spinner
	return s[m.frame%len(s)]
}

// startOption maps Config.Mode to a mode option ("" = let the user choose).
func (m *Model) startOption() string {
	switch m.cfg.Mode {
	case ModeRepair:
		return optRepair
	case ModeModules:
		return optModules
	case ModeUninstall:
		return optUninstall
	case ModeInstall:
		if m.cfg.Resume {
			return optResume
		}
		return optInstall
	}
	return ""
}
