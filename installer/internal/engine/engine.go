// Package engine runs a step list: Check -> Apply -> Verify with the journal,
// retry/skip/abort decisions, module rollback and the five modes (install,
// repair, modules, uninstall, reconcile).
package engine

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"syscall"
	"time"

	"serpx/installer/internal/journal"
	"serpx/installer/internal/steps"
)

// Decision after a failed step (screen I9).
type Decision int

const (
	Abort Decision = iota // keep the journal, roll back nothing
	Retry
	Skip // non-core only: roll back the module's steps, mark it skipped
)

// SyncFS flushes every filesystem. A step that changed the system is journalled "done" only after
// this: without it a power loss leaves a durable "done" next to files that never reached the disk
// (found in the QEMU stand: a zero-filled /usr/bin/yay, a deploy that vanished). Tests replace it.
var SyncFS = syscall.Sync

// ErrAborted: the user (or a nil Decide) stopped the run after a failure.
var ErrAborted = errors.New("engine: aborted")

// StepError wraps the failure that ended a run.
type StepError struct {
	Step string
	Err  error
}

func (e *StepError) Error() string { return fmt.Sprintf("step %s: %v", e.Step, e.Err) }
func (e *StepError) Unwrap() error { return e.Err }

// Engine executes steps.
type Engine struct {
	Env     *steps.Env
	Journal *journal.Journal
	// Decide is called after a failure. nil means Abort.
	Decide func(step steps.Step, err error) Decision
	// Resume skips steps the journal already marks done/skipped.
	Resume bool
	// RecheckAll (repair/reconcile): ignore the journal and Check+Verify every step.
	RecheckAll bool
	// Requires maps a module to the modules it needs (skip cascades to dependents).
	Requires map[string][]string
	// OnStep (optional) observes progress: index is 1-based.
	OnStep func(i, n int, s steps.Step, ev string)

	skipped map[string]bool
	done    map[string][]steps.Step
	timings map[string]float64
}

func (g *Engine) rep() steps.Reporter {
	if g.Env.Rep == nil {
		return steps.NopReporter{}
	}
	return g.Env.Rep
}

func (g *Engine) note(i, n int, s steps.Step, ev string) {
	if g.OnStep != nil {
		g.OnStep(i, n, s, ev)
	}
}

// Run executes the list and, on success, writes the finish event and timings.
func (g *Engine) Run(ctx context.Context, list []steps.Step) error {
	g.skipped = map[string]bool{}
	g.done = map[string][]steps.Step{}
	g.timings = map[string]float64{}
	var prev map[string]string
	if g.Resume && !g.RecheckAll {
		entries, err := journal.Read(filepath.Join(g.Journal.Dir(), journal.FileJournal))
		if err != nil {
			return err
		}
		prev = journal.States(entries)
		// a step that has a start but no end was cut by a kill / power loss: pacman may have
		// left a stale lock or a half-written package behind
		for _, ev := range prev {
			if ev == journal.EvStart {
				if err := steps.RecoverPacman(ctx, g.Env, g.rep()); err != nil {
					return fmt.Errorf("recover after the interrupted run: %w", err)
				}
				break
			}
		}
	}
	for i, s := range list {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := len(list)
		if mod := s.Module(); mod != "" && g.skipped[mod] {
			g.Journal.Append(s.ID(), journal.EvSkip, map[string]any{"reason": "module-skipped"})
			g.note(i+1, n, s, journal.EvSkip)
			continue
		}
		if prev != nil && journal.StepFinished(prev, s.ID()) {
			g.note(i+1, n, s, journal.EvSkip)
			if mod := s.Module(); mod != "" && prev[s.ID()] == journal.EvDone {
				g.done[mod] = append(g.done[mod], s)
			}
			continue
		}
		if err := g.runStep(ctx, i+1, n, s); err != nil {
			return err
		}
	}
	if err := g.Journal.Append("", journal.EvFinish, nil); err != nil {
		return err
	}
	return g.writeTimings()
}

func (g *Engine) runStep(ctx context.Context, i, n int, s steps.Step) error {
	for {
		if err := g.Journal.Append(s.ID(), journal.EvStart, nil); err != nil {
			return err
		}
		g.note(i, n, s, journal.EvStart)
		t0 := time.Now()
		skip, err := g.attempt(ctx, s)
		if err == nil {
			ev := journal.EvDone
			info := map[string]any{"ms": time.Since(t0).Milliseconds()}
			if skip {
				ev = journal.EvSkip
				info["reason"] = "already"
			} else {
				g.timings[s.ID()] = time.Since(t0).Seconds()
				if m := s.Module(); m != "" {
					g.done[m] = append(g.done[m], s)
				}
			}
			if err := g.Journal.Append(s.ID(), ev, info); err != nil {
				return err
			}
			g.note(i, n, s, ev)
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err() // interrupted: no fail event, the step is re-checked on resume
		}
		g.Journal.Append(s.ID(), journal.EvFail, map[string]any{"error": err.Error()})
		g.note(i, n, s, journal.EvFail)
		d := Abort
		if g.Decide != nil {
			d = g.Decide(s, err)
		}
		switch {
		case d == Retry:
			continue
		case d == Skip && s.Module() != "" && !g.isCore(s.Module()):
			return g.skipModule(ctx, s.Module(), i, n, s)
		}
		return &StepError{Step: s.ID(), Err: fmt.Errorf("%w: %v", ErrAborted, err)}
	}
}

func (g *Engine) isCore(mod string) bool {
	if g.Env.Set == nil {
		return mod == "core"
	}
	m, ok := g.Env.Set.Get(mod)
	return ok && m.Core
}

// attempt is Check -> Apply -> Verify; skip=true when Check said "done" and,
// in repair mode, Verify agreed.
func (g *Engine) attempt(ctx context.Context, s steps.Step) (skip bool, err error) {
	done, err := s.Check(ctx, g.Env)
	if err != nil {
		return false, err
	}
	if done {
		if g.RecheckAll {
			if verr := s.Verify(ctx, g.Env); verr != nil {
				done = false // looks done but is broken: apply again
			}
		}
		if done {
			return true, nil
		}
	}
	if err := s.Apply(ctx, g.Env, g.rep()); err != nil {
		return false, err
	}
	if err := s.Verify(ctx, g.Env); err != nil {
		return false, fmt.Errorf("verify: %w", err)
	}
	SyncFS()
	return false, nil
}

// skipModule rolls back the finished steps of mod (newest first), then marks
// mod and every module that requires it as skipped.
func (g *Engine) skipModule(ctx context.Context, mod string, i, n int, failed steps.Step) error {
	g.skipped[mod] = true
	// the failed step may have left partial changes behind
	err := failed.Rollback(ctx, g.Env)
	info := map[string]any{}
	if err != nil {
		info["error"] = err.Error()
	}
	g.Journal.Append(failed.ID(), journal.EvUndo, info)
	for changed := true; changed; {
		changed = false
		for m, reqs := range g.Requires {
			if g.skipped[m] {
				continue
			}
			for _, r := range reqs {
				if g.skipped[r] {
					g.skipped[m] = true
					changed = true
				}
			}
		}
	}
	for m := range g.skipped {
		list := g.done[m]
		for j := len(list) - 1; j >= 0; j-- {
			st := list[j]
			err := st.Rollback(ctx, g.Env)
			info := map[string]any{}
			if err != nil {
				info["error"] = err.Error()
			}
			g.Journal.Append(st.ID(), journal.EvUndo, info)
		}
		g.done[m] = nil
	}
	g.Journal.Append(failed.ID(), journal.EvSkip, map[string]any{"reason": "user", "module": mod})
	g.note(i, n, failed, journal.EvSkip)
	return nil
}

// Skipped returns the modules skipped during the run.
func (g *Engine) Skipped() []string {
	var out []string
	for m := range g.skipped {
		out = append(out, m)
	}
	return out
}

func (g *Engine) writeTimings() error {
	if len(g.timings) == 0 {
		return nil
	}
	path := filepath.Join(g.Journal.Dir(), journal.FileTimings)
	old := map[string]float64{}
	if b, err := readFile(path); err == nil {
		jsonUnmarshal(b, &old)
	}
	for k, v := range g.timings {
		old[k] = v
	}
	return journal.WriteJSON(path, old)
}
