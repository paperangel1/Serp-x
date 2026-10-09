package steps

import (
	"context"
	"fmt"
	"io/fs"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
)

// WallpaperRepo is upstream's wallpaper collection.
const WallpaperRepo = "https://github.com/ilyamiro/shell-wallpapers.git"

var imageExts = map[string]bool{".jpg": true, ".jpeg": true, ".png": true, ".gif": true, ".webp": true}

func isImage(name string) bool { return imageExts[strings.ToLower(filepath.Ext(name))] }

func imagesIn(dir string, recursive bool) []string {
	var out []string
	filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if d.Name() == ".git" || (!recursive && p != dir) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type().IsRegular() && isImage(d.Name()) {
			out = append(out, p)
		}
		return nil
	})
	return out
}

// syncWallpaperRepo is the fetch/reset-or-clone block of install_wallpapers.
// It returns the directory holding the pictures ("" if nothing is available).
func (e *Env) syncWallpaperRepo(ctx context.Context, rep Reporter) (string, error) {
	clone := filepath.Join(e.CacheDir(), "serpantinum-wallpapers")
	synced := false
	if _, err := os.Stat(filepath.Join(clone, ".git")); err == nil {
		if e.ok(ctx, "git", "-C", clone, "fetch", "--depth", "1", "origin") {
			for _, ref := range []string{"FETCH_HEAD", "origin/HEAD", "origin/main", "origin/master"} {
				if e.ok(ctx, "git", "-C", clone, "reset", "--hard", ref) {
					synced = true
					break
				}
			}
		}
	}
	if !synced {
		if err := os.RemoveAll(clone); err != nil {
			return "", err
		}
		rep.Log("Cloning wallpapers repository...")
		if err := e.best(ctx, false, "git", "clone", "--depth", "1", WallpaperRepo, clone); err != nil {
			return "", err
		}
	}
	src := clone
	if fi, err := os.Stat(filepath.Join(clone, "images")); err == nil && fi.IsDir() {
		src = filepath.Join(clone, "images")
	}
	if fi, err := os.Stat(src); err != nil || !fi.IsDir() {
		return "", nil
	}
	return src, nil
}

func (e *Env) copyWallpaper(src, dir string) error {
	dst := filepath.Join(dir, filepath.Base(src))
	if sameFile(src, dst, sizeOf(src)) {
		return nil
	}
	if err := e.FS.Backup("wallpapers", dst); err != nil { // foreign copy saved, or "created" recorded
		return err
	}
	return copyStream(src, dst, 0o644)
}

// installWallpapers is upstream install_wallpapers(full_pack).
func (e *Env) installWallpapers(ctx context.Context, rep Reporter, full bool) error {
	dir := e.WallpaperDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	src, err := e.syncWallpaperRepo(ctx, rep)
	if err != nil || src == "" {
		return err
	}
	if full {
		imgs := imagesIn(src, true)
		if len(imgs) == 0 { // no pictures: copy every file except README/LICENSE/.git
			filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
				if err == nil && d.IsDir() && d.Name() == ".git" {
					return filepath.SkipDir
				}
				if err == nil && d.Type().IsRegular() && d.Name() != "README.md" && d.Name() != "LICENSE" {
					imgs = append(imgs, p)
				}
				return nil
			})
		}
		for i, p := range imgs {
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := e.copyWallpaper(p, dir); err != nil {
				return err
			}
			rep.Progress(float64(i+1)/float64(len(imgs)), fmt.Sprintf("%d/%d", i+1, len(imgs)))
		}
		return nil
	}
	if len(imagesIn(dir, false)) > 0 {
		return nil
	}
	imgs := imagesIn(src, true)
	r := rand.New(rand.NewSource(e.now().UnixNano()))
	r.Shuffle(len(imgs), func(i, j int) { imgs[i], imgs[j] = imgs[j], imgs[i] })
	if len(imgs) > 3 {
		imgs = imgs[:3]
	}
	for _, p := range imgs {
		if err := e.copyWallpaper(p, dir); err != nil {
			return err
		}
	}
	return nil
}

type wallpapersStep struct {
	Base
	Full bool
}

func (s wallpapersStep) Check(_ context.Context, e *Env) (bool, error) {
	if !s.Full {
		return len(imagesIn(e.WallpaperDir(), false)) > 0, nil
	}
	clone := filepath.Join(e.CacheDir(), "serpantinum-wallpapers")
	src := clone
	if fi, err := os.Stat(filepath.Join(clone, "images")); err == nil && fi.IsDir() {
		src = filepath.Join(clone, "images")
	}
	imgs := imagesIn(src, true)
	if len(imgs) == 0 {
		return false, nil
	}
	for _, p := range imgs {
		if _, err := os.Stat(filepath.Join(e.WallpaperDir(), filepath.Base(p))); err != nil {
			return false, nil
		}
	}
	return true, nil
}

func (s wallpapersStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	return e.installWallpapers(ctx, rep, s.Full)
}

func (s wallpapersStep) Verify(_ context.Context, e *Env) error {
	if s.Full && len(imagesIn(e.WallpaperDir(), false)) == 0 {
		return fmt.Errorf("no wallpapers in %s", e.WallpaperDir())
	}
	return nil
}

func (s wallpapersStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback("wallpapers") }
