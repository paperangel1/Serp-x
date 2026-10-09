package plain

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/preflight"
)

var t0 = time.Date(2026, 10, 7, 19, 0, 0, 0, time.UTC)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newP(o Options) (*Printer, *bytes.Buffer, *clock) {
	var b bytes.Buffer
	c := &clock{t: t0}
	o.Out, o.Now = &b, c.now
	return New(o), &b, c
}

func TestSinkFlow(t *testing.T) {
	p, out, clk := newP(Options{Lang: "en"})
	p.PlanStart(12)
	p.StepStart("pkg.repo", "Install packages", 3, 12)
	p.StepProgress("pkg.repo", 5)  // below 10 %: silent
	p.StepProgress("pkg.repo", 37) // 30
	p.StepProgress("pkg.repo", 39) // same bucket: silent
	p.StepProgress("pkg.repo", 250)
	clk.t = t0.Add(75 * time.Second)
	p.StepDone("pkg.repo", false)
	p.StepStart("aur.x", "AUR x", 4, 12)
	p.StepDone("aur.x", true)
	p.StepStart("vpn", "VPN", 5, 12)
	p.StepFail("vpn", errors.New("boom"))
	p.Finish(false)
	want := []string{
		"Plan: 12 steps",
		"[ 3/12] Install packages ...",
		"[ 3/12]   30%",
		"[ 3/12]   100%",
		"[ 3/12] done (1m15s)",
		"[ 4/12] AUR x ...",
		"[ 4/12] skipped (0s)",
		"[ 5/12] VPN ...",
		"[ 5/12] FAILED: boom",
	}
	got := strings.Split(strings.TrimSpace(out.String()), "\n")
	for i, w := range want {
		if got[i] != w {
			t.Errorf("line %d: %q want %q", i, got[i], w)
		}
	}
	if !strings.Contains(got[len(got)-1], "--resume") {
		t.Fatal(got[len(got)-1])
	}
}

func TestVerboseColorETARedact(t *testing.T) {
	p, out, _ := newP(Options{Lang: "ru", Verbose: true, Color: true,
		ETA:    func() time.Duration { return 7 * time.Minute },
		Redact: func(s string) string { return strings.ReplaceAll(s, "AIzaFAKE", "***") }})
	p.StepStart("a", "Шаг", 1, 2)
	p.StepLog("a", "key=AIzaFAKE\r\n")
	p.StepDone("a", false)
	s := out.String()
	if !strings.Contains(s, "осталось "+eta.Format(7*time.Minute, "ru")) || !strings.Contains(s, "    | key=***") ||
		strings.Contains(s, "AIzaFAKE") || !strings.Contains(s, "\x1b[32mготово\x1b[0m") {
		t.Fatalf("%q", s)
	}
	q, o2, _ := newP(Options{})
	q.StepStart("a", "x", 1, 1)
	q.StepLog("a", "hidden")
	q.StepDone("a", false)
	if strings.Contains(o2.String(), "hidden") || strings.Contains(o2.String(), "\x1b") {
		t.Fatal("log/color leaked")
	}
}

func TestOnErrorPolicies(t *testing.T) {
	ctx := context.Background()
	e := errors.New("x")
	p, _, _ := newP(Options{Policy: PolicyAbort})
	if p.OnError(ctx, "s", e, true) != Abort {
		t.Fatal("abort")
	}
	p, _, _ = newP(Options{Policy: PolicySkipOptional})
	if p.OnError(ctx, "s", e, true) != Skip || p.OnError(ctx, "s", e, false) != Abort {
		t.Fatal("skip-optional")
	}
	p, _, _ = newP(Options{})
	if p.OnError(ctx, "s", e, true) != Abort {
		t.Fatal("ask without input aborts")
	}
}

func TestOnErrorAsk(t *testing.T) {
	ctx := context.Background()
	e := errors.New("x")
	p, out, _ := newP(Options{Lang: "en", In: strings.NewReader("???\nr\n")})
	if p.OnError(ctx, "vpn", e, true) != Retry {
		t.Fatal("retry after junk")
	}
	if strings.Count(out.String(), "Step vpn failed") != 2 || !strings.Contains(out.String(), "[s] skip module") {
		t.Fatalf("%q", out.String())
	}
	// core: skip is not offered nor accepted
	p, out, _ = newP(Options{Lang: "en", In: strings.NewReader("s\na\n")})
	if p.OnError(ctx, "core", e, false) != Abort || strings.Contains(out.String(), "skip module") {
		t.Fatalf("%q", out.String())
	}
	p, _, _ = newP(Options{Lang: "ru", In: strings.NewReader("с\n")})
	if p.OnError(ctx, "x", e, true) != Skip {
		t.Fatal("ru skip")
	}
	p, _, _ = newP(Options{In: strings.NewReader("")})
	if p.OnError(ctx, "x", e, true) != Abort {
		t.Fatal("EOF aborts")
	}
}

func TestConfirm(t *testing.T) {
	p, out, _ := newP(Options{Lang: "en", Yes: true})
	if !p.Confirm("Go?") || !strings.Contains(out.String(), "yes (--yes)") {
		t.Fatal("--yes")
	}
	p, _, _ = newP(Options{In: strings.NewReader("да\n")})
	if !p.Confirm("?") {
		t.Fatal("да")
	}
	p, _, _ = newP(Options{In: strings.NewReader("\n")})
	if p.Confirm("?") {
		t.Fatal("default no")
	}
	p, _, _ = newP(Options{})
	if p.Confirm("?") {
		t.Fatal("no input: no")
	}
}

func TestPreflightAndRetype(t *testing.T) {
	p, out, _ := newP(Options{Lang: "en"})
	p.PrintPreflight(preflight.Report{Checks: []preflight.Check{
		{ID: "root", Status: preflight.OK, Code: "root.ok"},
		{ID: "disk", Status: preflight.Fail, Code: "disk.low", Args: []any{"/: 1/2 MiB"}},
		{ID: "gpu", Status: preflight.Warn, Code: "gpu.nvidia"},
	}})
	p.PrintRetype([]string{"gemini_key", "servers/id_serp"})
	p.PrintRetype(nil)
	s := out.String()
	for _, w := range []string{"[ ok ] Running as a normal user", "[FAIL] Not enough disk space: /: 1/2 MiB", "[warn] NVIDIA found", "  - gemini_key", "Enter again"} {
		if !strings.Contains(s, w) {
			t.Errorf("missing %q in\n%s", w, s)
		}
	}
}

func TestMessagesComplete(t *testing.T) {
	for k, m := range msgs {
		if m.ru == "" || m.en == "" || strings.Count(m.ru, "%") != strings.Count(m.en, "%") {
			t.Errorf("%s", k)
		}
	}
}

var _ Sink = (*Printer)(nil)
