package steps

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// FontsURL is upstream's (unpinned) Iosevka Nerd Font release.
const FontsURL = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Iosevka.zip"

func (e *Env) fontsDir() string { return filepath.Join(e.Home, ".local/share/fonts/IosevkaNerdFont") }

func hasTTF(dir string) bool {
	es, _ := os.ReadDir(dir)
	for _, d := range es {
		if strings.HasSuffix(strings.ToLower(d.Name()), ".ttf") {
			return true
		}
	}
	return false
}

type fontsStep struct{ Base }

func (fontsStep) Check(_ context.Context, e *Env) (bool, error) { return hasTTF(e.fontsDir()), nil }

// unzipTTF extracts the top-level *.ttf files (upstream: unzip, then mv *.ttf).
func unzipTTF(zipPath, dst string, budget int64) ([]string, error) {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	var names []string
	for _, f := range zr.File {
		if f.FileInfo().IsDir() || path.Dir(f.Name) != "." || !strings.HasSuffix(strings.ToLower(f.Name), ".ttf") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return names, err
		}
		out := filepath.Join(dst, path.Base(f.Name))
		w, err := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			rc.Close()
			return names, err
		}
		n, err := io.Copy(w, io.LimitReader(rc, budget+1))
		w.Close()
		rc.Close()
		if err == nil && n > budget {
			err = errors.New("fonts archive is too large")
		}
		if err != nil {
			return names, err
		}
		budget -= n
		names = append(names, out)
	}
	return names, nil
}

// Apply is upstream install_fonts. A failed download only warns (upstream).
func (fontsStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	target := e.fontsDir()
	if !hasTTF(target) {
		cache := filepath.Join(e.CacheDir(), "serpantinum-fonts")
		os.RemoveAll(cache)
		if err := os.MkdirAll(cache, 0o755); err != nil {
			return err
		}
		defer os.RemoveAll(cache)
		if err := os.MkdirAll(target, 0o755); err != nil {
			return err
		}
		zipPath := filepath.Join(cache, "Iosevka.zip")
		var derr error
		for i := 0; i < 3 && e.DL != nil; i++ { // curl --retry 3
			if derr = e.DL.Download(ctx, FontsURL, zipPath); derr == nil || ctx.Err() != nil {
				break
			}
		}
		if e.DL == nil || derr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			rep.Warn("Failed to download fonts, skipping...")
		} else if names, err := unzipTTF(zipPath, cache, 1<<30); err == nil || len(names) > 0 {
			for _, n := range names {
				if strings.Contains(filepath.Base(n), "Mono") {
					continue // rm -f *Mono*.ttf
				}
				dst := filepath.Join(target, filepath.Base(n))
				if err := e.FS.Backup("core.fonts", dst); err != nil {
					return err
				}
				if err := copyStream(n, dst, 0o644); err != nil {
					return err
				}
			}
			// upstream also removes Mono fonts that were already there
			if es, _ := os.ReadDir(target); es != nil {
				for _, d := range es {
					if strings.Contains(d.Name(), "Mono") && strings.HasSuffix(d.Name(), ".ttf") {
						os.Remove(filepath.Join(target, d.Name()))
					}
				}
			}
			sys := "/usr/share/fonts/IosevkaNerdFont"
			if err := e.best(ctx, true, "install", "-d", "-m", "755", sys); err != nil {
				return err
			}
			var files []string
			es, _ := os.ReadDir(target)
			for _, d := range es {
				if !d.IsDir() {
					files = append(files, filepath.Join(target, d.Name()))
				}
			}
			if len(files) > 0 {
				if err := e.best(ctx, true, "install", append([]string{"-m", "644", "-t", sys}, files...)...); err != nil {
					return err
				}
			}
		}
	}
	// find ~/.local/share/fonts: files 644, dirs 755
	root := filepath.Join(e.Home, ".local/share/fonts")
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			os.Chmod(p, 0o755)
		} else if d.Type().IsRegular() {
			os.Chmod(p, 0o644)
		}
		return nil
	})
	if e.lookPath("fc-cache") {
		return e.best(ctx, false, "fc-cache", "-f", root)
	}
	return nil
}

func (fontsStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback("core.fonts") }
