package tui

import (
	"strings"

	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
)

type modRow struct {
	id     string // "" for a group header
	header string
	indent bool
}

type modState struct {
	preset   string
	explicit []string
	sel      *resolve.Selection
	rows     []modRow
	cur      int
	inited   bool
	notice   string // already translated lines
	cascade  *resolve.Warning
}

// enter prepares the module list when the screen is opened.
func (s *modState) enter(m *Model) {
	if !s.inited {
		s.inited = true
		s.rows = m.buildRows()
		switch {
		case m.md.mode == ModeModules && m.be.Installed() != nil:
			s.explicit = append([]string(nil), m.be.Installed().Modules...)
			s.preset = resolve.PresetCustom
		case len(s.explicit) > 0:
			s.preset = resolve.PresetCustom
		default:
			if s.preset == "" {
				s.preset = resolve.PresetFull
			}
			s.applyPreset(m, s.preset)
		}
		s.resolve(m)
		s.cur = s.firstRow()
	}
	m.wiz.rebuild(m)
}

func (s *modState) firstRow() int {
	for i, r := range s.rows {
		if r.id != "" {
			return i
		}
	}
	return 0
}

func (s *modState) applyPreset(m *Model, name string) {
	if name == resolve.PresetCustom || m.res == nil {
		return
	}
	list, err := m.res.Preset(name, resolve.Detect{Tags: m.chk.report.Facts.Tags()})
	if err == nil {
		s.explicit = list
	}
}

func (s *modState) resolve(m *Model) {
	if m.res == nil {
		return
	}
	sel, err := m.res.Resolve(s.explicit)
	if err != nil {
		return
	}
	s.sel = sel
}

// buildRows groups the manifests (required / build features / upstream).
func (m *Model) buildRows() []modRow {
	if m.set == nil {
		return nil
	}
	groups := []struct {
		key  string
		keep func(*manifest.Manifest) bool
	}{
		{"i3.g_core", func(x *manifest.Manifest) bool { return x.Core }},
		{"i3.g_build", func(x *manifest.Manifest) bool { return !x.Core && x.Group != "upstream" && x.Group != "system" }},
		{"i3.g_system", func(x *manifest.Manifest) bool { return !x.Core && (x.Group == "upstream" || x.Group == "system") }},
	}
	var rows []modRow
	for _, g := range groups {
		var in []*manifest.Manifest
		for _, x := range m.set.List {
			if g.keep(x) {
				in = append(in, x)
			}
		}
		if len(in) == 0 {
			continue
		}
		rows = append(rows, modRow{header: g.key})
		inGroup := map[string]bool{}
		for _, x := range in {
			inGroup[x.ID] = true
		}
		parentOf := func(x *manifest.Manifest) string {
			for _, r := range x.Requires {
				if inGroup[r] {
					if p, _ := m.set.Get(r); p != nil && !p.Core {
						return r
					}
				}
			}
			return ""
		}
		for _, x := range in {
			if parentOf(x) != "" {
				continue
			}
			rows = append(rows, modRow{id: x.ID})
			for _, y := range in {
				if parentOf(y) == x.ID {
					rows = append(rows, modRow{id: y.ID, indent: true})
				}
			}
		}
	}
	return rows
}

func (s *modState) move(d int) {
	i := s.cur
	for {
		i += d
		if i < 0 || i >= len(s.rows) {
			return
		}
		if s.rows[i].id != "" {
			s.cur = i
			return
		}
	}
}

func (m *Model) modulesKey(k tea.KeyPressMsg) tea.Cmd {
	s := &m.mod
	key := strings.ToLower(k.String())
	if s.cascade != nil {
		switch key {
		case "enter", "y":
			if ex, _, err := m.res.Deselect(s.explicit, s.cascade.Module, true); err == nil {
				s.explicit = ex
				s.preset = resolve.PresetCustom
				s.notice = m.t("i3.both_off", m.names(append([]string{s.cascade.Module}, s.cascade.Affected...)))
			}
			s.cascade = nil
			s.resolve(m)
		case "esc", "n":
			s.cascade = nil
			s.notice = ""
		}
		return nil
	}
	switch key {
	case "up", "k":
		s.move(-1)
	case "down", "j":
		s.move(1)
	case "space", " ":
		m.toggle(s.rows[s.cur].id)
	case "1":
		s.preset = resolve.PresetFull
		s.applyPreset(m, resolve.PresetFull)
		s.notice = ""
		s.resolve(m)
	case "2":
		s.preset = resolve.PresetMinimal
		s.applyPreset(m, resolve.PresetMinimal)
		s.notice = ""
		s.resolve(m)
	case "3":
		s.preset = resolve.PresetCustom
	case "enter":
		m.wiz.rebuild(m)
		if len(m.wiz.pages) > 0 {
			m.wiz.page = 0
			m.wiz.focus = 0
			m.go2(ScrWizard)
			return m.wiz.onEnterPage(m)
		}
		m.sumEnter()
	case "esc":
		m.back()
	case "q":
		return m.quitNow(ActionExit)
	}
	return nil
}

func (m *Model) names(ids []string) string {
	var out []string
	for _, id := range ids {
		if x, ok := m.set.Get(id); ok {
			out = append(out, m.txt(x.Name))
		}
	}
	return strings.Join(out, ", ")
}

func (m *Model) toggle(id string) {
	s := &m.mod
	if id == "" || m.res == nil {
		return
	}
	x, _ := m.set.Get(id)
	if x != nil && x.Core {
		s.notice = m.t("i3.core_locked")
		return
	}
	s.notice = ""
	if s.sel != nil && s.sel.Has(id) {
		ex, warn, err := m.res.Deselect(s.explicit, id, false)
		if err != nil {
			return
		}
		if warn != nil {
			s.cascade = warn
			return
		}
		s.explicit = ex
		s.preset = resolve.PresetCustom
		s.resolve(m)
		return
	}
	next := append(append([]string(nil), s.explicit...), id)
	sel, err := m.res.Resolve(next)
	if err != nil {
		var ce *resolve.ConflictError
		if asConflict(err, &ce) {
			s.notice = m.t("i3.conflict", m.names([]string{ce.A}), m.names([]string{ce.B}))
		}
		return
	}
	var added []string
	for _, a := range sel.Modules {
		if a != id && (s.sel == nil || !s.sel.Has(a)) {
			added = append(added, a)
		}
	}
	if len(added) > 0 {
		s.notice = m.t("i3.auto_on", m.names(added))
	}
	s.explicit, s.sel = next, sel
	s.preset = resolve.PresetCustom
}

// totals sums the estimates of the selection.
func (m *Model) totals() (dl, disk float64, secs int) {
	if m.mod.sel == nil {
		return
	}
	for _, id := range m.mod.sel.Modules {
		if x, ok := m.set.Get(id); ok {
			dl += x.Estimate.DownloadMiB
			disk += x.Estimate.DiskMiB
			secs += x.Estimate.InstallS + x.Estimate.BuildS
		}
	}
	secs += int(dl * (1 << 20) / m.speed())
	return
}

func (m *Model) speed() float64 {
	if v := m.chk.report.Facts.NetSpeedBps; v > 0 {
		return v
	}
	return eta.DefaultSpeed
}

func (m *Model) modulesFooter() string {
	if m.mod.cascade != nil {
		return m.hints("Enter", m.t("f.remove_both"), "Esc", m.t("f.cancel"))
	}
	return m.hints(m.g.Updown, m.t("f.select"), "Space", m.t("f.toggle"), "1 2 3", m.t("f.preset"), "Enter", m.t("f.next"), "Esc", m.t("f.back"))
}

func (m *Model) modulesView(w, h int) []string {
	s := &m.mod
	var out []string
	pr := m.t("i3.preset") + " "
	line := m.st.Dim.Render(pr)
	for i, p := range []string{resolve.PresetFull, resolve.PresetMinimal, resolve.PresetCustom} {
		lbl := itoa(i+1) + " " + m.t("i3.p_"+p)
		if s.preset == p {
			line += m.pill(lbl) + " "
		} else {
			line += m.st.Key.Render(" "+lbl+" ") + " "
		}
	}
	out = append(out, line, "")

	lw := w * 58 / 100
	rw := w - lw - 2
	iw := lw - 4
	var body []string
	for i, r := range s.rows {
		if r.id == "" {
			body = append(body, m.st.Dim.Bold(true).Render(strings.ToUpper(m.t(r.header))))
			continue
		}
		x, _ := m.set.Get(r.id)
		on := s.sel != nil && s.sel.Has(r.id)
		auto := on && len(s.sel.Auto[r.id]) > 0 && !contains(s.explicit, r.id)
		mark := m.g.BoxOff
		switch {
		case x.Core:
			mark = m.g.BoxPart
		case on:
			mark = m.g.Box
		}
		name := m.txt(x.Name)
		if r.id == "nvidia" && contains(m.chk.report.Facts.GPUs, "nvidia") {
			name += " (" + m.t("i3.gpu_found") + ")"
		}
		if r.indent {
			name = m.g.Tree + " " + name
			mark = "  " + mark
		}
		size := padLeft(m.sizeText(x.Estimate.DownloadMiB), 9)
		dur := padLeft(m.durText(x.Estimate.InstallS+x.Estimate.BuildS), 7)
		if auto {
			dur = padLeft(m.t("i3.auto"), 7)
		}
		left := mark + " " + name
		row := padTo(m.trunc(left, iw-17), iw-16) + size + dur
		switch {
		case i == s.cur:
			body = append(body, m.st.Sel.Render(padTo(row, iw)))
		case auto:
			body = append(body, m.st.Pink.Render(row))
		case !on:
			body = append(body, m.st.Dim.Render(row))
		default:
			body = append(body, row)
		}
	}
	// keep the cursor row visible
	view := h - len(out) - 2
	body = scrollTo(body, s.cur, view)
	left := m.box(m.t("i3.title"), body, lw, h-len(out), true)

	cur := s.rows[min(s.cur, max(len(s.rows)-1, 0))]
	var right []string
	if cur.id != "" {
		x, _ := m.set.Get(cur.id)
		d := []string{""}
		d = append(d, wrap(m.txt(x.Desc), rw-4)...)
		if n := m.txt(x.Notes); n != "" {
			d = append(d, "")
			d = append(d, wrap(n, rw-4)...)
		}
		if len(x.Packages) > 0 {
			d = append(d, "", m.st.Dim.Render(m.t("i3.packages")+" "+strings.Join(x.Packages, " ")))
		}
		right = append(right, m.box(m.txt(x.Name), d, rw, 10, false)...)
	}
	var nb []string
	switch {
	case s.cascade != nil:
		nb = append([]string{m.st.Pink.Bold(true).Render(m.g.Tree + " " + m.t("i3.cascade_t", m.names([]string{s.cascade.Module})))},
			wrap(m.t("i3.cascade", m.names(s.cascade.Affected)), rw-4)...)
		nb = append(nb, "", m.button(m.t("i3.remove_both"), true)+" "+m.button(m.t("i3.cancel"), false))
	case s.notice != "":
		nb = wrap(s.notice, rw-4)
	default:
		for _, ln := range wrap(m.t("i3.hint"), rw-4) {
			nb = append(nb, m.st.Dim.Render(ln))
		}
	}
	right = append(right, m.box("", nb, rw, 8, s.cascade != nil)...)

	dl, disk, secs := m.totals()
	tb := []string{
		"",
		m.st.Dim.Render(padRight(m.t("i3.dl"), 9)) + m.st.Text.Bold(true).Render(m.sizeText(dl)),
		m.st.Dim.Render(padRight(m.t("i3.disk"), 9)) + m.st.Text.Bold(true).Render(m.sizeText(disk)),
		m.st.Dim.Render(padRight(m.t("i3.time"), 9)) + m.st.AccentB.Render(eta.Format(secDur(secs), m.lang)),
		m.st.Dim.Render(m.t("i3.at_speed", fmtF(m.speed()/(1<<20), 0))),
	}
	right = append(right, m.box(m.t("i3.total"), tb, rw, h-len(out)-len(right), false)...)
	out = append(out, cols(left, lw, right, rw, 2)...)
	return out
}
