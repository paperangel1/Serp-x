// Package fsx performs installer file writes under a path allow-list, backs
// up foreign files before overwriting and can roll changes back.
// See plan section 4.5.
package fsx

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

// ErrNotAllowed: the path is outside the allowed roots.
var ErrNotAllowed = errors.New("fsx: path not allowed")

// Config for FS.
type Config struct {
	Allowed  []string                  // absolute files or directory roots
	StateDir string                    // holds owned-files.txt and backups/
	Run      string                    // run id: backups/<run>/
	OnBackup func(path, backup string) // optional journal hook
}

// Change is one recorded modification.
type Change struct {
	Tag     string `json:"tag"` // module or step id
	Path    string `json:"path"`
	Backup  string `json:"backup,omitempty"` // copy of the previous content
	Mode    uint32 `json:"mode,omitempty"`
	UID     int    `json:"uid,omitempty"`
	GID     int    `json:"gid,omitempty"`
	Created bool   `json:"created,omitempty"` // file did not exist before
	Undone  bool   `json:"undone,omitempty"`
}

// FS is the transaction object.
type FS struct {
	cfg     Config
	mu      sync.Mutex
	allowed []string
	changes []Change
}

// New loads owned-files.txt and the change log of this run (for resume).
func New(cfg Config) (*FS, error) {
	if cfg.StateDir == "" || cfg.Run == "" {
		return nil, errors.New("fsx: StateDir and Run required")
	}
	f := &FS{cfg: cfg}
	for _, a := range cfg.Allowed {
		if !filepath.IsAbs(a) {
			return nil, fmt.Errorf("fsx: allowed path not absolute: %s", a)
		}
		f.allowed = append(f.allowed, resolve(filepath.Clean(a)))
	}
	if err := os.MkdirAll(f.backupRoot(), 0o700); err != nil {
		return nil, err
	}
	if b, err := os.ReadFile(f.changesFile()); err == nil {
		sc := bufio.NewScanner(strings.NewReader(string(b)))
		for sc.Scan() {
			var c Change
			if json.Unmarshal(sc.Bytes(), &c) != nil {
				continue
			}
			if c.Undone { // supersedes the matching earlier entry
				for i := len(f.changes) - 1; i >= 0; i-- {
					o := f.changes[i]
					if !o.Undone && o.Tag == c.Tag && o.Path == c.Path && o.Backup == c.Backup && o.Created == c.Created {
						f.changes[i].Undone = true
						break
					}
				}
				continue
			}
			f.changes = append(f.changes, c)
		}
	}
	return f, nil
}

func (f *FS) backupRoot() string  { return filepath.Join(f.cfg.StateDir, "backups", f.cfg.Run) }
func (f *FS) changesFile() string { return filepath.Join(f.backupRoot(), "changes.jsonl") }
func (f *FS) ownedFile() string   { return filepath.Join(f.cfg.StateDir, "owned-files.txt") }

// resolve evaluates symlinks of the deepest existing ancestor, so a symlink
// inside an allowed root cannot point the write elsewhere.
func resolve(p string) string {
	rest := ""
	cur := p
	for {
		if r, err := filepath.EvalSymlinks(cur); err == nil {
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return p
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

// Check validates a path against the allow-list and returns its clean form.
func (f *FS) Check(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%w: relative %q", ErrNotAllowed, path)
	}
	p := filepath.Clean(path)
	r := resolve(p)
	for _, a := range f.allowed {
		if r == a || strings.HasPrefix(r, a+string(filepath.Separator)) {
			return p, nil
		}
	}
	return "", fmt.Errorf("%w: %s", ErrNotAllowed, path)
}

// Owned returns the set of paths recorded as ours.
func (f *FS) Owned() map[string]bool {
	m := map[string]bool{}
	b, err := os.ReadFile(f.ownedFile())
	if err != nil {
		return m
	}
	for _, l := range strings.Split(string(b), "\n") {
		if l != "" {
			m[l] = true
		}
	}
	return m
}

func (f *FS) addOwned(p string) error {
	if f.Owned()[p] {
		return nil
	}
	return appendLine(f.ownedFile(), []byte(p))
}

func (f *FS) dropOwned(p string) error {
	o := f.Owned()
	if !o[p] {
		return nil
	}
	delete(o, p)
	var keep []string
	for k := range o {
		keep = append(keep, k)
	}
	return writeAtomic(f.ownedFile(), []byte(strings.Join(keep, "\n")+"\n"), 0o600)
}

func appendLine(path string, line []byte) error {
	fd, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer fd.Close()
	if _, err := fd.Write(append(line, '\n')); err != nil {
		return err
	}
	return fd.Sync()
}

func writeAtomic(path string, data []byte, perm os.FileMode) error {
	tmp := path + ".tmp"
	fd, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	if _, err := fd.Write(data); err != nil {
		fd.Close()
		return err
	}
	if err := fd.Sync(); err != nil {
		fd.Close()
		return err
	}
	if err := fd.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (f *FS) record(c Change) error {
	b, _ := json.Marshal(c)
	if err := appendLine(f.changesFile(), b); err != nil {
		return err
	}
	f.changes = append(f.changes, c)
	return nil
}

func (f *FS) lastChange(p string) *Change {
	for i := len(f.changes) - 1; i >= 0; i-- {
		if f.changes[i].Path == p && !f.changes[i].Undone {
			return &f.changes[i]
		}
	}
	return nil
}

// prepare backs up a pre-existing foreign file (once per run) and records the
// change. Must be called with f.mu held.
func (f *FS) prepare(tag, p string) error {
	fi, err := os.Lstat(p)
	if errors.Is(err, os.ErrNotExist) {
		if f.lastChange(p) == nil {
			return f.record(Change{Tag: tag, Path: p, Created: true})
		}
		return nil
	}
	if err != nil {
		return err
	}
	if f.lastChange(p) != nil || f.Owned()[p] {
		return nil // already backed up this run, or ours: nothing foreign to save
	}
	if fi.IsDir() {
		return fmt.Errorf("fsx: %s is a directory", p)
	}
	c := Change{Tag: tag, Path: p, Mode: uint32(fi.Mode().Perm())}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		c.UID, c.GID = int(st.Uid), int(st.Gid)
	}
	dst := filepath.Join(f.backupRoot(), "files", p)
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(p)
		if err != nil {
			return err
		}
		if err := os.Symlink(target, dst); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
	} else if err := copyFile(p, dst, fi.Mode().Perm()); err != nil {
		return err
	}
	c.Backup = dst
	if err := f.record(c); err != nil {
		return err
	}
	if f.cfg.OnBackup != nil {
		f.cfg.OnBackup(p, dst)
	}
	return nil
}

func copyFile(src, dst string, perm os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm|0o200)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chmod(dst, perm)
}

// Write atomically writes a file. Foreign existing files are backed up first.
func (f *FS) Write(tag, path string, data []byte, perm os.FileMode) error {
	p, err := f.Check(path)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if err := f.prepare(tag, p); err != nil {
		return err
	}
	// If p is a symlink, replace the link itself (rename does), never its target.
	if err := writeAtomic(p, data, perm); err != nil {
		return err
	}
	return f.addOwned(p)
}

// Symlink replaces path with a symlink to target (foreign file is backed up).
func (f *FS) Symlink(tag, path, target string) error {
	p, err := f.Check(path)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	if err := f.prepare(tag, p); err != nil {
		return err
	}
	if cur, err := os.Readlink(p); err == nil && cur == target {
		return f.addOwned(p)
	}
	tmp := p + ".lnk"
	os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		os.Remove(tmp)
		return err
	}
	return f.addOwned(p)
}

// Remove deletes a file (backing up a foreign one first).
func (f *FS) Remove(tag, path string) error {
	p, err := f.Check(path)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err := f.prepare(tag, p); err != nil {
		return err
	}
	if err := os.Remove(p); err != nil {
		return err
	}
	return f.dropOwned(p)
}

// Changes returns a copy of the change log.
func (f *FS) Changes() []Change {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Change(nil), f.changes...)
}

// Rollback undoes the changes with the given tag in reverse order: backed-up
// files are restored, files we created are removed. Idempotent.
func (f *FS) Rollback(tag string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	var first error
	for i := len(f.changes) - 1; i >= 0; i-- {
		c := f.changes[i]
		if c.Tag != tag || c.Undone {
			continue
		}
		if err := f.undo(c); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		f.changes[i].Undone = true
		b, _ := json.Marshal(f.changes[i])
		appendLine(f.changesFile(), b) // later line supersedes; see New()
	}
	return first
}

func (f *FS) undo(c Change) error {
	switch {
	case c.Backup != "":
		fi, err := os.Lstat(c.Backup)
		if err != nil {
			return err
		}
		os.Remove(c.Path)
		if fi.Mode()&os.ModeSymlink != 0 {
			t, err := os.Readlink(c.Backup)
			if err != nil {
				return err
			}
			return os.Symlink(t, c.Path)
		}
		if err := copyFile(c.Backup, c.Path, os.FileMode(c.Mode)); err != nil {
			return err
		}
		os.Lchown(c.Path, c.UID, c.GID) // best effort (needs root for foreign owners)
		return f.dropOwned(c.Path)
	case c.Created:
		if err := os.Remove(c.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return f.dropOwned(c.Path)
	}
	return nil
}

// Backup saves a pre-existing foreign file (once per run) without changing
// it, so the caller can overwrite it with its own streaming copy. A missing
// file records a "created" change instead (rollback removes it).
func (f *FS) Backup(tag, path string) error {
	p, err := f.Check(path)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.prepare(tag, p)
}

// Own records path as written by us (so later runs do not treat it as foreign).
func (f *FS) Own(path string) error {
	p, err := f.Check(path)
	if err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.addOwned(p)
}
