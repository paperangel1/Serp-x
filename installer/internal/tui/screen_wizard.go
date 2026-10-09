package tui

import (
	"regexp"
	"strings"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/manifest"
)

// plainSecrets are "secret" config keys that are shown while typing (the
// panel address is not a secret value in the mockup, only the token is).
var plainSecrets = map[string]bool{"servers.remnawave_url": true}

// hiddenKeys are asked implicitly (see the ssh block).
var hiddenKeys = map[string]bool{"servers.generate_key": true}

type field struct {
	module    string
	key       string
	kind      string
	label     manifest.Text
	help      manifest.Text
	validate  *regexp.Regexp
	skippable bool
	choices   []string
	in        textinput.Model
	masked    bool
	val       string // choice / bool value
	checked   bool   // "check key" pressed
}

func (f *field) isText() bool { return f.kind == "secret" || f.kind == "text" || f.kind == "path" }

func (f *field) value() string {
	if f.isText() {
		return f.in.Value()
	}
	return f.val
}

// formatOK: "" = nothing to say, "ok", "bad".
func (f *field) formatState() string {
	v := f.value()
	if v == "" || f.validate == nil || !f.isText() {
		return ""
	}
	if f.validate.MatchString(v) {
		return "ok"
	}
	return "bad"
}

type wizPage struct {
	module string
	fields []*field
	ssh    bool
}

type wizState struct {
	pages   []wizPage
	page    int
	focus   int // 0..len(visible fields)-1 = fields, then buttons
	cache   map[string]*field
	skipped map[string]bool
	ssh     *SSHKey
	sshBusy bool
	sshErr  string
	saved   string // path of the saved authorized_keys line
	err     string // validation message of the page
	note    string
}

func (w *wizState) init() {
	w.cache = map[string]*field{}
	w.skipped = map[string]bool{}
}

func (m *Model) targetModules() []string {
	if m.mod.sel == nil {
		return nil
	}
	have := map[string]bool{}
	if m.md.mode == ModeModules && m.be != nil {
		if in := m.be.Installed(); in != nil {
			for _, x := range in.Modules {
				have[x] = true
			}
		}
	}
	var out []string
	for _, id := range m.mod.sel.Modules {
		if !have[id] {
			out = append(out, id)
		}
	}
	return out
}

// rebuild creates the pages of the selected modules, keeping typed values.
func (w *wizState) rebuild(m *Model) {
	w.pages = nil
	if m.set == nil {
		return
	}
	for _, id := range m.targetModules() {
		x, ok := m.set.Get(id)
		if !ok || len(x.Config) == 0 {
			continue
		}
		pg := wizPage{module: id}
		for _, c := range x.Config {
			f := w.cache[c.Key]
			if f == nil {
				f = newField(id, c)
				if c.Key == "core.language" {
					f.val = m.lang
				}
				w.cache[c.Key] = f
			}
			if hiddenKeys[c.Key] {
				continue
			}
			pg.fields = append(pg.fields, f)
		}
		pg.ssh = id == "servers" && w.generateKey(m)
		if len(pg.fields) > 0 {
			w.pages = append(w.pages, pg)
		}
	}
	if w.page >= len(w.pages) {
		w.page = max(len(w.pages)-1, 0)
	}
}

func (w *wizState) generateKey(m *Model) bool {
	f := w.cache["servers.generate_key"]
	return f == nil || f.val != "false"
}

func newField(mod string, c manifest.Config) *field {
	f := &field{module: mod, key: c.Key, kind: c.Kind, label: c.Label, help: c.Help, skippable: c.Skippable, choices: c.Choices}
	if c.Validate != "" {
		f.validate, _ = regexp.Compile(c.Validate)
	}
	def := ""
	switch d := c.Default.(type) {
	case string:
		def = d
	case bool:
		def = boolStr(d)
	}
	if f.isText() {
		f.in = textinput.New()
		f.in.SetVirtualCursor(false)
		f.masked = c.Kind == "secret" && !plainSecrets[c.Key]
		if f.masked {
			f.in.EchoMode = textinput.EchoPassword
		}
		f.in.SetValue(def)
	} else {
		f.val = def
		if c.Kind == "choice" && def == "" && len(c.Choices) > 0 {
			f.val = c.Choices[0]
		}
		if c.Kind == "bool" && def == "" {
			f.val = "false"
		}
	}
	return f
}

// values returns the answers: plain config and secrets (separately).
func (w *wizState) values() (cfg, secrets map[string]string) {
	cfg, secrets = map[string]string{}, map[string]string{}
	for k, f := range w.cache {
		v := f.value()
		if f.kind == "secret" {
			if v != "" && !w.skipped[f.module] {
				secrets[k] = v
			}
			continue
		}
		cfg[k] = v
	}
	if w.skipped["servers"] {
		cfg["servers.generate_key"] = "false"
	}
	return
}

func (p *wizPage) hasSecret() bool {
	for _, f := range p.fields {
		if f.kind == "secret" {
			return true
		}
	}
	return false
}

func (p *wizPage) canSkip() bool {
	for _, f := range p.fields {
		if f.skippable {
			return true
		}
	}
	return false
}

// button ids of a page.
func (m *Model) pageButtons(p *wizPage) []string {
	var b []string
	switch {
	case p.ssh:
		b = append(b, "save")
	case p.hasSecret():
		b = append(b, "check")
	}
	if p.canSkip() {
		b = append(b, "skip")
	}
	return append(b, "next")
}

func (m *Model) curPage() *wizPage {
	if m.wiz.page < 0 || m.wiz.page >= len(m.wiz.pages) {
		return nil
	}
	return &m.wiz.pages[m.wiz.page]
}

func (m *Model) focusCount(p *wizPage) int { return len(p.fields) + len(m.pageButtons(p)) }

// syncFocus blurs all inputs and focuses the one under the cursor.
func (m *Model) syncFocus() {
	p := m.curPage()
	if p == nil {
		return
	}
	for i, f := range p.fields {
		if f.isText() {
			if i == m.wiz.focus {
				f.in.Focus()
			} else {
				f.in.Blur()
			}
		}
	}
}

func (w *wizState) onEnterPage(m *Model) tea.Cmd {
	w.err, w.note = "", ""
	p := m.curPage()
	if p == nil {
		return nil
	}
	m.syncFocus()
	if p.ssh && w.ssh == nil && !w.sshBusy {
		w.sshBusy = true
		be, ctx := m.be, m.ctx
		return func() tea.Msg {
			k, err := be.GenSSHKey(ctx)
			return sshMsg{k, err}
		}
	}
	return nil
}

func (m *Model) onSSH(msg sshMsg) {
	m.wiz.sshBusy = false
	if msg.err != nil {
		m.wiz.sshErr = msg.err.Error()
		return
	}
	k := msg.key
	m.wiz.ssh = &k
	m.wiz.sshErr = ""
}

func (m *Model) onSaved(msg savedMsg) {
	switch msg.what {
	case "authkeys":
		if msg.err != nil {
			m.wiz.note = m.t("w.save_fail", msg.err.Error())
		} else {
			m.wiz.saved = msg.path
			m.wiz.note = m.t("w.saved", msg.path)
		}
	case "setup":
		if msg.err != nil {
			m.sum.note = m.t("w.save_fail", msg.err.Error())
		} else {
			m.sum.exported = msg.path
			m.sum.note = m.t("s.exported", msg.path)
		}
	}
}

func (m *Model) wizardPaste(p tea.PasteMsg) tea.Cmd {
	pg := m.curPage()
	if pg == nil || m.wiz.focus >= len(pg.fields) {
		return nil
	}
	f := pg.fields[m.wiz.focus]
	if f.isText() {
		f.in, _ = f.in.Update(p)
	}
	return nil
}

func (m *Model) wizardKey(k tea.KeyPressMsg) tea.Cmd {
	w := &m.wiz
	p := m.curPage()
	if p == nil {
		m.sumEnter()
		return nil
	}
	key := k.String()
	nf := len(p.fields)
	onField := w.focus < nf
	var f *field
	if onField {
		f = p.fields[w.focus]
	}
	btns := m.pageButtons(p)
	typing := onField && f.isText()

	switch key {
	case "esc":
		m.prevPage()
		return nil
	case "tab", "down":
		w.focus = (w.focus + 1) % m.focusCount(p)
		m.syncFocus()
		return nil
	case "shift+tab", "up":
		w.focus = (w.focus - 1 + m.focusCount(p)) % m.focusCount(p)
		m.syncFocus()
		return nil
	case "ctrl+s":
		return m.pageSkip(p)
	case "enter":
		switch {
		case onField && w.focus < nf-1:
			w.focus++
			m.syncFocus()
		case onField:
			w.focus = nf + len(btns) - 1 // the "next" button
			return m.pageNext(p)
		default:
			return m.pressButton(p, btns[w.focus-nf])
		}
		return nil
	}
	if onField {
		switch f.kind {
		case "bool":
			if key == "space" || key == " " || key == "left" || key == "right" {
				f.val = boolStr(f.val != "true")
				return m.afterToggle(f)
			}
			return nil
		case "choice":
			i := indexOf(f.choices, f.val)
			switch key {
			case "left":
				i--
			case "right", "space", " ":
				i++
			default:
				return nil
			}
			if len(f.choices) > 0 {
				f.val = f.choices[(i+len(f.choices))%len(f.choices)]
			}
			return nil
		}
		if typing {
			f.checked = false
			w.err = ""
			f.in, _ = f.in.Update(k)
		}
		return nil
	}
	// buttons
	bi := w.focus - nf
	switch strings.ToLower(key) {
	case "left":
		if bi > 0 {
			w.focus--
		}
	case "right":
		if bi < len(btns)-1 {
			w.focus++
		}
	case "s":
		if contains(btns, "skip") {
			return m.pageSkip(p)
		}
	case "c":
		if contains(btns, "save") {
			return m.pressButton(p, "save")
		}
		if contains(btns, "check") {
			return m.pressButton(p, "check")
		}
	case "q":
		return m.quitNow(ActionExit)
	}
	return nil
}

func (m *Model) afterToggle(f *field) tea.Cmd {
	if f.key == "servers.generate_key" {
		m.wiz.rebuild(m)
	}
	return nil
}

func (m *Model) pressButton(p *wizPage, id string) tea.Cmd {
	switch id {
	case "next":
		return m.pageNext(p)
	case "skip":
		return m.pageSkip(p)
	case "check":
		for _, f := range p.fields {
			if f.kind == "secret" {
				f.checked = true
			}
		}
	case "save":
		if m.wiz.ssh == nil {
			return nil
		}
		be, line := m.be, m.wiz.ssh.Line
		return func() tea.Msg {
			path, err := be.SaveAuthorizedKeys(line)
			return savedMsg{what: "authkeys", path: path, err: err}
		}
	}
	return nil
}

func (m *Model) pageNext(p *wizPage) tea.Cmd {
	for _, f := range p.fields {
		if f.formatState() == "bad" {
			m.wiz.err = m.t("w.bad_format", m.txt(f.label))
			m.wiz.focus = indexField(p, f)
			m.syncFocus()
			return nil
		}
		if f.kind == "path" && strings.TrimSpace(f.in.Value()) == "" {
			m.wiz.err = m.t("w.need_value", m.txt(f.label))
			m.wiz.focus = indexField(p, f)
			m.syncFocus()
			return nil
		}
	}
	delete(m.wiz.skipped, p.module)
	m.nextPage()
	return m.wiz.onEnterPage(m)
}

func indexField(p *wizPage, f *field) int {
	for i, x := range p.fields {
		if x == f {
			return i
		}
	}
	return 0
}

func (m *Model) pageSkip(p *wizPage) tea.Cmd {
	for _, f := range p.fields {
		if f.kind == "secret" {
			f.in.SetValue("")
		}
	}
	m.wiz.skipped[p.module] = true
	m.nextPage()
	return m.wiz.onEnterPage(m)
}

func (m *Model) nextPage() {
	w := &m.wiz
	if w.page+1 < len(w.pages) {
		w.page++
		w.focus = 0
		return
	}
	m.sumEnter()
}

func (m *Model) prevPage() {
	w := &m.wiz
	if w.page > 0 {
		w.page--
		w.focus = 0
		m.syncFocus()
		return
	}
	m.back()
}

func (m *Model) wizardFooter() string {
	p := m.curPage()
	skip := "s"
	if p != nil && m.wiz.focus < len(p.fields) && p.fields[m.wiz.focus].isText() {
		skip = "Ctrl+S"
	}
	if p != nil && p.ssh {
		return m.hints("Tab", m.t("f.field"), "c", m.t("f.save_line"), "Enter", m.t("f.next"), skip, m.t("f.skip"), "Esc", m.t("f.back"))
	}
	return m.hints("Tab", m.t("f.field"), "Enter", m.t("f.next"), skip, m.t("f.skip"), "Esc", m.t("f.back"), "F2", m.t("f.lang"))
}

// ---- view ----

func (m *Model) fieldRow(f *field, focused bool, iw, lblW int) []string {
	lbl := m.txt(f.label)
	lblSt := m.st.Dim
	if focused {
		lblSt = m.st.AccentB
	}
	switch f.kind {
	case "bool":
		mark := m.g.BoxOff
		if f.val == "true" {
			mark = m.g.Box
		}
		row := mark + " " + lbl
		if focused {
			return []string{m.st.Accent.Render(row)}
		}
		return []string{row}
	case "choice":
		var opts []string
		for _, c := range f.choices {
			name := m.t("ch." + c)
			if c == f.val {
				opts = append(opts, m.st.Accent.Render(m.g.Radio)+" "+m.st.Text.Bold(true).Render(name))
			} else {
				opts = append(opts, m.st.Dim.Render(m.g.RadioOff+" "+name))
			}
		}
		return []string{lblSt.Render(lbl), "  " + strings.Join(opts, "   ")}
	}
	val := f.in.Value()
	var shown string
	if f.masked {
		n := len([]rune(val))
		shown = strings.Repeat(m.g.Mask, min(n, iw-width(lbl)-8))
	} else {
		shown = val
		if r := []rune(shown); len(r) > iw-width(lbl)-8 {
			shown = m.ell() + string(r[len(r)-(iw-width(lbl)-9):])
		}
	}
	if focused {
		shown += m.st.Accent.Render(m.g.Cursor)
	} else if val == "" {
		shown = m.st.Dim.Render(m.t("w.empty"))
	}
	return []string{lblSt.Render(padRight(lbl, lblW)) + shown}
}

func (m *Model) fieldHint(f *field) string {
	switch f.formatState() {
	case "ok":
		if f.checked {
			return m.st.OK.Render(m.g.Check+" "+m.t("w.fmt_ok")) + "  " + m.st.Dim.Render(m.t("w.check_later"))
		}
		return m.st.OK.Render(m.g.Check + " " + m.t("w.fmt_ok"))
	case "bad":
		return m.st.Bad.Render(m.g.Cross + " " + m.t("w.fmt_bad"))
	}
	return ""
}

func (m *Model) wizardView(w, h int) []string {
	p := m.curPage()
	if p == nil {
		return nil
	}
	pg := m.wiz
	x, _ := m.set.Get(p.module)
	head := m.st.Dim.Render(m.t("w.step", pg.page+1, len(pg.pages)))
	var dots []string
	for i := range pg.pages {
		if i <= pg.page {
			dots = append(dots, m.st.Accent.Render(m.g.Full))
		} else {
			dots = append(dots, m.st.Dim.Render(m.g.Empty))
		}
	}
	dd := strings.Join(dots, " ")
	out := []string{head + strings.Repeat(" ", max(w-width(head)-width(dd), 1)) + dd}
	out = append(out, m.st.Text.Bold(true).Render(m.t("w.title."+p.module)))
	out = append(out, "")
	intro := m.t("w.intro." + p.module)
	for _, ln := range wrap(intro, w-2) {
		out = append(out, ln)
	}
	out = append(out, "")

	fw := w
	var side []string
	if p.hasSecret() && !p.ssh {
		fw = w - 34
		side = m.box(m.t("w.safety"), append([]string{""}, wrap(m.t("w.safety.text"), 26)...), 32, 10, false)
	}
	var fb []string
	if !p.ssh {
		fb = append(fb, "")
	}
	lblW := 0
	for _, f := range p.fields {
		if f.isText() {
			lblW = max(lblW, width(m.txt(f.label)))
		}
	}
	lblW = min(lblW+2, fw/2)
	for i, f := range p.fields {
		fb = append(fb, m.fieldRow(f, pg.focus == i, fw-4, lblW)...)
		if hnt := m.fieldHint(f); hnt != "" {
			fb = append(fb, "  "+hnt)
		}
		if f.kind == "secret" && f.in.Value() == "" && !m.wiz.skipped[p.module] {
			if h := m.txt(f.help); h != "" && pg.focus == i {
				for _, ln := range wrap(h, fw-8) {
					fb = append(fb, m.st.Dim.Render("  "+ln))
				}
			}
		}
	}
	if !p.ssh {
		fb = append(fb, "")
	}
	box := m.box(m.txt(x.Name), fb, fw, 0, false)
	if side != nil {
		out = append(out, cols(box, fw, side, 32, 2)...)
	} else {
		out = append(out, box...)
	}
	if p.ssh {
		out = append(out, m.sshBlock(w)...)
	}
	out = append(out, "")
	if pg.err != "" {
		out = append(out, m.st.Bad.Render(m.g.Cross+" "+pg.err))
	} else if pg.note != "" {
		out = append(out, m.st.OK.Render(m.g.Check+" "+pg.note))
	}
	var bl []string
	for i, b := range m.pageButtons(p) {
		label := m.t("b." + b)
		if b == "save" {
			label = m.t("b.save", m.t("w.auth_path"))
		}
		if b == "check" {
			label = m.t("b.check")
		}
		if b == "next" {
			label += " " + m.g.Arrow
		}
		bl = append(bl, m.button(label, pg.focus == len(p.fields)+i))
	}
	out = append(out, strings.Join(bl, " "))
	return out
}

// exactAuthLine is the line the user adds on every server.
func (m *Model) sshBlock(w int) []string {
	pg := &m.wiz
	var b []string
	switch {
	case pg.sshBusy:
		b = append(b, m.st.Dim.Render(m.spinner()+" "+m.t("w.ssh_gen")))
	case pg.sshErr != "":
		b = append(b, m.st.Bad.Render(m.g.Cross+" "+m.t("w.ssh_fail", pg.sshErr)))
	case pg.ssh != nil:
		k := pg.ssh
		b = append(b, m.st.OK.Render(m.g.Check)+" "+m.t("w.ssh_ok", k.Path)+"  "+m.st.Dim.Render(k.Fingerprint))
		b = append(b, m.t("w.ssh_add"))
		for _, ln := range wrap(k.Line, w-8) {
			b = append(b, m.st.Code.Render(ln))
		}
		b = append(b, m.t("w.ssh_allow"), m.st.Dim.Render("status · diag-disk · diag-load · diag-logs · diag-net · diag-ports · diag-security"),
			m.st.Dim.Render("act-restart-node · act-update-container · act-docker-prune · act-reboot"), m.st.Dim.Render(m.t("w.ssh_easy")))
	}
	return m.box(m.t("w.ssh_title"), b, w, 0, false)
}
