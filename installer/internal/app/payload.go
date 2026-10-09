package app

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"serpx/installer/internal/backup"
)

// validPayload: the directory has the shell code and the CLI.
func validPayload(dir string) bool {
	for _, p := range []string{"bin", "src"} {
		if st, err := os.Stat(filepath.Join(dir, p)); err != nil || !st.IsDir() {
			return false
		}
	}
	return true
}

// findPayload resolves --payload (directory or .tar.zst archive); without
// the flag it looks upwards from the binary and from the working directory
// for a clone of the repository (bin/ and src/ side by side).
func findPayload(flag, exe, cwd, unpackDir string, c backup.Compressor) (string, error) {
	if flag != "" {
		st, err := os.Stat(flag)
		if err != nil {
			return "", fmt.Errorf("payload %s: %w", flag, err)
		}
		if st.IsDir() {
			if !validPayload(flag) {
				return "", fmt.Errorf("payload %s: bin/ and src/ not found", flag)
			}
			return flag, nil
		}
		return unpackPayload(flag, unpackDir, c)
	}
	var starts []string
	if exe != "" {
		starts = append(starts, filepath.Dir(exe))
	}
	if cwd != "" {
		starts = append(starts, cwd)
	}
	for _, d := range starts {
		for dir := d; ; dir = filepath.Dir(dir) {
			if validPayload(dir) {
				return dir, nil
			}
			if dir == filepath.Dir(dir) {
				break
			}
		}
	}
	return "", errors.New("payload not found: pass --payload DIR (a clone of the repository or the unpacked release)")
}

// unpackPayload extracts a .tar.zst into dest (hostile paths are refused).
func unpackPayload(archive, dest string, c backup.Compressor) (string, error) {
	f, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	defer f.Close()
	rc, err := c.Decompress(f)
	if err != nil {
		return "", err
	}
	defer rc.Close()
	if err := os.RemoveAll(dest); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return "", err
	}
	tr := tar.NewReader(rc)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
		name := filepath.Clean(h.Name)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			return "", fmt.Errorf("payload archive: unsafe path %q", h.Name)
		}
		target := filepath.Join(dest, name)
		switch h.Typeflag {
		case tar.TypeDir:
			err = os.MkdirAll(target, 0o755)
		case tar.TypeReg:
			if err = os.MkdirAll(filepath.Dir(target), 0o755); err == nil {
				var w *os.File
				w, err = os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(h.Mode)&0o777|0o200)
				if err == nil {
					_, err = io.Copy(w, tr)
					if cerr := w.Close(); err == nil {
						err = cerr
					}
				}
			}
		case tar.TypeSymlink:
			link := h.Linkname
			if filepath.IsAbs(link) || strings.Contains(filepath.Clean(filepath.Join(filepath.Dir(name), link)), "..") {
				return "", fmt.Errorf("payload archive: unsafe link %q", h.Name)
			}
			if err = os.MkdirAll(filepath.Dir(target), 0o755); err == nil {
				err = os.Symlink(link, target)
			}
		}
		if err != nil {
			return "", err
		}
	}
	// a release archive may keep everything in one top directory
	if !validPayload(dest) {
		ents, _ := os.ReadDir(dest)
		if len(ents) == 1 && ents[0].IsDir() && validPayload(filepath.Join(dest, ents[0].Name())) {
			return filepath.Join(dest, ents[0].Name()), nil
		}
		return "", errors.New("payload archive: bin/ and src/ not found")
	}
	return dest, nil
}
