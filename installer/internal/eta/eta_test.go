package eta

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 7, 19, 0, 0, 0, time.UTC)

func TestEWMA(t *testing.T) {
	m := New(4)
	m.ObserveBytes(0, t0)
	m.ObserveBytes(1_000_000, t0.Add(time.Second)) // first sample = 1 MB/s
	if got := m.Speed(); got != 1_000_000 {
		t.Fatalf("first sample: %v", got)
	}
	m.ObserveBytes(1_500_000, t0.Add(1500*time.Millisecond)) // < 1 s: ignored
	if m.Speed() != 1_000_000 {
		t.Fatal("sub-second sample must be ignored")
	}
	m.ObserveBytes(3_000_000, t0.Add(2*time.Second)) // 2 MB/s sample
	want := 0.3*2_000_000 + 0.7*1_000_000
	if d := m.Speed() - want; d > 1 || d < -1 {
		t.Fatalf("ewma %v want %v", m.Speed(), want)
	}
	if d := m.Download(14_000_000); d < 9*time.Second || d > 11*time.Second {
		t.Fatalf("download %v", d)
	}
}

func TestStartSpeedAndDefaults(t *testing.T) {
	m := New(0)
	if m.Download(int64(DefaultSpeed)) != time.Second {
		t.Fatal("default speed")
	}
	m.SetStartSpeed(2e6)
	if m.Download(4_000_000) != 2*time.Second {
		t.Fatal("start speed")
	}
	m.ObserveBytes(100, t0)
	m.ObserveBytes(50, t0.Add(2*time.Second)) // reset
	if m.Speed() != 2e6 {
		t.Fatal("negative delta must not change speed")
	}
}

func TestInstallAURMedian(t *testing.T) {
	m := New(8)
	if m.Install(1000) != 120*time.Second {
		t.Fatalf("install %v", m.Install(1000))
	}
	if m.AUR(200) != 100*time.Second {
		t.Fatalf("aur %v", m.AUR(200))
	}
	if m.Other("x", 30) != 30*time.Second {
		t.Fatal("estimate fallback")
	}
	for _, s := range []int{10, 50, 20} {
		m.RecordTiming("x", time.Duration(s)*time.Second)
	}
	if m.Other("x", 30) != 20*time.Second {
		t.Fatalf("median %v", m.Other("x", 30))
	}
	m.CalibrateInstall(100, 100*time.Second) // 1 s/MiB actual
	if m.Install(100) <= 12*time.Second {
		t.Fatal("calibration should raise k")
	}
}

func TestSmootherClamp(t *testing.T) {
	var s Smoother
	if s.Update(100*time.Second) != 100*time.Second {
		t.Fatal("first")
	}
	if got := s.Update(10 * time.Second); got != 75*time.Second {
		t.Fatalf("down %v", got)
	}
	if got := s.Update(1000 * time.Second); got != time.Duration(93.75*float64(time.Second)) {
		t.Fatalf("up %v", got)
	}
}

func TestFormat(t *testing.T) {
	cases := []struct {
		d    time.Duration
		lang string
		want string
	}{
		{30 * time.Second, "ru", "< 1 мин"},
		{59 * time.Second, "en", "< 1 min"},
		{7*time.Minute + 10*time.Second, "ru", "≈ 7 мин"},
		{7*time.Minute + 40*time.Second, "en", "≈ 8 min"},
		{83 * time.Minute, "ru", "≈ 1 ч 23 мин"},
	}
	for _, c := range cases {
		if got := Format(c.d, c.lang); got != c.want {
			t.Errorf("%v %s: %q want %q", c.d, c.lang, got, c.want)
		}
	}
}

func TestTrackerSyntheticTape(t *testing.T) {
	m := New(4)
	m.SetStartSpeed(1_000_000)
	items := []Item{
		{ID: "pkg.dl", Kind: KindDownload, Bytes: 20_000_000},
		{ID: "pkg.inst", Kind: KindInstall, InstalledMiB: 100},
		{ID: "aur.x", Kind: KindAUR, BuildS: 40},
		{ID: "deploy", Kind: KindOther, EstimateS: 10},
	}
	tr := NewTracker(m, items)
	// 20 s download + 12 s install + 40 s aur + 10 s = 82 s
	if got := tr.Remaining(t0); got != 82*time.Second {
		t.Fatalf("initial %v", got)
	}
	tr.Feed(Event{Step: "pkg.dl", Kind: "start", At: t0})
	tr.Feed(Event{Step: "pkg.dl", Kind: "bytes", At: t0, Bytes: 0})
	tr.Feed(Event{Step: "pkg.dl", Kind: "bytes", At: t0.Add(time.Second), Bytes: 4_000_000}) // 4 MB/s sample
	// speed = 1e6 -> sample 4e6 first sample but speed known => ewma 0.3*4e6+0.7*1e6=1.9e6
	rem := tr.Remaining(t0.Add(time.Second))
	if rem >= 82*time.Second || rem < 55*time.Second {
		t.Fatalf("after bytes %v", rem)
	}
	tr.Feed(Event{Step: "pkg.dl", Kind: "done", At: t0.Add(10 * time.Second)})
	tr.Feed(Event{Step: "pkg.inst", Kind: "start", At: t0.Add(10 * time.Second)})
	tr.Feed(Event{Step: "pkg.inst", Kind: "done", At: t0.Add(30 * time.Second)}) // 20 s real vs 12 est.
	if m.Install(100) <= 12*time.Second {
		t.Fatal("install not calibrated by the tape")
	}
	tr.Feed(Event{Step: "aur.x", Kind: "start", At: t0.Add(30 * time.Second)})
	tr.Feed(Event{Step: "aur.x", Kind: "skip", At: t0.Add(31 * time.Second)})
	if got := tr.Remaining(t0.Add(31 * time.Second)); got != 10*time.Second {
		t.Fatalf("left %v", got)
	}
	tr.Feed(Event{Step: "deploy", Kind: "start", At: t0.Add(31 * time.Second)})
	tr.Feed(Event{Step: "deploy", Kind: "done", At: t0.Add(36 * time.Second)})
	if tr.Remaining(t0.Add(36*time.Second)) != 0 {
		t.Fatal("must end at 0")
	}
	if len(m.Timings()["deploy"]) != 1 || len(m.Timings()["aur.x"]) != 0 {
		t.Fatalf("timings %v", m.Timings())
	}
	// Tick never jumps more than 25 %.
	tr2 := NewTracker(New(1), items)
	prev := tr2.Tick(t0)
	for i := 1; i < 5; i++ {
		cur := tr2.Tick(t0.Add(time.Duration(i) * time.Hour))
		if float64(cur) > 1.25*float64(prev)+1 || float64(cur) < 0.75*float64(prev)-1 {
			t.Fatalf("jump %v -> %v", prev, cur)
		}
		prev = cur
	}
}

func TestSave(t *testing.T) {
	m := New(2)
	m.RecordTiming("a", 5*time.Second)
	p := filepath.Join(t.TempDir(), "timings.json")
	if err := m.Save(p); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(p)
	var f timingsFile
	if err := json.Unmarshal(b, &f); err != nil || f.Timings["a"][0] != 5 {
		t.Fatalf("%v %s", err, b)
	}
}

func TestLoadRoundtrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "timings.json")
	m := New(2)
	m.RecordTiming("a", 7*time.Second)
	m.CalibrateInstall(100, 50*time.Second)
	if err := m.Save(p); err != nil {
		t.Fatal(err)
	}
	n := New(2)
	if err := n.Load(p); err != nil || n.Other("a", 1) != 7*time.Second || n.Install(100) != m.Install(100) {
		t.Fatalf("load: %v", err)
	}
	if err := New(1).Load(filepath.Join(t.TempDir(), "none")); err != nil {
		t.Fatal(err)
	}
}
