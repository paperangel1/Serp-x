package preflight

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"time"
)

func lookPath(f string) (string, error) { return exec.LookPath(f) }

// DefaultSpeedURL is a pacman mirror file used for the 1 MiB speed sample.
const DefaultSpeedURL = "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db"

// HTTPProbe is the real NetProbe.
type HTTPProbe struct {
	Client   *http.Client
	SpeedURL string
}

func (p HTTPProbe) client() *http.Client {
	if p.Client != nil {
		return p.Client
	}
	return &http.Client{Timeout: 15 * time.Second}
}

// Head does an HTTP HEAD; any status below 500 counts as reachable.
func (p HTTPProbe) Head(ctx context.Context, url string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return err
	}
	resp, err := p.client().Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode >= 500 {
		return fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return nil
}

// Speed downloads up to 1 MiB and returns bytes per second.
func (p HTTPProbe) Speed(ctx context.Context) (float64, error) {
	u := p.SpeedURL
	if u == "" {
		u = DefaultSpeedURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Range", "bytes=0-1048575")
	start := time.Now()
	resp, err := p.client().Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return 0, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	n, err := io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return 0, err
	}
	el := time.Since(start).Seconds()
	if el <= 0 || n == 0 {
		return 0, fmt.Errorf("no data")
	}
	return float64(n) / el, nil
}
