package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/preflight"
)

// Mode options of screen I2.
const (
	optResume    = "resume"
	optRepair    = "repair"
	optModules   = "modules"
	optUninstall = "uninstall"
	optReinstall = "reinstall"
	optInstall   = "install"
)

type modeState struct {
	opts      []string
	cur       int
	mode      string
	reinstall bool
	resume    bool
	installed *Installed
}

// init builds the option list from the preflight facts.
func (s *modeState) init(m *Model) {
	s.opts = nil
	f := m.chk.report.Facts
	s.installed = m.be.Installed()
	if f.NeedsResume {
		s.opts = append(s.opts, optResume)
	}
	switch f.Install {
	case preflight.InstallSerpX:
		s.opts = append(s.opts, optRepair, optModules, optUninstall, optReinstall)
	case preflight.InstallUpstream, preflight.InstallLegacy:
		s.opts = append(s.opts, optInstall)
	default:
		if f.NeedsResume {
			s.opts = append(s.opts, optInstall)
		}
	}
	s.cur = 0
	if s.resume && contains(s.opts, optResume) {
		s.cur = 0
	}
}

func (m *Model) modeKey(k tea.KeyPressMsg) tea.Cmd {
	s := &m.md
	switch strings.ToLower(k.String()) {
	case "up", "k":
		s.cur = clampInt(s.cur-1, 0, len(s.opts)-1)
	case "down", "j":
		s.cur = clampInt(s.cur+1, 0, len(s.opts)-1)
	case "esc":
		m.back()
	case "q":
		return m.quitNow(ActionExit)
	case "enter":
		m.modeApply(s.opts[s.cur])
	}
	return nil
}

func (m *Model) modeApply(opt string) {
	s := &m.md
	s.reinstall, s.resume = false, false
	switch opt {
	case optResume:
		s.mode, s.resume = ModeInstall, true
		m.mod.enter(m)
		m.go2(ScrModules)
	case optRepair:
		s.mode = ModeRepair
		m.sumEnter()
	case optUninstall:
		s.mode = ModeUninstall
		m.sumEnter()
	case optModules:
		s.mode = ModeModules
		m.mod.enter(m)
		m.go2(ScrModules)
	case optReinstall:
		s.mode, s.reinstall = ModeInstall, true
		m.mod.enter(m)
		m.go2(ScrModules)
	default:
		s.mode = ModeInstall
		m.mod.enter(m)
		m.go2(ScrModules)
	}
}

func (m *Model) modeFooter() string {
	return m.hints(m.g.Updown, m.t("f.select"), "Enter", m.t("f.next"), "Esc", m.t("f.back"), "F2", m.t("f.lang"), "q", m.t("f.quit"))
}

func (m *Model) modeView(w, h int) []string {
	s := &m.md
	f := m.chk.report.Facts
	var info []string
	switch {
	case f.Install == preflight.InstallSerpX:
		build, date, n := f.Version, "", 0
		if s.installed != nil {
			build, n = s.installed.Build, len(s.installed.Modules)
			if !s.installed.InstalledAt.IsZero() {
				date = s.installed.InstalledAt.Format("02.01.2006")
			}
		}
		l1 := m.st.Accent.Render(m.g.Full) + " " + m.t("i2.found", m.st.AccentB.Render("serp-x "+build))
		if date != "" {
			l1 += m.st.Dim.Render(" " + m.g.Bullet + " " + m.t("i2.since", date, n))
		}
		info = []string{l1, m.st.Dim.Render("  " + m.t("i2.safe"))}
	case f.Install == preflight.InstallUpstream:
		info = []string{m.st.Accent.Render(m.g.Full) + " " + m.t("i2.upstream", f.Version), m.st.Dim.Render("  " + m.t("i2.upstream2"))}
	case f.Install == preflight.InstallLegacy:
		info = []string{m.st.Accent.Render(m.g.Full) + " " + m.t("i2.legacy"), m.st.Dim.Render("  " + m.t("i2.upstream2"))}
	default:
		info = []string{m.st.Accent.Render(m.g.Full) + " " + m.t("i2.nothing")}
	}
	out := m.box("", info, w, 4, false)
	out = append(out, "")

	lw := (w - 2) / 2
	rw := w - lw - 2
	var items []string
	for i, o := range s.opts {
		title, sub := m.t("i2."+o), m.t("i2."+o+".sub")
		if i == s.cur {
			items = append(items, "", m.st.Sel.Render(padTo(" "+m.g.V+" "+title, lw-6)), m.st.Sel.Render(padTo("   "+sub, lw-6)))
		} else {
			items = append(items, "", m.st.Text.Render("   "+title), m.st.Dim.Render("   "+sub))
		}
	}
	left := m.box(m.t("i2.what"), items, lw, h-len(out), true)

	var cur string
	if len(s.opts) > 0 {
		cur = s.opts[s.cur]
	}
	var rb []string
	rb = append(rb, "", m.st.Text.Bold(true).Render(m.t("i2.will")), "")
	for _, ln := range wrap(m.t("i2."+cur+".what"), rw-6) {
		rb = append(rb, ln)
	}
	rb = append(rb, "", m.st.OK.Render(m.t("i2."+cur+".time")))
	pend := m.t("i2.no")
	pendSt := m.st.OK
	if f.NeedsResume {
		pend, pendSt = m.t("i2.yes"), m.st.Warn
	}
	rb = append(rb, "", m.st.Dim.Render(m.t("i2.unfinished")+" ")+pendSt.Render(pend))
	right := m.box(m.t("i2.title_"+cur), rb, rw, h-len(out), false)
	out = append(out, cols(left, lw, right, rw, 2)...)
	return out
}
