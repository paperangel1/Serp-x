package backup

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"serpx/installer/internal/journal"
)

// KeepSecretCopies is how many local secret copies survive.
const KeepSecretCopies = 2

// AutoOptions for AutoBackup (before reinstall / uninstall).
type AutoOptions struct {
	ExportOptions
	Run      string // run id
	ShareDir string // ~/.local/share/serpantinum-installer
}

// AutoResult is what AutoBackup produced.
type AutoResult struct {
	Archive     string
	SecretsCopy string // "" if there were no secrets
}

// secretFiles lists what the local copy holds (relative to Roots.Config).
func secretFiles(cfgRoot string) ([]string, error) {
	var out []string
	sdir := filepath.Join(cfgRoot, "serpantinum", "secrets")
	err := filepath.WalkDir(sdir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.Type().IsRegular() {
			rel, _ := filepath.Rel(cfgRoot, p)
			out = append(out, rel)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(filepath.Join(cfgRoot, "serpantinum", "servers", "id_serp")); err == nil {
		out = append(out, filepath.Join("serpantinum", "servers", "id_serp"))
	}
	sort.Strings(out)
	return out, nil
}

// AutoBackup writes the normal archive to OutDir and a local secrets.tar
// (dir 700, file 600) that never leaves the machine; keeps the last two.
func AutoBackup(o AutoOptions) (*AutoResult, error) {
	arch, err := Export(o.ExportOptions)
	if err != nil {
		return nil, err
	}
	res := &AutoResult{Archive: arch}
	files, err := secretFiles(o.Roots.Config)
	if err != nil {
		return res, err
	}
	if len(files) == 0 {
		return res, nil
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, rel := range files {
		b, err := os.ReadFile(filepath.Join(o.Roots.Config, rel))
		if err != nil {
			return res, err
		}
		if err := tw.WriteHeader(&tar.Header{Name: filepath.ToSlash(rel), Mode: 0o600, Size: int64(len(b)), Typeflag: tar.TypeReg, ModTime: o.Now}); err != nil {
			return res, err
		}
		if _, err := tw.Write(b); err != nil {
			return res, err
		}
	}
	if err := tw.Close(); err != nil {
		return res, err
	}
	bdir := filepath.Join(o.ShareDir, "backups")
	dir := filepath.Join(bdir, o.Run)
	for _, d := range []string{o.ShareDir, bdir, dir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return res, err
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return res, err
		}
	}
	p := filepath.Join(dir, "secrets.tar")
	if err := journal.WriteAtomic(p, buf.Bytes(), 0o600); err != nil {
		return res, err
	}
	res.SecretsCopy = p
	return res, pruneSecretCopies(bdir)
}

func secretCopies(bdir string) []string {
	ents, _ := os.ReadDir(bdir)
	var out []string
	for _, e := range ents {
		p := filepath.Join(bdir, e.Name(), "secrets.tar")
		if e.IsDir() {
			if _, err := os.Stat(p); err == nil {
				out = append(out, p)
			}
		}
	}
	sort.Strings(out) // run ids sort chronologically
	return out
}

func pruneSecretCopies(bdir string) error {
	c := secretCopies(bdir)
	for len(c) > KeepSecretCopies {
		if err := os.Remove(c[0]); err != nil {
			return err
		}
		_ = os.Remove(filepath.Dir(c[0])) // only if empty
		c = c[1:]
	}
	return nil
}

// RestoreSecretsIfEmpty puts the newest local copy back when secrets/ is
// missing or empty after a reinstall. Returns the restored paths.
func RestoreSecretsIfEmpty(ctx context.Context, roots Roots, shareDir string, w Writer, tag string) ([]string, error) {
	sdir := filepath.Join(roots.Config, "serpantinum", "secrets")
	if ents, err := os.ReadDir(sdir); err == nil && len(ents) > 0 {
		return nil, nil
	}
	copies := secretCopies(filepath.Join(shareDir, "backups"))
	if len(copies) == 0 {
		return nil, nil
	}
	f, err := os.Open(copies[len(copies)-1])
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var restored []string
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if err != nil {
			break
		}
		if h.Typeflag != tar.TypeReg || !safeName(h.Name) || !strings.HasPrefix(h.Name, "serpantinum/") {
			return restored, fmt.Errorf("backup: bad entry %q in secrets copy", h.Name)
		}
		var b bytes.Buffer
		if _, err := b.ReadFrom(tr); err != nil {
			return restored, err
		}
		target := filepath.Join(roots.Config, filepath.FromSlash(h.Name))
		if err := w.Write(tag, target, b.Bytes(), 0o600); err != nil {
			return restored, err
		}
		restored = append(restored, target)
	}
	if err := os.Chmod(sdir, 0o700); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return restored, err
	}
	_ = ctx
	return restored, nil
}

// RemoveSecretCopies deletes all local secret copies (only after the user
// confirmed "uninstall and my data").
func RemoveSecretCopies(shareDir string) error {
	return os.RemoveAll(filepath.Join(shareDir, "backups"))
}
