// Package eta estimates the remaining installation time (plan 4.7):
// download speed by EWMA, package install time by size, AUR builds by
// build_s * 4 / nproc, everything else by the median of earlier runs.
package eta

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"sort"
	"sync"
	"time"

	"serpx/installer/internal/journal"
)

// Defaults from the plan.
const (
	Alpha         = 0.3  // EWMA weight of the newest 1 s sample
	DefaultK      = 0.12 // seconds per MiB of installed size
	MaxJump       = 0.25 // displayed value may change at most 25 % per second
	DefaultSpeed  = 1 << 20
	maxTimingsPer = 20
)

// Model keeps the learned speeds and timings. Safe for concurrent use.
type Model struct {
	mu       sync.Mutex
	speed    float64 // bytes/s, 0 = unknown
	k        float64
	nproc    int
	timings  map[string][]float64 // step id -> seconds
	lastAt   time.Time
	lastByte int64
	haveLast bool
}

// New returns a model; nproc <= 0 means 1.
func New(nproc int) *Model {
	if nproc <= 0 {
		nproc = 1
	}
	return &Model{k: DefaultK, nproc: nproc, timings: map[string][]float64{}}
}

// SetStartSpeed sets the preflight measurement (bytes/s).
func (m *Model) SetStartSpeed(bps float64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if bps > 0 {
		m.speed = bps
	}
}

// Speed returns the current estimate in bytes/s (DefaultSpeed if unknown).
func (m *Model) Speed() float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.speedLocked()
}

func (m *Model) speedLocked() float64 {
	if m.speed <= 0 {
		return DefaultSpeed
	}
	return m.speed
}

// ObserveBytes feeds the cumulative downloaded byte count at time at.
// Samples closer than 1 s to the previous accepted one are ignored.
func (m *Model) ObserveBytes(total int64, at time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.haveLast {
		m.lastAt, m.lastByte, m.haveLast = at, total, true
		return
	}
	dt := at.Sub(m.lastAt).Seconds()
	if dt < 1 {
		return
	}
	delta := total - m.lastByte
	m.lastAt, m.lastByte = at, total
	if delta < 0 {
		return // counter reset (new file)
	}
	sample := float64(delta) / dt
	if m.speed <= 0 {
		m.speed = sample
		return
	}
	m.speed = Alpha*sample + (1-Alpha)*m.speed
}

// ResetDownload forgets the byte counter (a new transfer starts), keeping the speed.
func (m *Model) ResetDownload() {
	m.mu.Lock()
	m.haveLast = false
	m.mu.Unlock()
}

// Download estimates the time to fetch the remaining bytes.
func (m *Model) Download(remaining int64) time.Duration {
	if remaining <= 0 {
		return 0
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	return secs(float64(remaining) / m.speedLocked())
}

// Install estimates unpacking/installing installedMiB of packages.
func (m *Model) Install(installedMiB float64) time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	return secs(installedMiB * m.k)
}

// CalibrateInstall refines k from a real run (EWMA with the same alpha).
func (m *Model) CalibrateInstall(installedMiB float64, took time.Duration) {
	if installedMiB < 1 || took <= 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.k = Alpha*(took.Seconds()/installedMiB) + (1-Alpha)*m.k
}

// AUR estimates a build: build_s * 4 / nproc.
func (m *Model) AUR(buildS int) time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	return secs(float64(buildS) * 4 / float64(m.nproc))
}

// Other: median of recorded timings for the step, else estimateS.
func (m *Model) Other(stepID string, estimateS int) time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	if v := m.timings[stepID]; len(v) > 0 {
		return secs(median(v))
	}
	return secs(float64(estimateS))
}

// RecordTiming stores the fact for the next run.
func (m *Model) RecordTiming(stepID string, took time.Duration) {
	if took <= 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	v := append(m.timings[stepID], took.Seconds())
	if len(v) > maxTimingsPer {
		v = v[len(v)-maxTimingsPer:]
	}
	m.timings[stepID] = v
}

// Timings returns a copy for persistence.
func (m *Model) Timings() map[string][]float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string][]float64, len(m.timings))
	for k, v := range m.timings {
		out[k] = append([]float64(nil), v...)
	}
	return out
}

// timingsFile is the on-disk form of timings.json.
type timingsFile struct {
	V       int                  `json:"v"`
	K       float64              `json:"k_s_per_mib,omitempty"`
	Speed   float64              `json:"speed_bps,omitempty"`
	Timings map[string][]float64 `json:"timings"`
}

// Save writes timings.json atomically (after a run).
func (m *Model) Save(path string) error {
	m.mu.Lock()
	f := timingsFile{V: 1, K: m.k, Speed: m.speed, Timings: map[string][]float64{}}
	for k, v := range m.timings {
		f.Timings[k] = append([]float64(nil), v...)
	}
	m.mu.Unlock()
	return journal.WriteJSON(path, f)
}

func median(v []float64) float64 {
	c := append([]float64(nil), v...)
	sort.Float64s(c)
	n := len(c)
	if n%2 == 1 {
		return c[n/2]
	}
	return (c[n/2-1] + c[n/2]) / 2
}

func secs(s float64) time.Duration {
	if s < 0 || math.IsNaN(s) || math.IsInf(s, 0) {
		return 0
	}
	return time.Duration(s * float64(time.Second))
}

// Smoother limits how fast the displayed value changes.
type Smoother struct {
	shown time.Duration
	have  bool
}

// Update takes the raw remaining time (called once per second) and returns
// the value to display: it never moves by more than 25 % of the shown value
// per call.
func (s *Smoother) Update(raw time.Duration) time.Duration {
	if !s.have {
		s.shown, s.have = raw, true
		return raw
	}
	lo := time.Duration(float64(s.shown) * (1 - MaxJump))
	hi := time.Duration(float64(s.shown) * (1 + MaxJump))
	switch {
	case raw < lo:
		raw = lo
	case raw > hi:
		raw = hi
	}
	s.shown = raw
	return raw
}

// Format renders "≈ 7 мин" / "< 1 мин" (en: "~ 7 min" / "< 1 min").
func Format(d time.Duration, lang string) string {
	ru := lang != "en"
	if d < time.Minute {
		if ru {
			return "< 1 мин"
		}
		return "< 1 min"
	}
	mins := int(math.Round(d.Minutes()))
	if mins < 60 {
		if ru {
			return fmt.Sprintf("≈ %d мин", mins)
		}
		return fmt.Sprintf("≈ %d min", mins)
	}
	h, mm := mins/60, mins%60
	if ru {
		return fmt.Sprintf("≈ %d ч %d мин", h, mm)
	}
	return fmt.Sprintf("≈ %d h %d min", h, mm)
}

// Load reads timings.json written by Save; a missing file is not an error.
func (m *Model) Load(path string) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var f timingsFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil // corrupt history is just ignored
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if f.K > 0 {
		m.k = f.K
	}
	for k, v := range f.Timings {
		m.timings[k] = v
	}
	return nil
}
