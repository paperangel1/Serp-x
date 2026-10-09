package app

import (
	"context"
	"io"
	"time"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/tui"
)

// PlainOptions of a line-by-line run.
type PlainOptions struct {
	Out     io.Writer
	In      io.Reader
	Lang    string
	Yes     bool
	Policy  plain.Policy
	Verbose bool
	Color   bool
}

// plainHandler adds the error decision, the confirmation and the ETA
// tracking to the Printer.
type plainHandler struct {
	*plain.Printer
	ctx  context.Context
	trk  *eta.Tracker
	now  func() time.Time
	opt  map[string]bool // id -> optional
	last string
}

func (p *plainHandler) Detail(string, tui.Detail) {}

func (p *plainHandler) StepStart(id, title string, i, n int) {
	if p.trk != nil {
		p.trk.Feed(eta.Event{Step: id, Kind: "start", At: p.now()})
	}
	p.Printer.StepStart(id, title, i, n)
}

func (p *plainHandler) StepDone(id string, skipped bool) {
	if p.trk != nil {
		k := "done"
		if skipped {
			k = "skip"
		}
		p.trk.Feed(eta.Event{Step: id, Kind: k, At: p.now()})
	}
	p.Printer.StepDone(id, skipped)
}

func (p *plainHandler) Decide(id string, err error, optional bool, _ []string) plain.Decision {
	return p.Printer.OnError(p.ctx, id, err, optional)
}

// RunPlain runs a request with line output. Policy comes from --yes /
// my-setup.toml run.on_error.
func (s *Service) RunPlain(ctx context.Context, req tui.Request, po PlainOptions) (tui.RunResult, error) {
	info, perr := s.Plan(ctx, req)
	var trk *eta.Tracker
	var remaining func() time.Duration
	if perr == nil {
		mdl := info.ETA
		if mdl == nil {
			mdl = eta.New(s.cfg.NProc)
		}
		if r := s.Report(); r != nil {
			mdl.SetStartSpeed(r.Facts.NetSpeedBps)
		}
		trk = eta.NewTracker(mdl, info.Items)
		remaining = func() time.Duration { return trk.Tick(s.cfg.Now()) }
	}
	pr := plain.New(plain.Options{Out: po.Out, In: po.In, Lang: po.Lang, Yes: po.Yes, Policy: po.Policy, Verbose: po.Verbose,
		Color: po.Color, ETA: remaining, Redact: s.log.Redact, Now: s.cfg.Now})
	h := &plainHandler{Printer: pr, ctx: ctx, trk: trk, now: s.cfg.Now}
	res, err := s.Run(ctx, req, h)
	if err == nil {
		pr.PrintRetype(res.Retype)
	}
	return res, err
}
