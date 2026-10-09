package tui

import (
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/golden"

	"serpx/installer"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/preflight"
)

var t0 = time.Date(2026, 10, 7, 19, 4, 0, 0, time.UTC)

func loadSet(t testing.TB) *manifest.Set {
	t.Helper()
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		t.Fatal(err)
	}
	return set
}

func report(kind preflight.InstallKind, resume bool) preflight.Report {
	c := func(id string, st preflight.Status, code string, a ...any) preflight.Check {
		return preflight.Check{ID: id, Status: st, Code: code, Args: a}
	}
	r := preflight.Report{Facts: preflight.Facts{
		GPUs: []string{"nvidia"}, Install: kind, Version: "2.2.4-s2", NeedsResume: resume, NetSpeedBps: 11.4 * (1 << 20),
	}}
	r.Checks = []preflight.Check{
		c(preflight.CheckArch, preflight.OK, "arch.ok", "arch"),
		c(preflight.CheckRoot, preflight.OK, "root.ok"),
		c(preflight.CheckSudo, preflight.OK, "sudo.ok"),
		c(preflight.CheckNet, preflight.OK, "net.ok", "11.4"),
		c(preflight.CheckDisk, preflight.OK, "disk.ok", 4096),
		c(preflight.CheckRAM, preflight.OK, "ram.ok", 7800),
		c(preflight.CheckGPU, preflight.Warn, "gpu.nvidia"),
		c(preflight.CheckAUR, preflight.OK, "aur.none"),
		c(preflight.CheckConsole, preflight.OK, "console.ok", "xterm-256color", "unicode", 256),
	}
	switch kind {
	case preflight.InstallSerpX:
		r.Checks = append(r.Checks, c(preflight.CheckInstall, preflight.OK, "install.serp-x", "2.2.4-s2"))
	default:
		r.Checks = append(r.Checks, c(preflight.CheckInstall, preflight.OK, "install.none"))
	}
	if resume {
		r.Checks = append(r.Checks, c(preflight.CheckResume, preflight.OK, "resume.yes"))
	}
	return r
}

func newFake(t testing.TB, kind preflight.InstallKind) *FakeBackend {
	f := &FakeBackend{SetV: loadSet(t), Report: report(kind, false), Fail: map[string]int{}}
	if kind == preflight.InstallSerpX {
		f.InstalledV = &Installed{Build: "2.2.4-s2", InstalledAt: time.Date(2026, 9, 12, 10, 0, 0, 0, time.UTC),
			Modules: []string{"core", "hotkeys", "emoji", "tools", "ocr", "ai-gemini", "servers", "commands", "commands-media"}}
	}
	return f
}

func newModel(t testing.TB, be Backend, lang, glyphs string) *Model {
	cfg := Config{Backend: be, Version: "2.2.4-s3", Lang: lang, Glyphs: glyphs, Sixteen: glyphs == GlyphASCII,
		Now: func() time.Time { return t0 }, Width: 100, Height: 32, NoAnimation: true, NoTick: true}
	return New(cfg)
}

// exec runs a command like the runtime would, but gives up after a short
// time (tick and session waits block by design).
func exec(cmd tea.Cmd) tea.Msg {
	if cmd == nil {
		return nil
	}
	ch := make(chan tea.Msg, 1)
	go func() { ch <- cmd() }()
	select {
	case m := <-ch:
		return m
	case <-time.After(150 * time.Millisecond):
		return nil
	}
}

// send feeds a message and every non-blocking command it produces.
func send(m *Model, msg tea.Msg) {
	var feed func(tea.Msg)
	feed = func(msg tea.Msg) {
		if msg == nil {
			return
		}
		_, cmd := m.Update(msg)
		if cmd == nil {
			return
		}
		res := exec(cmd)
		if b, ok := res.(tea.BatchMsg); ok {
			for _, c := range b {
				feed(exec(c))
			}
			return
		}
		feed(res)
	}
	feed(msg)
}

func key(m *Model, keys ...string) {
	for _, k := range keys {
		send(m, keyMsg(k))
	}
}

func keyMsg(k string) tea.KeyPressMsg {
	switch k {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "tab":
		return tea.KeyPressMsg{Code: tea.KeyTab}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "left":
		return tea.KeyPressMsg{Code: tea.KeyLeft}
	case "right":
		return tea.KeyPressMsg{Code: tea.KeyRight}
	case "space":
		return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	case "backspace2":
		return tea.KeyPressMsg{Code: tea.KeyBackspace}
	case "ctrl+s":
		return tea.KeyPressMsg{Code: 's', Mod: tea.ModCtrl}
	case "f2":
		return tea.KeyPressMsg{Code: tea.KeyF2}
	}
	r := []rune(k)
	return tea.KeyPressMsg{Code: r[0], Text: k}
}

func typeText(m *Model, s string) {
	for _, r := range s {
		send(m, tea.KeyPressMsg{Code: r, Text: string(r)})
	}
}

// boot loads the preflight (the program does this from Init).
func boot(m *Model) { send(m, m.Init()()) }

func screenText(m *Model) string { return ansi.Strip(m.render()) }

func checkGolden(t *testing.T, m *Model) {
	t.Helper()
	golden.RequireEqual(t, []byte(screenText(m)))
}

// feedEvents applies synthetic engine events to the progress screen.
func feedEvents(m *Model, evs ...any) {
	for _, e := range evs {
		m.Update(sessMsg{e})
	}
}
