package eta

import (
	"sync"
	"time"
)

// Kind of a plan item for estimating.
type Kind int

const (
	KindOther    Kind = iota // median of timings or EstimateS
	KindDownload             // Bytes to fetch
	KindInstall              // InstalledMiB
	KindAUR                  // BuildS
)

// Item is one planned step with its inputs.
type Item struct {
	ID           string
	Kind         Kind
	Bytes        int64
	InstalledMiB float64
	BuildS       int
	EstimateS    int
}

// Event is what the engine reports (the engine adapts its own events to it).
type Event struct {
	Step  string
	Kind  string // "start", "done", "skip", "fail", "bytes"
	At    time.Time
	Bytes int64 // for "bytes": cumulative downloaded in the current transfer
}

// Tracker turns a stream of events into "remaining time".
type Tracker struct {
	mu      sync.Mutex
	m       *Model
	items   []Item
	state   map[string]string // "", "run", "end"
	started map[string]time.Time
	elapsed map[string]time.Duration
	sm      Smoother
	got     map[string]int64 // bytes fetched per download item
}

// NewTracker plans the items in order.
func NewTracker(m *Model, items []Item) *Tracker {
	return &Tracker{m: m, items: items, state: map[string]string{},
		started: map[string]time.Time{}, elapsed: map[string]time.Duration{}, got: map[string]int64{}}
}

func (t *Tracker) estimate(it Item) time.Duration {
	switch it.Kind {
	case KindDownload:
		return t.m.Download(it.Bytes - t.got[it.ID])
	case KindInstall:
		return t.m.Install(it.InstalledMiB)
	case KindAUR:
		return t.m.AUR(it.BuildS)
	}
	return t.m.Other(it.ID, it.EstimateS)
}

// Feed consumes one event.
func (t *Tracker) Feed(e Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	switch e.Kind {
	case "start":
		t.state[e.Step] = "run"
		t.started[e.Step] = e.At
	case "bytes":
		t.got[e.Step] = e.Bytes
		t.m.ObserveBytes(e.Bytes, e.At)
	case "done", "skip", "fail":
		if t.state[e.Step] == "end" {
			return
		}
		t.state[e.Step] = "end"
		if st, ok := t.started[e.Step]; ok && e.Kind == "done" {
			took := e.At.Sub(st)
			t.elapsed[e.Step] = took
			for _, it := range t.items {
				if it.ID != e.Step {
					continue
				}
				switch it.Kind {
				case KindInstall:
					t.m.CalibrateInstall(it.InstalledMiB, took)
				case KindOther, KindAUR:
					t.m.RecordTiming(it.ID, took)
				case KindDownload:
					t.m.ResetDownload()
				}
			}
		}
	}
}

// Remaining is the raw remaining time at now.
func (t *Tracker) Remaining(now time.Time) time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.remainingLocked(now)
}

func (t *Tracker) remainingLocked(now time.Time) time.Duration {
	var sum time.Duration
	for _, it := range t.items {
		switch t.state[it.ID] {
		case "end":
			continue
		case "run":
			left := t.estimate(it) - now.Sub(t.started[it.ID])
			if left < 0 {
				left = 0
			}
			sum += left
		default:
			sum += t.estimate(it)
		}
	}
	return sum
}

// Tick returns the smoothed value to display; call once per second.
func (t *Tracker) Tick(now time.Time) time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sm.Update(t.remainingLocked(now))
}
