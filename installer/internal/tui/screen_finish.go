package tui

import (
	"io"
	"strings"

	tea "charm.land/bubbletea/v2"
)

type finState struct {
	btns       []string // reboot | hyprland | exit
	cur        int
	ok         bool
	installed  []string
	notes      []string
	needReboot bool
	logOn      bool
}

func (m *Model) finEnter() {
	p := &m.prg
	f := &m.fin
	*f = finState{ok: p.err == nil}
	skipped := map[string]bool{}
	for _, s := range p.result.Skipped {
		skipped[s] = true
	}
	for _, s := range p.skippedMods {
		skipped[s] = true
	}
	mode := m.md.mode
	if f.ok && (mode == ModeInstall || mode == ModeModules) {
		for _, id := range m.targetModules() {
			if skipped[id] {
				continue
			}
			x, _ := m.set.Get(id)
			f.installed = append(f.installed, m.txt(x.Name))
			if id == "nvidia" {
				f.needReboot = true
			}
		}
	}
	for id := range skipped {
		if id == "" {
			continue
		}
		f.notes = append(f.notes, "skip:"+id)
	}
	sortStrings(f.notes)
	if f.ok {
		if later := m.laterList(); len(later) > 0 {
			f.notes = append(f.notes, "later:"+strings.Join(later, ", "))
		}
		if p.result.Restored != "" {
			f.notes = append(f.notes, "restored:"+p.result.Restored)
		}
		if len(p.result.Retype) > 0 {
			f.notes = append(f.notes, "retype:"+strings.Join(p.result.Retype, ", "))
		}
		if f.needReboot {
			f.notes = append(f.notes, "reboot:")
		}
		switch {
		case mode == ModeUninstall:
			f.btns = []string{ActionExit}
		case f.needReboot:
			f.btns = []string{ActionReboot, ActionHyprland, ActionExit}
		default:
			f.btns = []string{ActionHyprland, ActionReboot, ActionExit}
		}
	} else {
		f.btns = []string{ActionExit}
	}
	m.result.OK = f.ok
	m.result.Err = p.err
	m.go2(ScrFinish)
}

func sortStrings(l []string) {
	for i := 1; i < len(l); i++ {
		for j := i; j > 0 && l[j] < l[j-1]; j-- {
			l[j], l[j-1] = l[j-1], l[j]
		}
	}
}

func (m *Model) finishKey(k tea.KeyPressMsg) tea.Cmd {
	f := &m.fin
	switch strings.ToLower(k.String()) {
	case "left", "up", "shift+tab":
		f.cur = clampInt(f.cur-1, 0, len(f.btns)-1)
	case "right", "down", "tab":
		f.cur = clampInt(f.cur+1, 0, len(f.btns)-1)
	case "l":
		f.logOn = !f.logOn
	case "enter":
		return m.quitNow(f.btns[f.cur])
	case "q", "esc":
		return m.quitNow(ActionExit)
	}
	return nil
}

func (m *Model) finishFooter() string {
	return m.hints(m.g.Updown, m.t("f.select"), "Enter", m.t("f.run"), "L", m.t("f.log"), "F2", m.t("f.lang"))
}

func (m *Model) finishView(w, h int) []string {
	f := &m.fin
	p := &m.prg
	var out []string
	took := m.spent(p.ended.Sub(p.started))
	if f.ok {
		out = append(out, m.st.OK.Render(m.g.Check)+" "+m.st.Text.Bold(true).Render(m.t("fin.done_in."+m.md.mode, took))+
			"   "+m.st.Dim.Render(m.t("fin.build", m.cfg.Version)))
	} else {
		out = append(out, m.st.Bad.Render(m.g.Cross)+" "+m.st.Text.Bold(true).Render(m.t("fin.failed")))
	}
	out = append(out, "")
	lw := w * 46 / 100
	rw := w - lw - 2
	boxH := 0
	var left []string
	left = append(left, "")
	switch {
	case !f.ok:
		for _, ln := range wrap(m.t("fin.failed_text"), lw-4) {
			left = append(left, ln)
		}
		if p.err != nil {
			left = append(left, "", m.st.Dim.Render(m.trunc(oneLine(p.err.Error()), lw-4)))
		}
	case m.md.mode == ModeInstall || m.md.mode == ModeModules:
		for _, n := range f.installed {
			left = append(left, m.st.OK.Render(m.g.Check)+" "+n)
		}
	default:
		left = append(left, m.st.OK.Render(m.g.Check)+" "+m.t("fin.mode."+m.md.mode))
	}
	ltitle := m.t("fin.installed", len(f.installed))
	if !f.ok {
		ltitle = m.t("fin.state")
	} else if m.md.mode != ModeInstall && m.md.mode != ModeModules {
		ltitle = m.t("fin.result")
	}
	var right []string
	right = append(right, "")
	for _, n := range f.notes {
		kind, val, _ := strings.Cut(n, ":")
		switch kind {
		case "skip":
			x, _ := m.set.Get(val)
			name := val
			if x != nil {
				name = m.txt(x.Name)
			}
			right = append(right, m.st.Warn.Render(m.g.Skip+" "+m.t("fin.skipped", name)), "  "+m.st.Dim.Render(m.t("fin.add_later")+" ")+m.st.Accent.Render("serp-installer modules"), "")
		case "later":
			right = append(right, m.st.Text.Bold(true).Render(m.g.Empty+" "+m.t("fin.later")))
			for _, ln := range wrap(val, rw-8) {
				right = append(right, "  "+ln)
			}
			right = append(right, "")
		case "restored":
			right = append(right, m.st.Text.Bold(true).Render(m.g.Resume+" "+m.t("fin.restored")), "  "+val, "")
		case "retype":
			right = append(right, m.st.Warn.Render(m.g.Warn+" "+m.t("fin.retype")))
			for _, ln := range wrap(val, rw-8) {
				right = append(right, "  "+ln)
			}
			right = append(right, "")
		case "reboot":
			right = append(right, m.st.Warn.Render(m.g.Warn+" "+m.t("fin.reboot")), "")
		}
	}
	if len(right) == 1 && f.ok {
		right = append(right, m.st.Dim.Render(m.t("fin.nothing")))
	}
	if !f.ok {
		right = append(right, wrap(m.t("fin.resume_hint"), rw-4)...)
		right = append(right, m.st.Accent.Render("serp-installer install --resume"))
	}
	boxH = clampInt(max(len(left), len(right))+2, 8, h-11)
	out = append(out, cols(m.box(ltitle, left, lw, boxH, false), lw, m.box(m.t("fin.attention"), right, rw, boxH, false), rw, 2)...)
	out = append(out, "")
	var files []string
	files = append(files, m.st.Dim.Render(padRight(m.t("fin.log"), 8))+m.st.Accent.Render(m.be.LogPath()))
	if p.result.BackupPath != "" {
		files = append(files, m.st.Dim.Render(padRight(m.t("fin.backup"), 8))+m.st.Accent.Render(p.result.BackupPath))
	}
	if p.result.ConfigPath != "" {
		files = append(files, m.st.Dim.Render(padRight(m.t("fin.config"), 8))+m.st.Accent.Render(p.result.ConfigPath)+m.st.Dim.Render("  ("+m.t("fin.config_note")+")"))
	}
	if f.logOn {
		out = append(out, m.logBox(w, 8)...)
	} else {
		out = append(out, m.box(m.t("fin.files"), files, w, 0, false)...)
	}
	out = append(out, "")
	var bl []string
	for i, b := range f.btns {
		lbl := m.t("fin.b." + b)
		if b == ActionReboot && f.needReboot {
			lbl = m.t("fin.b.reboot_nv")
		}
		bl = append(bl, m.button(lbl, i == f.cur))
	}
	out = append(out, strings.Join(bl, " "))
	return out
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// VT palette (Linux console): \e]P<hex index><rrggbb> reprograms a colour so
// the 16-colour theme gets the Serpantinum hues; \e]R resets it.
var vtPalette = [16]string{"0f0d14", "f38ba8", "a6e3a1", "f9e2af", "89b4fa", "6e5aa8", "94e2d5", "e6e1ee",
	"7a7690", "f4b8c8", "a6e3a1", "f9e2af", "89b4fa", "c8b6ff", "94e2d5", "ffffff"}

// ApplyVTPalette reprograms the console palette.
func ApplyVTPalette(w io.Writer) {
	var b strings.Builder
	for i, c := range vtPalette {
		b.WriteString("\x1b]P" + strings.ToUpper(string("0123456789abcdef"[i])) + c)
	}
	io.WriteString(w, b.String())
}

// ResetVTPalette restores the default console palette.
func ResetVTPalette(w io.Writer) { io.WriteString(w, "\x1b]R") }

// Run starts the full-screen program and returns what the user chose.
func Run(cfg Config, opts ...tea.ProgramOption) (Result, error) {
	m := New(cfg)
	p := tea.NewProgram(m, opts...)
	fm, err := p.Run()
	if fm, ok := fm.(*Model); ok {
		return fm.Result(), err
	}
	return m.Result(), err
}
