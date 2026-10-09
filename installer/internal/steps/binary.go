package steps

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"serpx/installer/internal/manifest"
)

// HTTPDownloader is the real Downloader: https only, bounded size.
type HTTPDownloader struct {
	Client  *http.Client
	MaxSize int64 // 0 = 1 GiB
}

func (d HTTPDownloader) Download(ctx context.Context, url, dst string) error {
	if !strings.HasPrefix(url, "https://") {
		return fmt.Errorf("refusing non-https url %q", url)
	}
	c := d.Client
	if c == nil {
		c = &http.Client{Timeout: 30 * time.Minute}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: HTTP %d", url, resp.StatusCode)
	}
	max := d.MaxSize
	if max == 0 {
		max = 1 << 30
	}
	tmp := dst + ".part"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	n, err := io.Copy(f, io.LimitReader(resp.Body, max+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n > max {
		err = fmt.Errorf("download %s: larger than %d bytes", url, max)
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// SHA256File returns the lowercase hex digest of a file.
func SHA256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// ExtractZipMember writes the member (matched by exact name, then by base
// name) of a zip to dst. The destination name is chosen by the caller, so a
// hostile archive cannot write elsewhere.
func ExtractZipMember(zipPath, member, dst string, maxSize int64) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	var found *zip.File
	for _, f := range zr.File {
		if f.Name == member {
			found = f
			break
		}
	}
	if found == nil {
		for _, f := range zr.File {
			if !f.FileInfo().IsDir() && path.Base(f.Name) == member {
				found = f
				break
			}
		}
	}
	if found == nil {
		return fmt.Errorf("member %q not found in %s", member, filepath.Base(zipPath))
	}
	rc, err := found.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o700)
	if err != nil {
		return err
	}
	n, err := io.Copy(out, io.LimitReader(rc, maxSize+1))
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil && n > maxSize {
		err = errors.New("archive member is too large")
	}
	return err
}

type binaryStep struct {
	Base
	B manifest.Binary
}

type binaryMarker struct {
	Version string `json:"version"`
	SHA256  string `json:"sha256"`
}

func (s binaryStep) marker(e *Env) string {
	return filepath.Join(e.StateDir, "binaries", s.B.Name+".json")
}

func (s binaryStep) skipped(ctx context.Context, e *Env) bool {
	for _, p := range s.B.SkipIfPkg {
		if e.ok(ctx, "pacman", "-Qq", p) {
			return true
		}
	}
	return false
}

func (s binaryStep) Check(ctx context.Context, e *Env) (bool, error) {
	if s.skipped(ctx, e) {
		return true, nil
	}
	b, err := readIfExists(s.marker(e))
	if err != nil || b == nil {
		return false, err
	}
	var m binaryMarker
	if json.Unmarshal(b, &m) != nil || m.Version != s.B.Version || m.SHA256 != s.B.SHA256 {
		return false, nil
	}
	_, err = os.Stat(e.Sys(e.Expand(s.B.Dest)))
	return err == nil, nil
}

func (s binaryStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	if done, _ := s.Check(ctx, e); done {
		return nil
	}
	if e.DL == nil {
		return errors.New("no downloader configured")
	}
	tmp := filepath.Join(e.StateDir, "tmp", "bin-"+s.B.Name)
	if err := os.RemoveAll(tmp); err != nil {
		return err
	}
	if err := os.MkdirAll(tmp, 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	arch := filepath.Join(tmp, "download")
	rep.Log("download " + s.B.URL)
	if err := e.DL.Download(ctx, s.B.URL, arch); err != nil {
		return err
	}
	got, err := SHA256File(arch)
	if err != nil {
		return err
	}
	if got != s.B.SHA256 {
		return fmt.Errorf("sha256 mismatch for %s: got %s, pinned %s (nothing was installed)", s.B.Name, got, s.B.SHA256)
	}
	payload := arch
	if s.B.ArchiveMember != "" {
		payload = filepath.Join(tmp, s.B.Name)
		if err := ExtractZipMember(arch, s.B.ArchiveMember, payload, 256<<20); err != nil {
			return err
		}
	}
	mode := s.B.Mode
	if mode == "" {
		mode = "0755"
	}
	dest := e.Expand(s.B.Dest)
	if _, err := e.exec(ctx, true, "install", "-m", mode, payload, dest); err != nil {
		return err
	}
	mb, _ := json.Marshal(binaryMarker{Version: s.B.Version, SHA256: s.B.SHA256})
	if err := os.MkdirAll(filepath.Dir(s.marker(e)), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.marker(e), mb, 0o600)
}

func (s binaryStep) Verify(ctx context.Context, e *Env) error {
	if s.skipped(ctx, e) {
		return nil
	}
	fi, err := os.Stat(e.Sys(e.Expand(s.B.Dest)))
	if err != nil {
		if e.Rootfs == "" || e.Rootfs == "/" {
			return err
		}
		return nil // fake root: the install command is a recorded no-op
	}
	if fi.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("%s is not executable", s.B.Dest)
	}
	return nil
}

func (s binaryStep) Rollback(ctx context.Context, e *Env) error {
	if _, err := os.Stat(s.marker(e)); err != nil {
		return nil // never installed by us
	}
	if err := e.best(ctx, true, "rm", "-f", e.Expand(s.B.Dest)); err != nil {
		return err
	}
	return os.Remove(s.marker(e))
}
