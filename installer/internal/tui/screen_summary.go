package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/eta"
)

type sumState struct {
	plan       *PlanInfo
	planErr    string
	seq        int
	btn        int // 0 back, 1 start
	note       string
	exported   string
	removeData bool
}

// queue adds a command to run after the current key/message is handled.
func (m *Model) queue(c tea.Cmd) {
	if c != nil {
		m.pend = append(m.pend, c)
	}
}

// request collects everything the wizard decided.
func (m *Model) request() Request {
	cfg, sec := m.wiz.values()
	r := Request{Mode: m.md.mode, Config: cfg, Secrets: sec, Lang: m.lang, Restore: m.cfg.Restore,
		Resume: m.md.resume, Reinstall: m.md.reinstall, RemoveData: m.sum.removeData}
	if r.Mode == ModeInstall || r.Mode == ModeModules {
		r.Modules = append([]string(nil), m.mod.explicit...)
	}
	return r
}

func (m *Model) sumEnter() {
	m.sum.plan, m.sum.planErr, m.sum.note = nil, "", ""
	m.sum.btn = 1
	m.sum.seq++
	seq := m.sum.seq
	req := m.request()
	be, ctx := m.be, m.ctx
	m.queue(func() tea.Msg {
		p, err := be.Plan(ctx, req)
		return planMsg{seq: seq, plan: p, err: err}
	})
	m.go2(ScrSummary)
}

func (m *Model) onPlan(msg planMsg) {
	if msg.seq != m.sum.seq {
		return
	}
	if msg.err != nil {
		m.sum.planErr = msg.err.Error()
		return
	}
	p := msg.plan
	m.sum.plan = &p
}

func (m *Model) summaryKey(k tea.KeyPressMsg) tea.Cmd {
	s := &m.sum
	switch strings.ToLower(k.String()) {
	case "enter":
		if s.btn == 0 {
			m.back()
			return nil
		}
		if s.plan != nil {
			return m.startRun()
		}
	case "left", "up", "shift+tab":
		s.btn = 0
	case "right", "down", "tab":
		s.btn = 1
	case "esc":
		m.back()
	case "e":
		if m.md.mode == ModeInstall || m.md.mode == ModeModules {
			be, req := m.be, m.request()
			return func() tea.Msg {
				p, err := be.ExportSetup(req)
				return savedMsg{what: "setup", path: p, err: err}
			}
		}
	case "d":
		if m.md.mode == ModeUninstall {
			s.removeData = !s.removeData
			m.sumEnter()
			m.sum.btn = 1
		}
	case "q":
		return m.quitNow(ActionExit)
	}
	return nil
}

func (m *Model) summaryFooter() string {
	switch m.md.mode {
	case ModeInstall, ModeModules:
		return m.hints("Enter", m.t("f.start"), "Esc", m.t("f.back_fix"), "e", m.t("f.export"), "F2", m.t("f.lang"))
	case ModeUninstall:
		return m.hints("Enter", m.t("f.start"), "d", m.t("f.data"), "Esc", m.t("f.back"), "F2", m.t("f.lang"))
	}
	return m.hints("Enter", m.t("f.start"), "Esc", m.t("f.back"), "F2", m.t("f.lang"))
}

func (m *Model) setting(k, v string, st string) string {
	sty := m.st.Text
	switch st {
	case "ok":
		sty = m.st.OK
	case "dim":
		sty = m.st.Dim
	case "acc":
		sty = m.st.Accent
	}
	return m.st.Dim.Render(padRight(k, 14)) + sty.Render(v)
}

func (m *Model) has(id string) bool { return m.mod.sel != nil && m.mod.sel.Has(id) }

func (m *Model) secretSet(key string) bool {
	f := m.wiz.cache[key]
	return f != nil && f.in.Value() != "" && !m.wiz.skipped[f.module]
}

// laterList names what stays to be configured after the install.
func (m *Model) laterList() []string {
	var out []string
	seen := map[string]bool{}
	for _, id := range m.targetModules() {
		x, _ := m.set.Get(id)
		if x == nil {
			continue
		}
		for _, c := range x.Config {
			if c.Kind != "secret" {
				continue
			}
			if f := m.wiz.cache[c.Key]; f != nil && f.in.Value() == "" && !seen[id] {
				seen[id] = true
				out = append(out, m.txt(x.Name))
			}
		}
	}
	return out
}

func (m *Model) settingLines() []string {
	var l []string
	langName := "русский"
	if m.lang == "en" {
		langName = "English"
	}
	l = append(l, "", m.setting(m.t("s.lang"), langName, ""))
	if m.has("ai-gemini") {
		v, st := m.t("s.skipped"), "dim"
		if m.secretSet("ai.gemini_key") {
			v, st = m.t("s.key_set"), "ok"
			if f := m.wiz.cache["ai.proxy"]; f != nil && f.in.Value() != "" {
				v += ", " + m.t("s.proxy")
			} else {
				v += ", " + m.t("s.no_proxy")
			}
		}
		l = append(l, m.setting("Gemini", v, st))
	}
	if m.has("servers") {
		v, st := m.t("s.skipped"), "dim"
		if m.secretSet("servers.remnawave_token") {
			v, st = m.t("s.set"), "ok"
		}
		l = append(l, m.setting("Remnawave", v, st))
		v, st = m.t("s.none"), "dim"
		if m.wiz.ssh != nil && !m.wiz.skipped["servers"] {
			v, st = m.t("s.created"), "ok"
		}
		l = append(l, m.setting(m.t("s.ssh"), v, st))
	}
	if m.has("vpn") {
		v, st := m.t("s.skipped"), "dim"
		if m.secretSet("vpn.subscription") {
			v, st = m.t("s.set"), "ok"
		}
		l = append(l, m.setting("VPN", v, st))
	}
	if f := m.wiz.cache["tools.notes_dir"]; f != nil && m.has("tools") {
		l = append(l, m.setting(m.t("s.notes"), f.in.Value(), ""))
	}
	if m.has("commands") {
		var parts []string
		if f := m.wiz.cache["commands.start_daemon"]; f != nil && f.val == "true" {
			parts = append(parts, m.t("s.daemon"))
		}
		if f := m.wiz.cache["commands.examples"]; f != nil && f.val == "true" {
			parts = append(parts, m.t("s.examples"))
		}
		if len(parts) > 0 {
			l = append(l, m.setting("Commands", strings.Join(parts, " + "), ""))
		}
	}
	if m.chk.report.Facts.Install == "serp-x" || m.md.reinstall {
		l = append(l, m.setting(m.t("s.backup"), m.t("s.backup_before"), ""))
	}
	if m.cfg.Restore != "" {
		l = append(l, m.setting(m.t("s.restore"), m.cfg.Restore, "acc"))
	}
	later := m.laterList()
	lv := m.dash()
	if len(later) > 0 {
		lv = strings.Join(later, ", ")
	}
	l = append(l, "", m.st.Dim.Render(m.t("s.later")))
	for _, ln := range wrap(lv, 48) {
		l = append(l, "  "+m.st.Dim.Render(ln))
	}
	return l
}

func (m *Model) summaryView(w, h int) []string {
	s := &m.sum
	var out []string
	mode := m.md.mode
	head := m.t("s.ready." + mode)
	if m.md.resume {
		head = m.t("s.ready.resume")
	}
	out = append(out, m.st.Text.Bold(true).Render(head), "")
	if s.planErr != "" {
		out = append(out, m.st.Bad.Render(m.g.Cross+" "+m.t("s.plan_fail", s.planErr)))
		out = append(out, "", strings.Join([]string{m.button(m.t("b.back"), true)}, ""))
		return out
	}
	lw := w * 46 / 100
	rw := w - lw - 2
	topH := 14

	var left []string
	left = append(left, "")
	var title string
	switch mode {
	case ModeInstall, ModeModules:
		ids := m.targetModules()
		title = m.t("s.will_install", len(ids))
		for _, id := range ids {
			x, _ := m.set.Get(id)
			left = append(left, m.st.OK.Render(m.g.Check)+" "+m.txt(x.Name))
		}
		var not []string
		for _, x := range m.set.List {
			if m.mod.sel != nil && !m.mod.sel.Has(x.ID) {
				not = append(not, m.txt(x.Name))
			}
		}
		if len(not) > 0 {
			left = append(left, "", m.st.Dim.Render(m.t("s.not_install")+" "+strings.Join(not, ", ")))
		}
	default:
		title = m.t("s.will_do." + mode)
		if s.plan != nil {
			for _, st := range s.plan.Steps {
				left = append(left, m.st.Dim.Render(m.g.Bullet)+" "+m.txt(st.Title))
			}
		} else {
			left = append(left, m.st.Dim.Render(m.spinner()+" "+m.t("s.planning")))
		}
	}
	var right []string
	switch mode {
	case ModeInstall, ModeModules:
		right = m.settingLines()
	case ModeUninstall:
		mark := m.g.BoxOff
		if s.removeData {
			mark = m.g.Box
		}
		right = []string{"", m.st.Text.Render(mark + " " + m.t("s.remove_data")), ""}
		for _, ln := range wrap(m.t("s.data_note"), rw-4) {
			right = append(right, m.st.Dim.Render(ln))
		}
		if s.removeData {
			right = append(right, "", m.st.Warn.Render(m.g.Warn+" "+m.t("s.data_warn")))
		}
	default:
		right = append([]string{""}, wrap(m.t("s.repair_note"), rw-4)...)
	}
	lb := m.box(title, left, lw, topH, false)
	rb := m.box(m.t("s.settings"), right, rw, topH, false)
	out = append(out, cols(lb, lw, rb, rw, 2)...)
	out = append(out, "")

	var root []string
	root = append(root, "")
	if s.plan != nil {
		seen := map[string]bool{}
		for _, st := range s.plan.Steps {
			t := m.txt(st.Title)
			if st.Root && !seen[t] {
				seen[t] = true
				root = append(root, m.g.Bullet+" "+t)
			}
		}
	}
	if len(root) == 1 {
		root = append(root, m.st.Dim.Render(m.g.Bullet+" "+m.t("s.no_root")))
	}
	var dl, disk float64
	var secs int
	if s.plan != nil {
		dl, disk, secs = s.plan.DownloadMiB, s.plan.DiskMiB, s.plan.Seconds
	}
	tot := []string{"",
		m.st.Dim.Render(padRight(m.t("i3.dl"), 9)) + m.st.Text.Bold(true).Render(m.sizeText(dl)),
		m.st.Dim.Render(padRight(m.t("i3.disk"), 9)) + m.st.Text.Bold(true).Render(m.sizeText(disk)),
		m.st.Dim.Render(padRight(m.t("i3.time"), 9)) + m.st.AccentB.Render(eta.Format(secDur(secs), m.lang)),
	}
	bh := 7
	rootBox := m.box(m.t("s.root"), root, rw+lw-34, bh, false)
	totBox := m.box(m.t("s.total"), tot, 32, bh, true)
	out = append(out, cols(rootBox, rw+lw-34, totBox, 32, 2)...)
	out = append(out, "")
	startLbl := m.t("b.start." + mode)
	out = append(out, m.button(m.g.Back+" "+m.t("b.back"), s.btn == 0)+" "+m.button(startLbl, s.btn == 1))
	if s.note != "" {
		out = append(out, "", m.st.OK.Render(m.g.Check+" "+s.note))
	}
	return out
}
