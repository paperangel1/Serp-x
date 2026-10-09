package tui

import (
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"serpx/installer/internal/plain"
	"serpx/installer/internal/preflight"
)

// probe wraps the model and records every frame the program renders.
type probe struct {
	*Model
	mu     *sync.Mutex
	frames *[]string
}

func (p probe) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	_, cmd := p.Model.Update(msg)
	return p, cmd
}

func (p probe) View() tea.View {
	v := p.Model.View()
	p.mu.Lock()
	*p.frames = append(*p.frames, ansi.Strip(v.Content))
	p.mu.Unlock()
	return v
}

func (p probe) last() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(*p.frames) == 0 {
		return ""
	}
	return (*p.frames)[len(*p.frames)-1]
}

func (p probe) all() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), (*p.frames)...)
}

func (p probe) waitFor(t *testing.T, what string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(p.last(), what) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %q; last frame:\n%s", what, p.last())
}

func startProgram(t *testing.T, be Backend, lang string) (*teatest.TestModel, probe) {
	t.Helper()
	m := New(Config{Backend: be, Version: "2.2.4-s3", Lang: lang, Glyphs: GlyphUnicode, Now: time.Now,
		Width: 100, Height: 32, NoAnimation: true})
	p := probe{Model: m, mu: &sync.Mutex{}, frames: &[]string{}}
	tm := teatest.NewTestModel(t, p, teatest.WithInitialTermSize(100, 32))
	return tm, p
}

func press(tm *teatest.TestModel, keys ...string) {
	for _, k := range keys {
		tm.Send(keyMsg(k))
	}
}

func typeInto(tm *teatest.TestModel, s string) {
	for _, r := range s {
		tm.Send(tea.KeyPressMsg{Code: r, Text: string(r)})
	}
}

// walkWizard answers every page of the Full preset; the secrets are fakes.
func walkWizard(t *testing.T, tm *teatest.TestModel, p probe) {
	t.Helper()
	p.waitFor(t, "Setting 1 of")
	press(tm, "enter") // shell language
	p.waitFor(t, "Setting 2 of")
	press(tm, "enter") // notes folder
	p.waitFor(t, "Gemini key")
	typeInto(tm, fakeGemini)
	press(tm, "enter", "enter")
	p.waitFor(t, "Remnawave panel address")
	typeInto(tm, "https://panel.example.com")
	press(tm, "enter")
	typeInto(tm, fakeToken)
	press(tm, "enter")
	p.waitFor(t, "VPN: subscription")
	typeInto(tm, fakeSub)
	press(tm, "enter", "enter", "enter")
	p.waitFor(t, "Start the daemon")
	press(tm, "enter", "enter")
}

func TestScenarioFullInstallWithSkipAndNoLeaks(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	be.Fail["vpn.install"] = 1
	tm, p := startProgram(t, be, "en")

	p.waitFor(t, "ready to go")
	press(tm, "enter") // I1 -> I3 (nothing installed)
	p.waitFor(t, "Hotkeys menu")
	press(tm, "enter") // I3 -> wizard
	walkWizard(t, tm, p)
	p.waitFor(t, "Everything is ready")
	out := p.last()
	for _, s := range []string{fakeGemini, fakeToken, fakeSub} {
		if strings.Contains(out, s) {
			t.Fatalf("secret on the summary screen")
		}
	}
	p.waitFor(t, "Remnawave")
	press(tm, "enter") // start
	p.waitFor(t, "It did not work")
	p.waitFor(t, "Skip VPN (Xray)")
	press(tm, "s")
	p.waitFor(t, "Done in")
	if !strings.Contains(p.last(), "VPN (Xray) skipped") {
		t.Fatalf("skipped module missing from the finish screen:\n%s", p.last())
	}
	press(tm, "q")
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
	fm := tm.FinalModel(t).(probe)
	if fm.result.Action != ActionExit || !fm.result.OK {
		t.Fatalf("result = %+v", fm.result)
	}

	// what the engine received
	be.mu.Lock()
	last := be.Last
	decided := be.Decided
	be.mu.Unlock()
	if last.Secrets["ai.gemini_key"] != fakeGemini || last.Secrets["servers.remnawave_token"] != fakeToken ||
		last.Secrets["vpn.subscription"] != fakeSub || last.Secrets["servers.remnawave_url"] != "https://panel.example.com" {
		t.Fatalf("secrets did not reach the engine: %d keys", len(last.Secrets))
	}
	if last.Mode != ModeInstall || last.Config["vpn.mode"] != "ru-direct" || last.Config["servers.generate_key"] != "true" {
		t.Fatalf("request = %+v", last.Config)
	}
	if len(decided) != 1 || decided[0] != plain.Skip {
		t.Fatalf("decisions = %v", decided)
	}
	// nothing the program drew or wrote contains a secret
	for i, f := range p.all() {
		for _, s := range []string{fakeGemini, fakeToken, fakeSub} {
			if strings.Contains(f, s) {
				t.Fatalf("frame %d leaks a secret", i)
			}
		}
	}
	raw, _ := io.ReadAll(tm.FinalOutput(t))
	for _, s := range []string{fakeGemini, fakeToken, fakeSub, "FAKE-TOKEN", "AIzaFAKE"} {
		if strings.Contains(string(raw), s) {
			t.Fatalf("terminal output leaks %q", s)
		}
	}
}

func TestScenarioAbortOnRequiredModule(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	be.Fail["core.packages"] = 1
	tm, p := startProgram(t, be, "ru")
	p.waitFor(t, "можно продолжать")
	press(tm, "enter", "2", "enter") // Minimal preset -> wizard (shell language only)
	p.waitFor(t, "Настройка 1 из 1")
	press(tm, "enter")
	p.waitFor(t, "Всё готово")
	press(tm, "enter")
	p.waitFor(t, "Не получилось")
	if strings.Contains(p.last(), "Пропустить") {
		t.Fatal("the required module must not offer Skip")
	}
	press(tm, "a")
	p.waitFor(t, "Установка не завершена")
	press(tm, "enter")
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
	fm := tm.FinalModel(t).(probe)
	if fm.result.OK || fm.result.Err == nil || fm.result.Action != ActionExit {
		t.Fatalf("result = %+v", fm.result)
	}
}

func TestScenarioRetryThenDone(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	be.Fail["core.keys"] = 2
	tm, p := startProgram(t, be, "en")
	p.waitFor(t, "ready to go")
	press(tm, "enter", "2", "enter")
	p.waitFor(t, "Setting 1 of 1")
	press(tm, "enter")
	p.waitFor(t, "Everything is ready")
	press(tm, "enter")
	p.waitFor(t, "It did not work")
	press(tm, "r")
	waitUntil(t, func() bool { be.mu.Lock(); defer be.mu.Unlock(); return len(be.Decided) == 1 })
	time.Sleep(50 * time.Millisecond) // the second failure raises the modal again
	p.waitFor(t, "It did not work")
	press(tm, "r")
	p.waitFor(t, "Done in")
	press(tm, "right", "enter") // Hyprland (no reboot button first: nvidia is off in Minimal)
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
	fm := tm.FinalModel(t).(probe)
	if fm.result.Action != ActionExit && fm.result.Action != ActionReboot && fm.result.Action != ActionHyprland {
		t.Fatalf("result = %+v", fm.result)
	}
	if !fm.result.OK {
		t.Fatal("run must succeed after the retries")
	}
	if got := be.Decided; len(got) != 2 || got[0] != plain.Retry || got[1] != plain.Retry {
		t.Fatalf("decisions = %v", got)
	}
}

func TestScenarioCtrlCQuits(t *testing.T) {
	be := newFake(t, preflight.InstallNone)
	tm, p := startProgram(t, be, "en")
	p.waitFor(t, "ready to go")
	tm.Send(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
}

func waitUntil(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not reached")
}
