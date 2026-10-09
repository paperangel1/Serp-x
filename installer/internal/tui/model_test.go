package tui

import (
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/plain"
	"serpx/installer/internal/preflight"
)

const (
	fakeGemini = "AIzaFAKE0000000000000000000000000000"
	fakeToken  = "FAKE-TOKEN-SECRET-0000"
	fakeSub    = "https://sub.example.com/FAKE-SUB-SECRET-0000"
)

func TestFlowFreshGoesStraightToModules(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	m := newModel(t, be, "ru", GlyphUnicode)
	boot(m)
	key(m, "enter")
	if m.screen != ScrModules {
		t.Fatalf("screen = %v", m.screen)
	}
	if m.mod.preset != "full" || !m.mod.sel.Has("nvidia") {
		t.Fatalf("preset %q, nvidia %v", m.mod.preset, m.mod.sel.Has("nvidia"))
	}
}

func TestBlockedPreflightStops(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	be.Report.Checks = append(be.Report.Checks, preflight.Check{ID: preflight.CheckRoot, Status: preflight.Fail, Code: "root.root"})
	m := newModel(t, be, "en", GlyphUnicode)
	boot(m)
	key(m, "enter")
	if m.screen != ScrCheck {
		t.Fatalf("must stay on the check screen, got %v", m.screen)
	}
	if !strings.Contains(screenText(m), "cannot continue") {
		t.Fatal("verdict missing")
	}
}

func TestModeOptions(t *testing.T) {
	be := newFake(t, preflight.InstallSerpX)
	be.Report.Facts.NeedsResume = true
	m := newModel(t, be, "ru", GlyphUnicode)
	boot(m)
	want := []string{optResume, optRepair, optModules, optUninstall, optReinstall}
	if strings.Join(m.md.opts, ",") != strings.Join(want, ",") {
		t.Fatalf("opts = %v", m.md.opts)
	}
	key(m, "enter") // continue the interrupted run
	key(m, "enter")
	if m.screen != ScrModules || !m.md.resume {
		t.Fatalf("screen %v resume %v", m.screen, m.md.resume)
	}
}

func TestRepairAndUninstallRequests(t *testing.T) {
	be := newFake(t, preflight.InstallSerpX)
	m := newModel(t, be, "ru", GlyphUnicode)
	boot(m)
	key(m, "enter", "enter") // check -> mode -> repair
	if m.screen != ScrSummary || m.request().Mode != ModeRepair || m.sum.plan == nil {
		t.Fatalf("repair: screen %v req %+v plan %v", m.screen, m.request().Mode, m.sum.plan)
	}
	key(m, "esc", "down", "down", "enter") // uninstall
	if m.request().Mode != ModeUninstall {
		t.Fatalf("mode = %s", m.request().Mode)
	}
	key(m, "d")
	if !m.request().RemoveData {
		t.Fatal("d must tick 'remove my data'")
	}
}

func TestModulesModeStartsFromInstalled(t *testing.T) {
	be := newFake(t, preflight.InstallSerpX)
	m := newModel(t, be, "ru", GlyphUnicode)
	boot(m)
	key(m, "enter", "down", "enter") // modules
	if m.screen != ScrModules || m.mod.preset != "custom" {
		t.Fatalf("screen %v preset %s", m.screen, m.mod.preset)
	}
	if m.mod.sel.Has("vpn") || !m.mod.sel.Has("commands-media") {
		t.Fatal("selection must be the installed one")
	}
	// only modules added since need questions: vpn is not selected and nothing
	// new was ticked, so the wizard is skipped
	key(m, "enter")
	if m.screen != ScrSummary {
		t.Fatalf("screen = %v", m.screen)
	}
}

func TestCascadeAndCoreLock(t *testing.T) {
	m, _ := toModules(t, variant{"en", GlyphUnicode})
	key(m, "1") // full
	// core cannot be removed
	m.mod.cur = m.mod.firstRow()
	key(m, "space")
	if !m.mod.sel.Has("core") || !strings.Contains(m.mod.notice, "required") {
		t.Fatalf("core: %q", m.mod.notice)
	}
	// Commands -> asks about commands-media
	for m.mod.rows[m.mod.cur].id != "commands" {
		key(m, "down")
	}
	key(m, "space")
	if m.mod.cascade == nil || !m.mod.sel.Has("commands") {
		t.Fatal("cascade prompt expected, nothing removed yet")
	}
	key(m, "esc")
	if m.mod.cascade != nil || !m.mod.sel.Has("commands") {
		t.Fatal("cancel must keep both")
	}
	key(m, "space", "enter")
	if m.mod.sel.Has("commands") || m.mod.sel.Has("commands-media") {
		t.Fatal("both must go")
	}
	if m.mod.preset != "custom" {
		t.Fatalf("preset = %s", m.mod.preset)
	}
}

func TestAutoDependencyNotice(t *testing.T) {
	m, _ := toModules(t, variant{"ru", GlyphUnicode})
	key(m, "2") // minimal
	for m.mod.rows[m.mod.cur].id != "commands-media" {
		key(m, "down")
	}
	key(m, "space")
	if !m.mod.sel.Has("commands") || !strings.Contains(m.mod.notice, "Commands") {
		t.Fatalf("auto: %v %q", m.mod.sel.Modules, m.mod.notice)
	}
	if len(m.mod.sel.Auto["commands"]) == 0 {
		t.Fatal("commands must be marked auto")
	}
}

func TestLanguageSwitchF2(t *testing.T) {
	m, _ := toModules(t, variant{"ru", GlyphUnicode})
	ru := screenText(m)
	key(m, "f2")
	en := screenText(m)
	if ru == en || !strings.Contains(en, "Modules") || !strings.Contains(ru, "Модули") {
		t.Fatal("F2 must switch the whole screen")
	}
	key(m, "f2")
	if screenText(m) != ru {
		t.Fatal("second F2 must come back")
	}
}

func TestWizardMasksSecretsAndValidates(t *testing.T) {
	m, _ := toWizard(t, variant{"en", GlyphUnicode})
	gotoPage(t, m, "ai-gemini")
	typeText(m, "not-a-key")
	if !strings.Contains(screenText(m), "format looks wrong") {
		t.Fatal("bad format must be flagged")
	}
	key(m, "enter", "enter") // to proxy, then try to go on
	if p := m.curPage(); p.module != "ai-gemini" || m.wiz.err == "" {
		t.Fatalf("must block on a bad format (page %s, err %q)", p.module, m.wiz.err)
	}
	// fix it
	m.wiz.focus = 0
	m.syncFocus()
	for range "not-a-key" {
		key(m, "backspace2")
	}
	f := m.wiz.cache["ai.gemini_key"]
	f.in.SetValue("")
	typeText(m, fakeGemini)
	out := screenText(m)
	if strings.Contains(out, fakeGemini) || strings.Contains(out, "AIzaFAKE") {
		t.Fatal("secret leaked into the screen")
	}
	if !strings.Contains(out, "••••") {
		t.Fatal("mask expected")
	}
	_, secrets := m.wiz.values()
	if secrets["ai.gemini_key"] != fakeGemini {
		t.Fatal("value must reach the request")
	}
}

func TestWizardSkipDropsSecrets(t *testing.T) {
	m, be := toWizard(t, variant{"en", GlyphUnicode})
	gotoPage(t, m, "ai-gemini")
	typeText(m, fakeGemini)
	key(m, "ctrl+s")
	_, secrets := m.wiz.values()
	if _, ok := secrets["ai.gemini_key"]; ok {
		t.Fatal("a skipped page must not send its secret")
	}
	_ = be
	for m.screen != ScrSummary {
		if p := m.curPage(); p != nil && p.canSkip() {
			key(m, "ctrl+s")
		} else {
			key(m, "enter")
		}
	}
	if !strings.Contains(screenText(m), "Set up later") {
		t.Fatal("summary must list what is left")
	}
}

func TestSSHStepAndSaveLine(t *testing.T) {
	m, be := toWizard(t, variant{"en", GlyphUnicode})
	gotoPage(t, m, "servers")
	if m.wiz.ssh == nil {
		t.Fatal("the key must be generated on entering the page")
	}
	out := screenText(m)
	if !strings.Contains(out, `restrict,command="/usr/local/sbin/serp-run" ssh-ed25519`) || !strings.Contains(out, "serpantinum") {
		t.Fatalf("exact line missing:\n%s", out)
	}
	// go to the button row and save
	for i := 0; i < 4; i++ {
		key(m, "tab")
	}
	key(m, "c")
	if be.Saved["authkeys"] != m.wiz.ssh.Line {
		t.Fatal("the exact line must be saved")
	}
}

func TestBackNavigation(t *testing.T) {
	m, _ := toWizard(t, variant{"ru", GlyphUnicode})
	key(m, "enter") // page 2
	if m.wiz.page != 1 {
		t.Fatalf("page = %d", m.wiz.page)
	}
	key(m, "esc")
	if m.wiz.page != 0 {
		t.Fatalf("page = %d", m.wiz.page)
	}
	key(m, "esc")
	if m.screen != ScrModules {
		t.Fatalf("screen = %v", m.screen)
	}
	key(m, "esc")
	if m.screen != ScrCheck {
		t.Fatalf("screen = %v", m.screen)
	}
}

func TestProgressDecisions(t *testing.T) {
	m := progressModel(t, variant{"en", GlyphUnicode}, false)
	be := m.be.(*FakeBackend)
	_ = be
	feedEvents(m, evFail{"vpn.install", "dial tcp: i/o timeout"}, evDecide{"vpn.install", "dial tcp: i/o timeout", true, nil})
	if m.prg.dec == nil {
		t.Fatal("modal expected")
	}
	if got := m.decideButtons(); len(got) != 3 || got[1] != plain.Skip {
		t.Fatalf("buttons = %v", got)
	}
	key(m, "s")
	if m.prg.dec != nil {
		t.Fatal("decision must close the modal")
	}
	select {
	case d := <-m.prg.sess.dec:
		if d != plain.Skip {
			t.Fatalf("decision = %v", d)
		}
	default:
		t.Fatal("decision was not sent")
	}
	// a core step cannot be skipped
	feedEvents(m, evDecide{"core.packages", "boom", false, nil})
	if got := m.decideButtons(); len(got) != 2 {
		t.Fatalf("core: buttons = %v", got)
	}
	key(m, "s") // ignored
	if m.prg.dec == nil {
		t.Fatal("skip must not work for a required module")
	}
	key(m, "a")
	if d := <-m.prg.sess.dec; d != plain.Abort {
		t.Fatalf("decision = %v", d)
	}
}

func TestPauseAndQuitConfirm(t *testing.T) {
	m := progressModel(t, variant{"en", GlyphUnicode}, false)
	key(m, "p")
	if !m.prg.paused || m.prg.sess.pauseCh == nil {
		t.Fatal("pause expected")
	}
	key(m, "p")
	if m.prg.paused || m.prg.sess.pauseCh != nil {
		t.Fatal("resume expected")
	}
	key(m, "q")
	if !m.prg.confirmQuit || !strings.Contains(screenText(m), "Abort?") {
		t.Fatal("quit must ask first")
	}
	key(m, "n")
	if m.prg.confirmQuit {
		t.Fatal("n must dismiss")
	}
	key(m, "q", "y")
	if !m.prg.aborting || m.prg.sess.ctx.Err() == nil {
		t.Fatal("y must cancel the run")
	}
}

func TestFinishActions(t *testing.T) {
	m := progressModel(t, variant{"en", GlyphUnicode}, false)
	feedEvents(m, evRunEnd{})
	if m.screen != ScrFinish || !m.fin.ok {
		t.Fatalf("screen %v ok %v", m.screen, m.fin.ok)
	}
	if m.fin.btns[0] != ActionReboot { // nvidia is in the full preset
		t.Fatalf("buttons = %v", m.fin.btns)
	}
	key(m, "right", "enter")
	if m.result.Action != ActionHyprland || !m.quit {
		t.Fatalf("result = %+v", m.result)
	}
}

func TestFailedRunFinish(t *testing.T) {
	m := progressModel(t, variant{"ru", GlyphUnicode}, false)
	feedEvents(m, evRunEnd{err: errTest})
	if m.fin.ok || len(m.fin.btns) != 1 || m.result.OK {
		t.Fatalf("fin = %+v", m.fin)
	}
	if !strings.Contains(screenText(m), "serp-installer install --resume") {
		t.Fatal("resume hint missing")
	}
}

func TestHintKey(t *testing.T) {
	cases := map[string]string{
		"dial tcp: lookup x: i/o timeout": "net", "invalid or corrupted package (PGP signature)": "keys",
		"No space left on device": "disk", "unable to lock database": "lock", "boom": "generic",
	}
	for in, want := range cases {
		if got := hintKey(in); got != want {
			t.Errorf("%q: %s, want %s", in, got, want)
		}
	}
}

func TestVTPalette(t *testing.T) {
	var b strings.Builder
	ApplyVTPalette(&b)
	if !strings.HasPrefix(b.String(), "\x1b]P00f0d14") || strings.Count(b.String(), "\x1b]P") != 16 {
		t.Fatalf("palette = %q", b.String())
	}
}

func TestSmallTerminalDoesNotPanic(t *testing.T) {
	m, _ := toModules(t, variant{"ru", GlyphNerd})
	for _, sz := range [][2]int{{60, 20}, {80, 24}, {120, 40}, {40, 10}} {
		m.w, m.h = sz[0], sz[1]
		for _, s := range []Screen{ScrCheck, ScrModules, ScrSummary, ScrFinish} {
			m.screen = s
			_ = m.render()
		}
	}
}

type testErr string

func (e testErr) Error() string { return string(e) }

var errTest = testErr("boom")

func TestScreenTransitionSettles(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	m := New(Config{Backend: be, Version: "x", Lang: "en", Glyphs: GlyphUnicode, Now: func() time.Time { return t0 }, NoTick: true})
	boot(m)
	key(m, "enter")
	if m.slide != 1 {
		t.Fatalf("the transition must start at 1, got %v", m.slide)
	}
	first := screenText(m)
	if !strings.HasPrefix(strings.Split(first, "\n")[4], strings.Repeat(" ", 8)) {
		t.Fatal("content must start shifted")
	}
	prev := m.slide
	for i := 0; i < 40 && m.slide > 0; i++ {
		send(m, tickMsg(t0.Add(time.Duration(i)*100*time.Millisecond)))
		if m.slide > 1.01 {
			t.Fatalf("overshoot beyond the start: %v", m.slide)
		}
		prev = m.slide
	}
	if m.slide != 0 {
		t.Fatalf("transition did not settle (last %v)", prev)
	}
	if strings.HasPrefix(strings.Split(screenText(m), "\n")[4], "        ") {
		t.Fatal("settled content must not be shifted")
	}
}

func TestStartModeSkipsTheChoice(t *testing.T) {
	be := newFake(t, preflight.InstallSerpX)
	m := New(Config{Backend: be, Version: "x", Lang: "en", Glyphs: GlyphUnicode, Now: func() time.Time { return t0 }, NoTick: true, NoAnimation: true, Mode: ModeModules})
	boot(m)
	key(m, "enter")
	if m.screen != ScrModules || m.md.mode != ModeModules {
		t.Fatalf("screen %v mode %s", m.screen, m.md.mode)
	}
}
