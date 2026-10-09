package tui

import (
	"fmt"
	"testing"
	"time"

	"serpx/installer/internal/preflight"
)

type variant struct{ lang, glyphs string }

var variants = []variant{{"ru", GlyphNerd}, {"en", GlyphNerd}, {"ru", GlyphASCII}, {"en", GlyphASCII}}

func (v variant) name() string { return v.lang + "_" + v.glyphs }

// toModules walks a fresh machine to the module screen.
func toModules(t *testing.T, v variant) (*Model, *FakeBackend) {
	be := newFake(t, preflight.InstallNone)
	m := newModel(t, be, v.lang, v.glyphs)
	boot(m)
	key(m, "enter") // -> modules
	return m, be
}

// toSummary: Full preset, defaults in the wizard, key and token entered.
func toWizard(t *testing.T, v variant) (*Model, *FakeBackend) {
	m, be := toModules(t, v)
	key(m, "enter") // -> wizard page 1 (core language)
	return m, be
}

func TestScreens(t *testing.T) {
	for _, v := range variants {
		v := v
		t.Run(v.name(), func(t *testing.T) {
			t.Run("I1_check", func(t *testing.T) {
				be := newFake(t, preflight.InstallSerpX)
				m := newModel(t, be, v.lang, v.glyphs)
				boot(m)
				checkGolden(t, m)
			})
			t.Run("I2_mode", func(t *testing.T) {
				be := newFake(t, preflight.InstallSerpX)
				m := newModel(t, be, v.lang, v.glyphs)
				boot(m)
				key(m, "enter")
				if m.screen != ScrMode {
					t.Fatalf("screen = %v", m.screen)
				}
				checkGolden(t, m)
			})
			t.Run("I3_modules", func(t *testing.T) {
				m, _ := toModules(t, v)
				key(m, "2")
				// go to commands-media and turn it on: Commands comes automatically
				for m.mod.rows[m.mod.cur].id != "commands-media" {
					key(m, "down")
				}
				key(m, "space")
				checkGolden(t, m)
			})
			t.Run("I4_wizard_secret", func(t *testing.T) {
				m, _ := toWizard(t, v)
				gotoPage(t, m, "ai-gemini")
				typeText(m, "AIzaFAKE0000000000000000000000000000")
				checkGolden(t, m)
			})
			t.Run("I5_wizard_ssh", func(t *testing.T) {
				m, _ := toWizard(t, v)
				gotoPage(t, m, "servers")
				typeText(m, "https://panel.example.com")
				key(m, "enter")
				typeText(m, "FAKE-TOKEN-0000")
				checkGolden(t, m)
			})
			t.Run("I6_summary", func(t *testing.T) {
				m, _ := toModules(t, v)
				for i := 0; i < 10 && m.screen != ScrSummary; i++ {
					key(m, "enter")
					if p := m.curPage(); p != nil && m.screen == ScrWizard {
						// skip the secret pages
						if p.canSkip() {
							key(m, "ctrl+s")
						}
					}
				}
				checkGolden(t, m)
			})
			t.Run("I7_progress", func(t *testing.T) {
				m := progressModel(t, v, false)
				checkGolden(t, m)
			})
			t.Run("I8_progress_log", func(t *testing.T) {
				m := progressModel(t, v, true)
				checkGolden(t, m)
			})
			t.Run("I9_error", func(t *testing.T) {
				m := progressModel(t, v, true)
				feedEvents(m, evFail{"vpn.install", "dial tcp: lookup proxy.golang.org: i/o timeout"},
					evDecide{"vpn.install", "dial tcp: lookup proxy.golang.org: i/o timeout", true,
						[]string{"==> Starting build()...", "go: downloading github.com/xtls/reality v0.0.0-2026", "dial tcp: lookup proxy.golang.org: i/o timeout", "==> ERROR: A failure occurred in build(). Aborting..."}})
				checkGolden(t, m)
			})
			t.Run("I10_finish", func(t *testing.T) {
				m := progressModel(t, v, false)
				m.now = t0.Add(13*time.Minute + 48*time.Second)
				feedEvents(m, evRunEnd{res: RunResult{Skipped: []string{"vpn"}, BackupPath: "~/serpantinum-backups/serpantinum-backup-2026-10-07.tar.zst",
					ConfigPath: "~/serpantinum-backups/my-setup.toml", Restored: "settings, 14 commands, 31 notes"}})
				if m.screen != ScrFinish {
					t.Fatalf("screen = %v", m.screen)
				}
				checkGolden(t, m)
			})
		})
	}
}

// progressModel builds the progress screen with a few finished steps.
func progressModel(t *testing.T, v variant, logOn bool) *Model {
	m, _ := toModules(t, v)
	key(m, "1") // Full preset (nvidia is detected)
	// enter through the wizard without skipping: defaults are valid
	for i := 0; i < 12 && m.screen != ScrSummary; i++ {
		key(m, "enter")
		if m.screen == ScrWizard {
			if p := m.curPage(); p != nil && p.canSkip() {
				key(m, "ctrl+s")
			}
		}
	}
	if m.screen != ScrSummary || m.sum.plan == nil {
		t.Fatalf("no summary: screen=%v", m.screen)
	}
	s := m.initProgress(*m.sum.plan)
	_ = s
	m.go2(ScrProgress)
	m.prg.started = t0
	n := len(m.prg.steps)
	step := 3
	for i := 0; i < step; i++ {
		m.now = t0.Add(time.Duration(i+1) * 4 * time.Second)
		feedEvents(m, evStart{id: m.prg.steps[i].info.ID, index: i + 1, total: n})
		m.now = m.now.Add(3 * time.Second)
		feedEvents(m, evDone{id: m.prg.steps[i].info.ID})
	}
	m.now = t0.Add(5*time.Minute + 12*time.Second)
	id := m.prg.steps[step].info.ID
	feedEvents(m, evStart{id: id, index: step + 1, total: n})
	m.now = t0.Add(5*time.Minute + 12*time.Second)
	feedEvents(m, evDetail{id: id, d: Detail{DoneMiB: 412, TotalMiB: 961, SpeedMBs: 11.2, File: "qt6-declarative"}})
	for i, l := range []string{"(24/63) checking keys in keyring", "qt6-declarative-6.10.1-1-x86_64   12.4 MiB  11.6 MiB/s 00:01 [####] 100%",
		"pipewire-1:1.6.2-1-x86_64   2.1 MiB  11.4 MiB/s 00:00 [####] 100%", "eta: download 441 MiB / 11.5 MB/s = 38 s", "pipewire-pulse-1:1.6.2-1-x86_64   18.3 KiB   ..."} {
		m.now = t0.Add(5*time.Minute + 12*time.Second + time.Duration(i)*time.Second)
		feedEvents(m, evLog{id, l})
	}
	m.now = t0.Add(5*time.Minute + 17*time.Second)
	m.prg.shown = m.prg.fraction(m.now)
	m.prg.remain = 7 * time.Minute
	m.prg.logOn = logOn
	return m
}

func TestAnimatedGlyphsAreStable(t *testing.T) {
	// the spinner frame is the only moving part: two frames differ in one cell
	m := progressModel(t, variant{"ru", GlyphNerd}, false)
	a := screenText(m)
	m.frame = 3
	b := screenText(m)
	if a == b {
		t.Fatal("spinner does not move")
	}
	_ = fmt.Sprint
}

// gotoPage presses Enter through the wizard until the page of module shows.
func gotoPage(t *testing.T, m *Model, module string) {
	t.Helper()
	for i := 0; i < 12; i++ {
		if p := m.curPage(); m.screen == ScrWizard && p != nil && p.module == module {
			return
		}
		if p := m.curPage(); p != nil && p.canSkip() {
			key(m, "ctrl+s")
			continue
		}
		key(m, "enter")
	}
	t.Fatalf("page %s not reached", module)
}
