// Package plain is the line-by-line output of the installer (--plain, serial
// console, TERM=dumb, tests). The engine reports through the small Sink
// interface below, so this package does not depend on the engine; the TUI
// implements the same interface.
package plain

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/preflight"
)

// Sink is what the engine calls while running a plan.
type Sink interface {
	PlanStart(total int)
	StepStart(id, title string, index, total int)
	StepProgress(id string, percent int)
	StepLog(id, line string)
	StepDone(id string, skipped bool)
	StepFail(id string, err error)
	Finish(ok bool)
}

// Decision after a failed step.
type Decision int

const (
	Retry Decision = iota
	Skip
	Abort
)

func (d Decision) String() string { return [...]string{"retry", "skip", "abort"}[d] }

// Policy is run.on_error from my-setup.toml.
type Policy string

const (
	PolicyAsk          Policy = "ask"
	PolicySkipOptional Policy = "skip-optional"
	PolicyAbort        Policy = "abort"
)

// Options of the Printer.
type Options struct {
	Out     io.Writer
	In      io.Reader            // answers for prompts (nil = never interactive)
	Lang    string               // ru | en
	Yes     bool                 // --yes: confirmations are answered "yes"
	Policy  Policy               // empty = ask
	Verbose bool                 // print step log lines
	Color   bool                 // ANSI colors for ok/fail
	ETA     func() time.Duration // remaining time, optional
	Redact  func(string) string  // secret redaction, optional
	Now     func() time.Time
}

// Printer implements Sink and the interactive helpers.
type Printer struct {
	o       Options
	mu      sync.Mutex
	in      *bufio.Reader
	started map[string]time.Time
	lastPct map[string]int
	index   map[string]int
	total   int
}

// New returns a Printer.
func New(o Options) *Printer {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Lang != "en" {
		o.Lang = "ru"
	}
	if o.Policy == "" {
		o.Policy = PolicyAsk
	}
	p := &Printer{o: o, started: map[string]time.Time{}, lastPct: map[string]int{}, index: map[string]int{}}
	if o.In != nil {
		p.in = bufio.NewReader(o.In)
	}
	return p
}

func (p *Printer) tr(key string, a ...any) string {
	m := msgs[key]
	f := m.ru
	if p.o.Lang == "en" {
		f = m.en
	}
	return fmt.Sprintf(f, a...)
}

func (p *Printer) println(s string) {
	if p.o.Redact != nil {
		s = p.o.Redact(s)
	}
	fmt.Fprintln(p.o.Out, s)
}

func (p *Printer) paint(code, s string) string {
	if !p.o.Color {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func (p *Printer) etaSuffix() string {
	if p.o.ETA == nil {
		return ""
	}
	return "  (" + p.tr("eta", eta.Format(p.o.ETA(), p.o.Lang)) + ")"
}

func (p *Printer) prefix(id string) string {
	w := len(fmt.Sprint(p.total))
	return fmt.Sprintf("[%*d/%d]", w, p.index[id], p.total)
}

// ---- Sink ----

func (p *Printer) PlanStart(total int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.total = total
	p.println(p.tr("plan", total))
}

func (p *Printer) StepStart(id, title string, index, total int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.total, p.index[id] = total, index
	p.started[id] = p.o.Now()
	p.lastPct[id] = -1
	p.println(p.prefix(id) + " " + title + " ..." + p.etaSuffix())
}

func (p *Printer) StepProgress(id string, percent int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	// print every 10 %, never the same bucket twice
	b := percent / 10 * 10
	if b == 0 || b <= p.lastPct[id] {
		return
	}
	p.lastPct[id] = b
	p.println(fmt.Sprintf("%s   %d%%", p.prefix(id), b))
}

func (p *Printer) StepLog(id, line string) {
	if !p.o.Verbose {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.println("    | " + strings.TrimRight(line, "\r\n"))
}

func (p *Printer) took(id string) string {
	st, ok := p.started[id]
	if !ok {
		return ""
	}
	d := p.o.Now().Sub(st).Round(time.Second)
	return " (" + d.String() + ")"
}

func (p *Printer) StepDone(id string, skipped bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if skipped {
		p.println(p.prefix(id) + " " + p.paint("33", p.tr("skipped")) + p.took(id))
		return
	}
	p.println(p.prefix(id) + " " + p.paint("32", p.tr("ok")) + p.took(id))
}

func (p *Printer) StepFail(id string, err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.println(p.prefix(id) + " " + p.paint("31", p.tr("fail")) + ": " + err.Error())
}

func (p *Printer) Finish(ok bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if ok {
		p.println(p.paint("32", p.tr("finish.ok")))
	} else {
		p.println(p.paint("31", p.tr("finish.fail")))
	}
}

// ---- interactive helpers ----

// OnError decides what to do after a failed step. optional says whether the
// module may be skipped (non-core). With policy ask and no input it aborts.
func (p *Printer) OnError(ctx context.Context, id string, err error, optional bool) Decision {
	switch p.o.Policy {
	case PolicyAbort:
		return Abort
	case PolicySkipOptional:
		if optional {
			return Skip
		}
		return Abort
	}
	for {
		if p.in == nil || ctx.Err() != nil {
			return Abort
		}
		opts := "[r] " + p.tr("opt.retry")
		if optional {
			opts += "  [s] " + p.tr("opt.skip")
		}
		opts += "  [a] " + p.tr("opt.abort")
		p.mu.Lock()
		p.println(p.tr("ask.error", id) + " " + opts)
		p.mu.Unlock()
		line, rerr := p.in.ReadString('\n')
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "r", "retry", "п", "повторить":
			return Retry
		case "s", "skip", "с", "пропустить":
			if optional {
				return Skip
			}
		case "a", "abort", "о", "прервать":
			return Abort
		}
		if rerr != nil {
			return Abort
		}
	}
}

// Confirm asks a yes/no question; --yes answers yes, no input answers no.
func (p *Printer) Confirm(question string) bool {
	if p.o.Yes {
		p.mu.Lock()
		p.println(question + " " + p.tr("auto.yes"))
		p.mu.Unlock()
		return true
	}
	if p.in == nil {
		return false
	}
	p.mu.Lock()
	p.println(question + " " + p.tr("yn"))
	p.mu.Unlock()
	line, _ := p.in.ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes", "д", "да":
		return true
	}
	return false
}

// PrintPreflight shows the I1 screen as lines.
func (p *Printer) PrintPreflight(r preflight.Report) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.println(p.tr("preflight"))
	for _, c := range r.Checks {
		mark, col := " ok ", "32"
		switch c.Status {
		case preflight.Warn:
			mark, col = "warn", "33"
		case preflight.Fail:
			mark, col = "FAIL", "31"
		}
		p.println("  [" + p.paint(col, mark) + "] " + c.Text(p.o.Lang))
	}
}

// PrintRetype lists the secrets the user has to enter again after a restore.
func (p *Printer) PrintRetype(names []string) {
	if len(names) == 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.println(p.tr("retype"))
	for _, n := range names {
		p.println("  - " + n)
	}
}
