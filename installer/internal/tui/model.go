package tui

import (
	"context"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/harmonica"
	"github.com/charmbracelet/x/ansi"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/preflight"
	"serpx/installer/internal/resolve"
)

// Screen is one of the installer screens.
type Screen int

const (
	ScrCheck    Screen = iota // I1
	ScrMode                   // I2
	ScrModules                // I3
	ScrWizard                 // I4, I5
	ScrSummary                // I6
	ScrProgress               // I7, I8, I9
	ScrFinish                 // I10
)

// Config of the TUI.
type Config struct {
	Backend Backend
	Version string // installer version shown in the header
	Lang    string // ru | en
	Glyphs  string // nerd | unicode | ascii
	// Sixteen selects the 16-colour palette (Linux console).
	Sixteen bool
	// Now is the clock (tests inject a fixed one). Ticks carry their own time.
	Now     func() time.Time
	Context context.Context
	Width   int
	Height  int
	// NoAnimation disables screen transitions (VT, tests).
	NoAnimation bool
	// NoTick stops the animation clock (tests drive time themselves).
	NoTick bool
	// Initial answers from flags.
	Preset  string
	Modules []string
	// Mode starts a specific flow (modules, repair, uninstall, install); "" = ask.
	Mode    string
	Restore string
	Resume  bool
}

// Model is the root bubbletea model.
type Model struct {
	cfg Config
	be  Backend
	set *manifest.Set
	res *resolve.Resolver
	ctx context.Context

	w, h    int
	lang    string
	g       Glyphs
	st      Styles
	now     time.Time
	frame   int
	screen  Screen
	hist    []Screen
	slide   float64
	slideV  float64
	spring  harmonica.Spring
	animate bool

	chk chkState
	md  modeState
	mod modState
	wiz wizState
	sum sumState
	prg prgState
	fin finState

	result Result
	quit   bool
	pend   []tea.Cmd
}

// New returns the model; call Init through bubbletea.
func New(cfg Config) *Model {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Context == nil {
		cfg.Context = context.Background()
	}
	if cfg.Lang != "en" {
		cfg.Lang = "ru"
	}
	if cfg.Width == 0 {
		cfg.Width = 100
	}
	if cfg.Height == 0 {
		cfg.Height = 32
	}
	m := &Model{cfg: cfg, be: cfg.Backend, ctx: cfg.Context, w: cfg.Width, h: cfg.Height, lang: cfg.Lang}
	m.g = GlyphsFor(cfg.Glyphs)
	m.st = NewStyles(cfg.Sixteen)
	m.now = cfg.Now()
	m.spring = harmonica.NewSpring(harmonica.FPS(10), 7.0, 0.9)
	m.animate = !cfg.NoAnimation && m.g.Mode != GlyphASCII
	if m.be != nil {
		m.set = m.be.Set()
		if m.set != nil {
			m.res = resolve.New(m.set)
		}
	}
	m.mod.preset = cfg.Preset
	m.mod.explicit = append([]string(nil), cfg.Modules...)
	m.md.resume = cfg.Resume
	m.wiz.init()
	return m
}

// Result is valid after the program quit.
func (m *Model) Result() Result { return m.result }

// ---- messages ----

type tickMsg time.Time
type checkDoneMsg struct{ report preflight.Report }
type planMsg struct {
	seq  int
	plan PlanInfo
	err  error
}
type sshMsg struct {
	key SSHKey
	err error
}
type savedMsg struct {
	what, path string
	err        error
}

func tick() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

// Init starts the preflight and the animation clock.
func (m *Model) Init() tea.Cmd {
	if m.cfg.NoTick {
		return m.checkCmd()
	}
	return tea.Batch(tick(), m.checkCmd())
}

func (m *Model) checkCmd() tea.Cmd {
	be, ctx := m.be, m.ctx
	return func() tea.Msg { return checkDoneMsg{be.Preflight(ctx)} }
}

// t translates a UI string.
func (m *Model) t(key string, a ...any) string { return tr(m.lang, key, a...) }

// txt picks the manifest text in the current language.
func (m *Model) txt(t manifest.Text) string { return t.Get(m.lang) }

// ---- navigation ----

func (m *Model) go2(s Screen) {
	if m.screen != s {
		m.hist = append(m.hist, m.screen)
		m.setScreen(s)
	}
}

func (m *Model) setScreen(s Screen) {
	m.screen = s
	if m.animate {
		m.slide, m.slideV = 1, 0
	}
}

func (m *Model) back() {
	if n := len(m.hist); n > 0 {
		s := m.hist[n-1]
		m.hist = m.hist[:n-1]
		m.setScreen(s)
	}
}

func (m *Model) stage() int {
	switch m.screen {
	case ScrCheck:
		return 0
	case ScrMode:
		return 1
	case ScrModules:
		return 2
	case ScrWizard:
		return 3
	case ScrSummary:
		return 4
	case ScrProgress:
		return 5
	}
	return 6
}

// ---- update ----

// Update is the bubbletea update function.
func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	cmd := m.update(msg)
	if len(m.pend) > 0 {
		cmd = tea.Batch(append([]tea.Cmd{cmd}, m.pend...)...)
		m.pend = nil
	}
	return m, cmd
}

func (m *Model) update(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
	case tickMsg:
		return m.onTick(time.Time(msg))
	case checkDoneMsg:
		m.onCheck(msg)
	case planMsg:
		m.onPlan(msg)
	case sshMsg:
		m.onSSH(msg)
	case savedMsg:
		m.onSaved(msg)
	case sessMsg:
		return m.onSession(msg)
	case tea.PasteMsg:
		return m.onPaste(msg)
	case tea.KeyPressMsg:
		return m.onKey(msg)
	}
	return nil
}

func (m *Model) onTick(t time.Time) tea.Cmd {
	m.now = t
	m.frame++
	if m.slide > 0 {
		m.slide, m.slideV = m.spring.Update(m.slide, m.slideV, 0)
		if m.slide < 0.03 {
			m.slide, m.slideV = 0, 0
		}
	}
	m.progTick()
	if m.cfg.NoTick {
		return nil
	}
	return tick()
}

func (m *Model) onKey(k tea.KeyPressMsg) tea.Cmd {
	key := k.String()
	switch key {
	case "ctrl+c":
		if m.screen == ScrProgress && !m.prg.done {
			m.prg.confirmQuit = true
			return nil
		}
		return m.quitNow(ActionExit)
	case "f2":
		if m.lang == "ru" {
			m.lang = "en"
		} else {
			m.lang = "ru"
		}
		return nil
	}
	switch m.screen {
	case ScrCheck:
		return m.checkKey(k)
	case ScrMode:
		return m.modeKey(k)
	case ScrModules:
		return m.modulesKey(k)
	case ScrWizard:
		return m.wizardKey(k)
	case ScrSummary:
		return m.summaryKey(k)
	case ScrProgress:
		return m.progressKey(k)
	case ScrFinish:
		return m.finishKey(k)
	}
	return nil
}

func (m *Model) onPaste(p tea.PasteMsg) tea.Cmd {
	if m.screen == ScrWizard {
		return m.wizardPaste(p)
	}
	return nil
}

func (m *Model) quitNow(action string) tea.Cmd {
	m.quit = true
	m.result.Action = action
	if m.prg.cancel != nil {
		m.prg.cancel()
	}
	return tea.Quit
}

// ---- view ----

// View renders the current screen.
func (m *Model) View() tea.View {
	v := tea.NewView(m.render())
	v.AltScreen = true
	v.WindowTitle = "serp-x"
	return v
}

// render returns the whole frame as text with ANSI styles.
func (m *Model) render() string {
	return strings.Join(m.frameLines(), "\n")
}

func (m *Model) frameLines() []string {
	w, h := max(m.w, 60), max(m.h, 20)
	ch := h - 5
	var body []string
	var foot string
	switch m.screen {
	case ScrCheck:
		body, foot = m.checkView(w, ch), m.checkFooter()
	case ScrMode:
		body, foot = m.modeView(w, ch), m.modeFooter()
	case ScrModules:
		body, foot = m.modulesView(w, ch), m.modulesFooter()
	case ScrWizard:
		body, foot = m.wizardView(w, ch), m.wizardFooter()
	case ScrSummary:
		body, foot = m.summaryView(w, ch), m.summaryFooter()
	case ScrProgress:
		body, foot = m.progressView(w, ch), m.progressFooter()
	case ScrFinish:
		body, foot = m.finishView(w, ch), m.finishFooter()
	}
	body = vfit(body, ch)
	if m.screen == ScrProgress {
		body = m.progressOverlay(body, w)
	}
	if m.slide > 0 {
		off := int(m.slide * 8)
		for i, ln := range body {
			body[i] = strings.Repeat(" ", off) + ansi.Truncate(ln, w-off, "")
		}
	}
	out := []string{m.header(w), "", m.stepper(w), ""}
	out = append(out, body...)
	out = append(out, foot)
	for i, ln := range out {
		if m.g.Mode == GlyphASCII {
			ln = asciiOnly.Replace(ln)
		}
		out[i] = padTo(ln, w)
	}
	return out
}

// asciiOnly maps the few non-CP437 symbols to what the Linux console font has.
var asciiOnly = strings.NewReplacer("≈", "~", "·", "-", "—", "-", "…", "~", "→", "->", "←", "<-", "↑↓", "^v", "▏", "_", "↻", "~", "◆", "*")

func (m *Model) header(w int) string {
	left := m.st.Accent.Render(m.g.Diamond) + " " + m.st.Text.Bold(true).Render("Serpantinum") +
		m.st.Dim.Render(" "+m.g.Bullet+" "+m.t("hdr.build")+"   "+m.t("hdr.installer")+" v"+m.cfg.Version)
	ru, en := " RU ", " EN "
	var lg string
	if m.lang == "ru" {
		lg = m.st.Pill.Render(ru) + m.st.Dim.Render(en)
	} else {
		lg = m.st.Dim.Render(ru) + m.st.Pill.Render(en)
	}
	right := m.st.Dim.Render(m.t("hdr.lang")+" ") + lg + m.st.Dim.Render("  F2")
	gap := w - width(left) - width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

func (m *Model) stepper(w int) string {
	names := []string{"st.check", "st.mode", "st.modules", "st.settings", "st.summary", "st.install", "st.done"}
	cur := m.stage()
	var parts []string
	for i, k := range names {
		name := m.t(k)
		switch {
		case i < cur:
			parts = append(parts, m.st.OK.Render(m.g.Check)+" "+m.st.Dim.Render(name))
		case i == cur:
			parts = append(parts, m.st.Accent.Render(m.g.Full)+m.pill(name))
		default:
			parts = append(parts, m.st.Dim.Render(m.g.Empty+" "+name))
		}
	}
	sep := m.st.Dim.Render(" " + m.g.Sep + m.g.Sep + " ")
	return m.trunc(strings.Join(parts, sep), w)
}
