package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"serpx/installer/internal/engine"
	"serpx/installer/internal/journal"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/tui"
)

// ModeReconcile is the CLI-only mode (no screen): bring the installation in
// line with the manifests.
const ModeReconcile = "reconcile"

const tailKeep = 40

// bridge turns engine callbacks into Handler calls, writes the per-run log
// and keeps the last lines for the error screen. Everything that passes
// through it is redacted first.
type bridge struct {
	h      tui.Handler
	lang   string
	redact func(string) string
	now    func() time.Time

	mu    sync.Mutex
	cur   string
	tail  []string
	total int
	logw  *os.File
}

func (b *bridge) write(src, line string) {
	line = b.redact(strings.TrimRight(line, "\r\n"))
	b.mu.Lock()
	b.tail = append(b.tail, line)
	if len(b.tail) > tailKeep {
		b.tail = b.tail[len(b.tail)-tailKeep:]
	}
	id := b.cur
	if b.logw != nil {
		fmt.Fprintf(b.logw, "%s %-7s %s\n", b.now().Format("15:04:05"), src, line)
	}
	b.mu.Unlock()
	b.h.StepLog(id, line)
}

func (b *bridge) lastLines(n int) []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.tail) < n {
		n = len(b.tail)
	}
	return append([]string(nil), b.tail[len(b.tail)-n:]...)
}

// steps.Reporter

func (b *bridge) Log(msg string)  { b.write("engine", msg) }
func (b *bridge) Warn(msg string) { b.write("warn", msg) }
func (b *bridge) Progress(frac float64, text string) {
	if frac >= 0 {
		b.mu.Lock()
		id := b.cur
		b.mu.Unlock()
		b.h.StepProgress(id, int(frac*100))
	}
	if text != "" {
		b.write("engine", text)
	}
}

// onStep is engine.Setup.OnStep.
func (b *bridge) onStep(i, n int, s steps.Step, ev string) {
	b.mu.Lock()
	first := b.total == 0
	b.total = n
	b.mu.Unlock()
	if first {
		b.h.PlanStart(n)
	}
	switch ev {
	case journal.EvStart:
		b.mu.Lock()
		b.cur = s.ID()
		b.mu.Unlock()
		b.write("engine", "start "+s.ID())
		b.h.StepStart(s.ID(), s.Title(b.lang), i, n)
	case journal.EvDone:
		b.write("engine", "done "+s.ID())
		b.h.StepDone(s.ID(), false)
	case journal.EvSkip:
		b.h.StepStart(s.ID(), s.Title(b.lang), i, n)
		b.h.StepDone(s.ID(), true)
	}
}

type confirmer interface{ Confirm(string) bool }

func confirmText(lang, kind string, items []string) string {
	list := strings.Join(items, ", ")
	switch {
	case kind == "data" && lang == "en":
		return "Remove your data: " + list + "?"
	case kind == "data":
		return "Удалить твои данные: " + list + "?"
	case lang == "en":
		return "Remove packages: " + list + "?"
	}
	return "Удалить пакеты: " + list + "?"
}

// Run implements tui.Backend: it runs one mode of the engine and reports to h.
func (s *Service) Run(ctx context.Context, req tui.Request, h tui.Handler) (tui.RunResult, error) {
	var res tui.RunResult
	s.registerSecrets(req)
	req, upstream := s.adoptUpstream(req)
	payload, err := s.Payload()
	if err != nil && req.Mode != tui.ModeUninstall {
		return res, err // removing things needs no payload; every other mode does
	}
	if err := os.MkdirAll(filepath.Dir(s.LogPath()), 0o700); err != nil {
		return res, err
	}
	lf, err := os.OpenFile(s.LogPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return res, err
	}
	defer lf.Close()
	b := &bridge{h: h, lang: s.cfg.Lang, redact: s.log.Redact, now: s.cfg.Now, logw: lf}
	if req.Lang != "" {
		b.lang = req.Lang
	}
	s.log.Info("run", "mode", req.Mode, "modules", strings.Join(req.Modules, ","), "run", s.runID)

	env := s.newEnv(req, b, payload)
	skippedByUser := map[string]bool{}
	setup := &engine.Setup{
		Env: env, Cat: s.cat, Resume: req.Resume, Restore: req.Restore != "" || req.Reinstall,
		OnStep: b.onStep, Arm: s.arm,
		Decide: func(st steps.Step, err error) engine.Decision {
			shown := errors.New(s.log.Redact(err.Error()))
			optional := false
			if mod := st.Module(); mod != "" {
				if m, ok := s.set.Get(mod); ok && !m.Core {
					optional = true
				}
			}
			b.write("error", st.ID()+": "+shown.Error())
			h.StepFail(st.ID(), shown)
			switch h.Decide(st.ID(), shown, optional, b.lastLines(8)) {
			case plain.Retry:
				return engine.Retry
			case plain.Skip:
				skippedByUser[st.Module()] = true
				return engine.Skip
			}
			return engine.Abort
		},
		Confirm: func(kind string, items []string) bool {
			if kind == "data" && req.RemoveData {
				return true // ticked on the summary screen, backup is made first
			}
			if c, ok := h.(confirmer); ok {
				return c.Confirm(confirmText(b.lang, kind, items))
			}
			return false
		},
	}

	archive := req.Restore
	var before []string
	if in := s.Installed(); in != nil {
		before = in.Modules
	}
	if req.Mode == tui.ModeInstall && req.Reinstall && (len(before) > 0 || upstream) {
		ar, err := s.autoBackup(before, env.Expand(req.Config["tools.notes_dir"]))
		if err != nil {
			return res, fmt.Errorf("backup before reinstall: %w", err)
		}
		res.BackupPath = s.display(ar.Archive)
		if archive == "" {
			archive = ar.Archive
		}
	}
	env.Hooks.Restore = s.restoreHook(env, archive, func(m string, retype []string) { res.Restored, res.Retype = m, retype })

	if req.Mode != tui.ModeUninstall {
		stop := run.KeepAlive(ctx, s.runner(), time.Minute, func(err error) { b.write("warn", "sudo keep-alive: "+err.Error()) })
		defer stop()
	}
	switch req.Mode {
	case tui.ModeInstall:
		err = engine.Install(ctx, setup, req.Modules)
	case tui.ModeRepair:
		err = engine.Repair(ctx, setup)
	case tui.ModeModules:
		err = engine.Modules(ctx, setup, req.Modules)
	case ModeReconcile:
		err = engine.Reconcile(ctx, setup)
	case tui.ModeUninstall:
		err = engine.Uninstall(ctx, setup, engine.UninstallOptions{RemoveData: req.RemoveData, BackupBefore: func(context.Context) error {
			var mods []string
			if in := s.Installed(); in != nil {
				mods = in.Modules
			}
			ar, err := s.autoBackup(mods, "")
			if err == nil {
				res.BackupPath = s.display(ar.Archive)
			}
			return err
		}})
	default:
		err = fmt.Errorf("unknown mode %q", req.Mode)
	}
	if err != nil {
		s.log.Error("run failed", "error", err.Error())
		b.h.Finish(false)
		return res, errors.New(s.log.Redact(err.Error()))
	}
	// modules that did not make it (skipped by the user or by a cascade)
	if req.Mode == tui.ModeInstall || req.Mode == tui.ModeModules {
		have := map[string]bool{}
		if in := s.Installed(); in != nil {
			for _, m := range in.Modules {
				have[m] = true
			}
		}
		if sel, e := s.selection(req); e == nil {
			for _, m := range sel.Modules {
				if !have[m] && (skippedByUser[m] || len(skippedByUser) > 0) {
					res.Skipped = append(res.Skipped, m)
				}
			}
		}
		if p, e := s.ExportSetup(req); e == nil {
			res.ConfigPath = p
		}
	}
	b.h.Finish(true)
	return res, nil
}
