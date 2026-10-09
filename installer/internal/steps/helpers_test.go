package steps_test

import (
	"archive/zip"
	"bytes"
	"context"
	"testing"

	"serpx/installer/internal/run"
)

// hookRunner runs a side effect before delegating (e.g. "makepkg installs yay").
type hookRunner struct {
	run.Runner
	on map[string]func(run.Cmd)
}

func (h hookRunner) Run(ctx context.Context, c run.Cmd) (run.Result, error) {
	if fn := h.on[c.Name]; fn != nil {
		fn(c)
	}
	return h.Runner.Run(ctx, c)
}

func zipMany(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var b bytes.Buffer
	zw := zip.NewWriter(&b)
	for n, c := range files {
		w, _ := zw.Create(n)
		w.Write([]byte(c))
	}
	zw.Close()
	return b.Bytes()
}
