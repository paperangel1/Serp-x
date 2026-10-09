package tui

import (
	"context"
	"sync"

	tea "charm.land/bubbletea/v2"

	"serpx/installer/internal/plain"
)

// Events flowing from the engine goroutine to the model.
type (
	evStart struct {
		id           string
		index, total int
	}
	evProgress struct {
		id  string
		pct int
	}
	evLog  struct{ id, line string }
	evDone struct {
		id      string
		skipped bool
	}
	evFail struct {
		id  string
		err string
	}
	evDetail struct {
		id string
		d  Detail
	}
	evDecide struct {
		id       string
		err      string
		optional bool
		tail     []string
	}
	evRunEnd struct {
		res RunResult
		err error
	}
)

// sessMsg carries one event into Update.
type sessMsg struct{ ev any }

// session implements Handler: it turns engine callbacks into messages and
// blocks the engine while the user decides (error modal) or pauses.
type session struct {
	ch   chan any
	dec  chan plain.Decision
	stop chan struct{}
	ctx  context.Context

	mu      sync.Mutex
	pauseCh chan struct{} // non-nil while paused; closed on resume
	stopped sync.Once
}

func newSession(ctx context.Context) *session {
	return &session{ch: make(chan any, 4096), dec: make(chan plain.Decision, 1), stop: make(chan struct{}), ctx: ctx}
}

func (s *session) close() { s.stopped.Do(func() { close(s.stop) }) }

func (s *session) send(ev any) {
	select {
	case s.ch <- ev:
	case <-s.stop:
	}
}

// wait returns a command that delivers the next event.
func (s *session) wait() tea.Cmd {
	return func() tea.Msg {
		select {
		case ev := <-s.ch:
			return sessMsg{ev}
		case <-s.stop:
			return nil
		}
	}
}

func (s *session) setPaused(p bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case p && s.pauseCh == nil:
		s.pauseCh = make(chan struct{})
	case !p && s.pauseCh != nil:
		close(s.pauseCh)
		s.pauseCh = nil
	}
}

func (s *session) gate() {
	s.mu.Lock()
	ch := s.pauseCh
	s.mu.Unlock()
	if ch == nil {
		return
	}
	select {
	case <-ch:
	case <-s.ctx.Done():
	case <-s.stop:
	}
}

// plain.Sink

func (s *session) PlanStart(int) {}
func (s *session) StepStart(id, _ string, index, total int) {
	s.gate()
	s.send(evStart{id, index, total})
}
func (s *session) StepProgress(id string, pct int)  { s.send(evProgress{id, pct}) }
func (s *session) StepLog(id, line string)          { s.send(evLog{id, line}) }
func (s *session) StepDone(id string, skipped bool) { s.send(evDone{id, skipped}) }
func (s *session) StepFail(id string, err error)    { s.send(evFail{id, err.Error()}) }
func (s *session) Finish(bool)                      {}

// Detail implements Handler.
func (s *session) Detail(id string, d Detail) { s.send(evDetail{id, d}) }

// Decide implements Handler.
func (s *session) Decide(id string, err error, optional bool, tail []string) plain.Decision {
	s.send(evDecide{id, err.Error(), optional, tail})
	select {
	case d := <-s.dec:
		return d
	case <-s.ctx.Done():
		return plain.Abort
	case <-s.stop:
		return plain.Abort
	}
}
