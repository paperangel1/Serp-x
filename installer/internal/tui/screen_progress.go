package tui

import (
	"context"
	"regexp"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/pacman"
	"serpx/installer/internal/plain"
)

const (
	stPending = iota
	stRun
	stDoneS
	stSkipS
	stFailS
)

type stepState struct {
	info    StepInfo
	status  int
	took    time.Duration
	started time.Time
}

type logLine struct {
	at   time.Time
	src  string
	text string
}

type decideReq struct {
	id       string
	err      string
	optional bool
	tail     []string
}

type prgState struct {
	steps   []stepState
	idx     map[string]int
	cur     int
	sess    *session
	cancel  context.CancelFunc
	started time.Time
	ended   time.Time
	trk     *eta.Tracker
	sm      eta.Smoother
	remain  time.Duration

	stepFrac    float64
	shown, vel  float64
	detail      Detail
	hasDetail   bool
	logs        []logLine
	logOn       bool
	logFocus    bool
	vp          viewport.Model
	paused      bool
	confirmQuit bool
	dec         *decideReq
	decBtn      int
	done        bool
	aborting    bool
	err         error
	result      RunResult
	skippedMods []string
	failedStep  string
}

func (m *Model) startRun() tea.Cmd {
	req := m.request()
	s := m.initProgress(*m.sum.plan)
	ctx := s.ctx
	m.go2(ScrProgress)
	be := m.be
	go func() {
		res, err := be.Run(ctx, req, s)
		s.send(evRunEnd{res, err})
	}()
	return s.wait()
}

// initProgress prepares the progress state for a plan and returns the
// session the engine reports to.
func (m *Model) initProgress(plan PlanInfo) *session {
	p := &m.prg
	*p = prgState{idx: map[string]int{}}
	for i, s := range plan.Steps {
		p.steps = append(p.steps, stepState{info: s})
		p.idx[s.ID] = i
	}
	mdl := plan.ETA
	if mdl == nil {
		mdl = eta.New(4)
	}
	if v := m.chk.report.Facts.NetSpeedBps; v > 0 {
		mdl.SetStartSpeed(v)
	}
	items := plan.Items
	if len(items) == 0 {
		for _, s := range plan.Steps {
			items = append(items, eta.Item{ID: s.ID, Kind: eta.KindOther, EstimateS: s.EstSec})
		}
	}
	p.trk = eta.NewTracker(mdl, items)
	p.started = m.now
	p.remain = p.trk.Tick(m.now)
	p.vp = viewport.New(viewport.WithWidth(80), viewport.WithHeight(5))
	ctx, cancel := context.WithCancel(m.ctx)
	s := newSession(ctx)
	p.sess, p.cancel = s, cancel
	return s
}

// weights of the steps for the overall percentage.
func (p *prgState) estOf(i int) float64 {
	e := float64(p.steps[i].info.EstSec)
	if e < 1 {
		e = 1
	}
	return e
}

func (p *prgState) fraction(now time.Time) float64 {
	var total, done float64
	for i := range p.steps {
		e := p.estOf(i)
		total += e
		switch p.steps[i].status {
		case stDoneS, stSkipS:
			done += e
		case stRun:
			f := p.stepFrac
			if f <= 0 {
				f = min(0.95, now.Sub(p.steps[i].started).Seconds()/e)
			}
			done += e * f
		}
	}
	if total == 0 {
		return 0
	}
	return min(done/total, 1)
}

func (m *Model) progTick() {
	p := &m.prg
	if m.screen != ScrProgress || p.done || p.sess == nil {
		return
	}
	if p.paused {
		return
	}
	target := p.fraction(m.now)
	p.shown, p.vel = m.spring.Update(p.shown, p.vel, target)
	if p.shown < 0 {
		p.shown = 0
	}
	if m.frame%10 == 0 && p.trk != nil {
		p.remain = p.sm.Update(p.trk.Remaining(m.now))
	}
}

func (m *Model) feed(id, kind string) {
	if m.prg.trk != nil {
		m.prg.trk.Feed(eta.Event{Step: id, Kind: kind, At: m.now})
	}
}

var pacmanLine = regexp.MustCompile(`^\s*\S+\s+[\d.,]+ [KMGT]?i?B`)

func (m *Model) addLog(id, line string) {
	p := &m.prg
	src := "engine"
	if _, ok := pacman.ParseProgress(line); ok || pacmanLine.MatchString(line) {
		src = "pacman"
	} else if strings.HasPrefix(line, "==>") || strings.Contains(line, "makepkg") {
		src = "makepkg"
	}
	p.logs = append(p.logs, logLine{at: m.now, src: src, text: strings.TrimRight(line, "\r\n")})
	if len(p.logs) > 4000 {
		p.logs = p.logs[len(p.logs)-3000:]
	}
}

func (m *Model) onSession(msg sessMsg) tea.Cmd {
	p := &m.prg
	s := p.sess
	if s == nil {
		return nil
	}
	switch e := msg.ev.(type) {
	case evStart:
		if i, ok := p.idx[e.id]; ok {
			p.cur = i
			p.steps[i].status = stRun
			p.steps[i].started = m.now
		}
		p.stepFrac, p.hasDetail = 0, false
		m.feed(e.id, "start")
	case evProgress:
		p.stepFrac = float64(e.pct) / 100
	case evLog:
		m.addLog(e.id, e.line)
		if pr, ok := pacman.ParseProgress(e.line); ok && pr.Phase == pacman.PhaseDownload {
			p.detail.File = pr.Name
			p.hasDetail = true
		}
	case evDetail:
		p.detail, p.hasDetail = e.d, true
		if e.d.TotalMiB > 0 {
			p.stepFrac = min(e.d.DoneMiB/e.d.TotalMiB, 1)
			m.feed(e.id, "bytes")
		}
	case evDone:
		if i, ok := p.idx[e.id]; ok {
			p.steps[i].took = m.now.Sub(p.steps[i].started)
			p.steps[i].status = stDoneS
			if e.skipped {
				p.steps[i].status = stSkipS
			}
		}
		p.stepFrac = 0
		kind := "done"
		if e.skipped {
			kind = "skip"
		}
		m.feed(e.id, kind)
	case evFail:
		if i, ok := p.idx[e.id]; ok {
			p.steps[i].status = stFailS
		}
		p.failedStep = e.id
		m.addLog(e.id, "FAILED: "+e.err)
		m.feed(e.id, "fail")
	case evDecide:
		p.dec = &decideReq{id: e.id, err: e.err, optional: e.optional, tail: e.tail}
		p.decBtn = 0
	case evRunEnd:
		p.done = true
		p.ended = m.now
		p.err = e.err
		p.result = e.res
		s.close()
		m.finEnter()
		return nil
	}
	return s.wait()
}

// decide sends the user's choice to the engine.
func (m *Model) decide(d plain.Decision) {
	p := &m.prg
	if p.dec == nil {
		return
	}
	if i, ok := p.idx[p.dec.id]; ok && d == plain.Retry {
		p.steps[i].status = stRun
		p.steps[i].started = m.now
	}
	if d == plain.Skip {
		mod := p.steps[p.idx[p.dec.id]].info.Module
		p.skippedMods = append(p.skippedMods, mod)
	}
	p.dec = nil
	select {
	case p.sess.dec <- d:
	default:
	}
}

func (m *Model) decideButtons() []plain.Decision {
	b := []plain.Decision{plain.Retry}
	if m.prg.dec != nil && m.prg.dec.optional {
		b = append(b, plain.Skip)
	}
	return append(b, plain.Abort)
}

func (m *Model) progressKey(k tea.KeyPressMsg) tea.Cmd {
	p := &m.prg
	key := strings.ToLower(k.String())
	if p.dec != nil {
		btns := m.decideButtons()
		switch key {
		case "left", "shift+tab", "up":
			p.decBtn = (p.decBtn - 1 + len(btns)) % len(btns)
		case "right", "tab", "down":
			p.decBtn = (p.decBtn + 1) % len(btns)
		case "enter":
			m.decide(btns[p.decBtn])
		case "r":
			m.decide(plain.Retry)
		case "s":
			if p.dec.optional {
				m.decide(plain.Skip)
			}
		case "a", "esc":
			m.decide(plain.Abort)
		case "l":
			p.logOn = !p.logOn
		}
		return nil
	}
	if p.confirmQuit {
		switch key {
		case "y", "enter":
			p.confirmQuit, p.aborting = false, true
			p.cancel()
			if p.sess != nil {
				p.sess.setPaused(false)
			}
		case "n", "esc", "q":
			p.confirmQuit = false
		}
		return nil
	}
	switch key {
	case "l":
		p.logOn = !p.logOn
		if !p.logOn {
			p.logFocus = false
		}
	case "tab":
		if p.logOn {
			p.logFocus = !p.logFocus
		}
	case "p":
		p.paused = !p.paused
		p.sess.setPaused(p.paused)
	case "q":
		p.confirmQuit = true
	case "up", "pgup":
		if p.logFocus {
			p.vp.ScrollUp(1)
		}
	case "down", "pgdown":
		if p.logFocus {
			p.vp.ScrollDown(1)
		}
	}
	return nil
}

func (m *Model) progressFooter() string {
	p := &m.prg
	logLbl := m.t("f.log")
	if p.logOn {
		logLbl = m.t("f.hide_log")
	}
	switch {
	case p.dec != nil:
		return m.hints("Tab", m.t("f.choose"), "Enter", m.t("f.do"), "L", m.t("f.full_log"))
	case p.confirmQuit:
		return m.hints("y", m.t("f.yes"), "n", m.t("f.no"))
	}
	pause := m.t("f.pause")
	if p.paused {
		pause = m.t("f.resume")
	}
	return m.hints("L", logLbl, "Tab", m.t("f.focus"), "p", pause, "q", m.t("f.abort_safe"))
}

// bar draws a progress bar of bw cells with 1/8 steps.
func (m *Model) bar(frac float64, bw int, fill, rest lipgloss.Style) string {
	frac = min(max(frac, 0), 1)
	cells := frac * float64(bw)
	full := int(cells)
	var b strings.Builder
	b.WriteString(fill.Render(strings.Repeat(m.g.BarFull, full)))
	used := full
	if part := m.g.BarPart; part != nil && full < bw {
		if i := int((cells - float64(full)) * 8); i > 0 {
			b.WriteString(fill.Render(part[i-1]))
			used++
		}
	}
	b.WriteString(rest.Render(strings.Repeat(m.g.BarEmpty, max(bw-used, 0))))
	return b.String()
}

func (m *Model) progressView(w, h int) []string {
	p := &m.prg
	var out []string
	n := len(p.steps)
	cur := min(p.cur+1, max(n, 1))
	title := ""
	if p.cur < n {
		title = m.txt(p.steps[p.cur].info.Title)
	}
	out = append(out, m.st.Dim.Render(m.t("p.step", cur, n)+"  "+m.g.Bullet+"  ")+m.st.Text.Bold(true).Render(title))
	out = append(out, "")
	pct := int(p.shown*100 + 0.5)
	if p.done && p.err == nil {
		pct = 100
	}
	out = append(out, m.bar(p.shown, w-8, m.st.Accent, m.st.Dim)+"  "+m.st.AccentB.Render(itoa(pct)+"%"))
	el := m.now.Sub(p.started)
	if p.done {
		el = p.ended.Sub(p.started)
	}
	rem := m.st.AccentB.Render(eta.Format(p.remain, m.lang))
	hint := m.t("p.eta_hint")
	if p.paused {
		hint = m.t("p.paused")
	}
	out = append(out, m.st.Dim.Render(m.t("p.elapsed")+" ")+clock(el)+"   "+m.st.Dim.Render(m.t("p.left")+" ")+rem+"  "+m.st.Dim.Render("("+hint+")"))
	out = append(out, "")

	boxH := h - len(out)
	logH := 0
	if p.logOn {
		logH = 8
		boxH -= logH
	}
	lw := w * 51 / 100
	rw := w - lw - 2
	out = append(out, cols(m.stepsBox(lw, boxH), lw, m.nowBox(rw, boxH), rw, 2)...)
	if p.logOn {
		out = append(out, m.logBox(w, logH)...)
	}
	return out
}

func (m *Model) stepsBox(w, h int) []string {
	p := &m.prg
	iw := w - 4
	var rows []string
	for i, s := range p.steps {
		title := m.txt(s.info.Title)
		var mark, right string
		switch s.status {
		case stDoneS:
			mark, right = m.st.OK.Render(m.g.Check), m.st.Dim.Render(clockMS(s.took))
		case stSkipS:
			mark, right = m.st.Dim.Render(m.g.Skip), m.st.Dim.Render(m.t("p.skipped"))
		case stFailS:
			mark, right = m.st.Bad.Render(m.g.Cross), m.st.Bad.Render(m.t("p.failed"))
		case stRun:
			mark = m.st.Accent.Render(m.spinner())
		default:
			mark = m.st.Dim.Render(m.g.Empty)
			right = m.st.Dim.Render(m.g.Cursor[:0] + "≈ " + clockMS(secDur(s.info.EstSec)))
			if m.g.Mode == GlyphASCII {
				right = m.st.Dim.Render("~ " + clockMS(secDur(s.info.EstSec)))
			}
		}
		l := m.trunc(title, iw-width(right)-4)
		row := mark + " " + padTo(l, iw-width(right)-3) + " " + right
		switch {
		case s.status == stRun:
			row = m.st.Sel.Render(padTo(ansi.Strip(row), iw))
		case s.status == stDoneS || s.status == stSkipS:
			// dim titles of finished steps
			row = mark + " " + m.st.Dim.Render(padTo(l, iw-width(right)-3)) + " " + right
		}
		rows = append(rows, row)
		_ = i
	}
	rows = scrollTo(rows, p.cur, h-2)
	return m.box(m.t("p.steps"), rows, w, h, !p.logFocus)
}

func clockMS(d time.Duration) string {
	s := int(d.Seconds())
	return itoaPad(s/60) + ":" + itoaPad2(s%60)
}

func itoaPad(n int) string { return itoa(n) }
func itoaPad2(n int) string {
	if n < 10 {
		return "0" + itoa(n)
	}
	return itoa(n)
}

func (m *Model) nowBox(w, h int) []string {
	p := &m.prg
	var b []string
	b = append(b, "")
	if p.cur < len(p.steps) {
		b = append(b, wrap(m.t("p.now.generic", m.txt(p.steps[p.cur].info.Title)), w-4)...)
	}
	if p.hasDetail && p.detail.TotalMiB > 0 {
		d := p.detail
		b = append(b, "", m.st.Dim.Render(m.t("p.got")+" ")+m.t("p.of", fmtF(d.DoneMiB, 0), fmtF(d.TotalMiB, 0)))
		b = append(b, m.bar(min(d.DoneMiB/d.TotalMiB, 1), w-6, m.st.Pink, m.st.Dim))
		b = append(b, m.st.Dim.Render(m.t("p.speed")+" ")+fmtF(d.SpeedMBs, 1)+" "+m.t("u.mbs"))
		if d.File != "" {
			b = append(b, m.st.Dim.Render(m.t("p.file")+" ")+m.st.Accent.Render(d.File))
		}
	} else if p.hasDetail && p.detail.File != "" {
		b = append(b, "", m.st.Dim.Render(m.t("p.file")+" ")+m.st.Accent.Render(p.detail.File))
	}
	b = append(b, "")
	for _, ln := range wrap(m.t("p.away"), w-4) {
		b = append(b, m.st.Dim.Render(ln))
	}
	for len(b) < h-5 {
		b = append(b, "")
	}
	lp := m.be.LogPath()
	b = append(b, m.st.Dim.Render(m.t("p.logfile")))
	for _, ln := range wrap(lp, w-6) {
		b = append(b, m.st.Dim.Render("  "+ln))
	}
	return m.box(m.t("p.now"), b, w, h, false)
}

func (m *Model) logBox(w, h int) []string {
	p := &m.prg
	iw := w - 4
	var lines []string
	for _, l := range p.logs {
		src := m.st.Pink.Render(padRight(l.src, 7))
		if l.src == "engine" {
			src = m.st.Accent.Render(padRight(l.src, 7))
		}
		lines = append(lines, m.st.Dim.Render(l.at.Format("15:04:05"))+" "+src+" "+l.text)
	}
	p.vp.SetWidth(iw)
	p.vp.SetHeight(h - 2)
	atBottom := p.vp.AtBottom() || !p.logFocus
	p.vp.SetContentLines(lines)
	if atBottom {
		p.vp.GotoBottom()
	}
	body := strings.Split(p.vp.View(), "\n")
	return m.box(m.t("p.log")+"  ("+m.t("p.log_help")+")", body, w, h, p.logFocus)
}

// ---- modal ----

func (m *Model) progressOverlay(body []string, w int) []string {
	p := &m.prg
	var modal []string
	switch {
	case p.dec != nil:
		modal = m.errorModal(min(w-8, 78))
	case p.confirmQuit:
		modal = m.quitModal(min(w-8, 60))
	default:
		return body
	}
	mw := width(modal[0])
	x0 := (w - mw) / 2
	y0 := max((len(body)-len(modal))/2, 0)
	out := append([]string(nil), body...)
	for i, ml := range modal {
		y := y0 + i
		if y >= len(out) {
			break
		}
		base := padTo(out[y], w)
		out[y] = ansi.Truncate(base, x0, "") + ml + ansi.TruncateLeft(base, x0+mw, "")
	}
	return out
}

func (m *Model) quitModal(w int) []string {
	b := []string{"", m.t("q.text"), "", m.button(m.t("q.abort"), true) + " " + m.button(m.t("q.stay"), false), ""}
	return m.boxStyled(m.t("q.title"), b, w, m.st.Warn)
}

// boxStyled is box with a custom border style.
func (m *Model) boxStyled(title string, body []string, w int, sty lipgloss.Style) []string {
	old := m.st.BorderFocus
	m.st.BorderFocus = sty
	defer func() { m.st.BorderFocus = old }()
	return m.box(title, body, w, 0, true)
}

func hintKey(err string) string {
	e := strings.ToLower(err)
	switch {
	case strings.Contains(e, "timeout"), strings.Contains(e, "lookup"), strings.Contains(e, "no such host"),
		strings.Contains(e, "connection"), strings.Contains(e, "dial tcp"), strings.Contains(e, "could not resolve"),
		strings.Contains(e, "failed retrieving file"):
		return "net"
	case strings.Contains(e, "pgp"), strings.Contains(e, "signature"), strings.Contains(e, "keyring"), strings.Contains(e, "corrupted"):
		return "keys"
	case strings.Contains(e, "no space"), strings.Contains(e, "space left"):
		return "disk"
	case strings.Contains(e, "unable to lock"), strings.Contains(e, "db.lck"):
		return "lock"
	}
	return "generic"
}

func (m *Model) errorModal(w int) []string {
	p := &m.prg
	d := p.dec
	title, mod := d.id, ""
	if i, ok := p.idx[d.id]; ok {
		title = m.txt(p.steps[i].info.Title)
		mod = p.steps[i].info.Module
	}
	iw := w - 4
	var b []string
	b = append(b, "", m.st.Bad.Render(m.g.Cross)+" "+m.st.Text.Bold(true).Render(m.t("e.failed", title)), "")
	b = append(b, wrap(m.t("e.did", title), iw)...)
	hk := hintKey(d.err)
	b = append(b, wrap(m.t("e.what", m.t("e.hint."+hk)), iw)...)
	b = append(b, "")
	tail := d.tail
	if len(tail) > 8 {
		tail = tail[len(tail)-8:]
	}
	if len(tail) == 0 {
		tail = []string{d.err}
	}
	for _, ln := range tail {
		st := m.st.Dim
		if strings.Contains(strings.ToLower(ln), "error") || strings.Contains(ln, "dial tcp") {
			st = m.st.Code
		}
		b = append(b, st.Render(m.trunc(ln, iw)))
	}
	b = append(b, "", m.st.Text.Bold(true).Render(m.t("e.options")))
	b = append(b, m.st.AccentB.Render(m.t("e.retry"))+m.st.Dim.Render(" "+m.g.Sep+" "+m.t("e.retry.d")))
	modName := ""
	if d.optional {
		modName = m.names([]string{mod})
		b = append(b, m.st.AccentB.Render(m.t("e.skip", modName))+m.st.Dim.Render(" "+m.g.Sep+" "+m.t("e.skip.d", modName)))
	}
	b = append(b, m.st.AccentB.Render(m.t("e.abort"))+m.st.Dim.Render(" "+m.g.Sep+" "+m.t("e.abort.d")))
	b = append(b, "")
	var bl []string
	for i, x := range m.decideButtons() {
		lbl := m.t("e.b." + x.String())
		if x == plain.Skip {
			lbl = m.t("e.b.skip", modName)
		}
		bl = append(bl, m.button(lbl, i == p.decBtn))
	}
	b = append(b, strings.Join(bl, " ")+"   "+m.st.Key.Render(" L ")+" "+m.st.Dim.Render(m.t("e.full_log")), "")
	return m.boxStyled(m.t("e.title"), b, w, m.st.Bad)
}
