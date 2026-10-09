package steps

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"serpx/installer/internal/journal"
)

// ExtraConfigs are copied into ~/.config on a non-update install (upstream EXTRA_CONFIGS).
var ExtraConfigs = []string{"kitty", "cava", "fastfetch"}

// compositorDir maps a compositor to its ~/.config directory name.
func compositorDir(comp string) string {
	switch comp {
	case "hyprland":
		return "hypr"
	}
	return comp // niri, sway and anything else keep their name
}

// srcFile is one file of a tree to deploy.
type srcFile struct {
	Rel     string // slash path relative to the tree root
	Abs     string
	Mode    fs.FileMode
	Symlink string // target if a symlink
}

// skipName: bytecode never goes to the install (plan G9).
func skipName(name string, isDir bool) bool {
	return name == "__pycache__" || name == ".git" || (!isDir && strings.HasSuffix(name, ".pyc"))
}

func listTree(root string) ([]srcFile, error) {
	var out []srcFile
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		if skipName(d.Name(), d.IsDir()) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			t, err := os.Readlink(p)
			if err != nil {
				return err
			}
			out = append(out, srcFile{Rel: rel, Abs: p, Symlink: t})
		case d.IsDir():
		case d.Type().IsRegular():
			fi, err := d.Info()
			if err != nil {
				return err
			}
			out = append(out, srcFile{Rel: rel, Abs: p, Mode: fi.Mode().Perm()})
		}
		return nil
	})
	return out, err
}

func nonEmptyDir(p string) bool {
	es, err := os.ReadDir(p)
	return err == nil && len(es) > 0
}

func sameFile(a, b string, size int64) bool {
	fb, err := os.Lstat(b)
	if err != nil || !fb.Mode().IsRegular() || fb.Size() != size {
		return false
	}
	fa, err := os.Open(a)
	if err != nil {
		return false
	}
	defer fa.Close()
	fbh, err := os.Open(b)
	if err != nil {
		return false
	}
	defer fbh.Close()
	ba, bb := make([]byte, 64<<10), make([]byte, 64<<10)
	for {
		na, ea := io.ReadFull(fa, ba)
		nb, eb := io.ReadFull(fbh, bb)
		if na != nb || !bytes.Equal(ba[:na], bb[:nb]) {
			return false
		}
		if ea != nil || eb != nil { // short read: both reached the end
			return true
		}
	}
}

func copyStream(src, dst string, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := dst + ".serp-tmp"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode|0o200)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst) // replaces a symlink at dst, never writes through it
}

func readList(p string) map[string]bool {
	m := map[string]bool{}
	f, err := os.Open(p)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		if l := sc.Text(); l != "" {
			m[l] = true
		}
	}
	return m
}

func writeList(p string, set map[string]bool) error {
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return journal.WriteAtomic(p, []byte(strings.Join(keys, "\n")+"\n"), 0o600)
}

// pruneEmpty removes empty directories under root (not root itself), deepest first.
func pruneEmpty(root string) {
	var dirs []string
	filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() && p != root {
			dirs = append(dirs, p)
		}
		return nil
	})
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, d := range dirs {
		os.Remove(d) // fails (ignored) unless empty
	}
}

// ---- deploy.code: mirror bin/ and src/ into ~/.local/share/serpantinum ----

// DeployListFile is the list of code files deployed by us (relative to TargetBase).
func (e *Env) deployedCodeList() string { return filepath.Join(e.StateDir, "deployed-code.txt") }

// DeployedCode returns the relative paths we deployed into TargetBase.
func (e *Env) DeployedCode() map[string]bool { return readList(e.deployedCodeList()) }

type deployCodeStep struct{ Base }

func (deployCodeStep) trees(e *Env) []struct{ Name, Src string } {
	return []struct{ Name, Src string }{{"bin", filepath.Join(e.Payload, "bin")}, {"src", filepath.Join(e.Payload, "src")}}
}

func execMode(rel string, m fs.FileMode) fs.FileMode {
	// upstream: chmod +x bin/* and src/scripts/**/*.sh
	if strings.HasPrefix(rel, "bin/") || (strings.HasPrefix(rel, "src/scripts/") && strings.HasSuffix(rel, ".sh")) {
		return m | 0o755
	}
	return m
}

func (s deployCodeStep) files(e *Env) ([]srcFile, error) {
	var all []srcFile
	for _, t := range s.trees(e) {
		if !nonEmptyDir(t.Src) {
			continue
		}
		fl, err := listTree(t.Src)
		if err != nil {
			return nil, err
		}
		for _, f := range fl {
			f.Rel = t.Name + "/" + f.Rel
			all = append(all, f)
		}
	}
	return all, nil
}

func (s deployCodeStep) Check(_ context.Context, e *Env) (bool, error) {
	fl, err := s.files(e)
	if err != nil {
		return false, err
	}
	if len(fl) == 0 {
		return false, errors.New("payload has no bin/ or src/")
	}
	prev := e.DeployedCode()
	cur := make(map[string]bool, len(fl))
	for _, f := range fl {
		cur[f.Rel] = true
	}
	for rel := range prev { // a previously deployed file the payload no longer has
		if !cur[rel] {
			if _, err := os.Lstat(filepath.Join(e.TargetBase(), filepath.FromSlash(rel))); err == nil {
				return false, nil
			}
		}
	}
	for _, f := range fl {
		dst := filepath.Join(e.TargetBase(), filepath.FromSlash(f.Rel))
		if f.Symlink != "" {
			if t, err := os.Readlink(dst); err != nil || t != f.Symlink {
				return false, nil
			}
			continue
		}
		fi, err := os.Lstat(dst)
		if err != nil || fi.Mode().Perm() != execMode(f.Rel, f.Mode) || !sameFile(f.Abs, dst, sizeOf(f.Abs)) {
			return false, nil
		}
		if !prev[f.Rel] {
			return false, nil
		}
	}
	return true, nil
}

func sizeOf(p string) int64 {
	if fi, err := os.Stat(p); err == nil {
		return fi.Size()
	}
	return -1
}

func (s deployCodeStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	fl, err := s.files(e)
	if err != nil {
		return err
	}
	if len(fl) == 0 {
		return errors.New("payload has no bin/ or src/")
	}
	if err := os.MkdirAll(e.BinDir(), 0o755); err != nil {
		return err
	}
	prev := e.DeployedCode()
	next := map[string]bool{}
	for i, f := range fl {
		if err := ctx.Err(); err != nil {
			return err
		}
		dst := filepath.Join(e.TargetBase(), filepath.FromSlash(f.Rel))
		if _, err := e.FS.Check(dst); err != nil {
			return err
		}
		next[f.Rel] = true
		if f.Symlink != "" {
			os.Remove(dst)
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			if err := os.Symlink(f.Symlink, dst); err != nil {
				return err
			}
			continue
		}
		mode := execMode(f.Rel, f.Mode)
		if fi, err := os.Lstat(dst); err == nil {
			if fi.Mode().IsRegular() && fi.Size() == sizeOf(f.Abs) && sameFile(f.Abs, dst, fi.Size()) {
				if fi.Mode().Perm() != mode {
					os.Chmod(dst, mode)
				}
				continue
			}
			if !prev[f.Rel] { // a foreign file is about to be replaced: keep a copy
				if err := e.FS.Backup("deploy.code", dst); err != nil {
					return err
				}
			}
		}
		if err := copyStream(f.Abs, dst, mode); err != nil {
			return err
		}
		if i%50 == 0 {
			rep.Progress(float64(i)/float64(len(fl)), f.Rel)
		}
	}
	// Mirror: remove only what an earlier deploy put there and the payload no
	// longer has. Foreign files stay (upstream did rm -rf on the whole dir).
	for rel := range prev {
		if !next[rel] {
			os.Remove(filepath.Join(e.TargetBase(), filepath.FromSlash(rel)))
		}
	}
	for _, t := range s.trees(e) {
		pruneEmpty(filepath.Join(e.TargetBase(), t.Name))
	}
	return writeList(e.deployedCodeList(), next)
}

func (deployCodeStep) Verify(_ context.Context, e *Env) error {
	if !nonEmptyDir(filepath.Join(e.TargetBase(), "src")) {
		return errors.New("src/ was not deployed")
	}
	return nil
}

func (deployCodeStep) Rollback(_ context.Context, e *Env) error {
	// Core cannot be skipped, so a rollback only returns foreign files that
	// were replaced. Files we created stay; uninstall removes them by the list.
	return e.FS.Rollback("deploy.code")
}

// ---- deploy.configs: kitty/cava/fastfetch and compositor configs ----

// DeployedConfigsList is the list of ~/.config files written by deploy.configs ($HOME-relative).
func (e *Env) deployedConfigsList() string {
	return filepath.Join(e.StateDir, "deployed-configs.txt")
}

// isUpdate is upstream's is_update (state current and not a reinstall).
func (e *Env) isUpdate() bool {
	return e.Opts.InstallState == StateCurrent && !e.Opts.Reinstall
}

type cfgTree struct {
	Name   string // log name
	Src    string // payload dir (or file)
	Dst    string // ~/.config/<x>
	Files  []srcFile
	Prune  bool // compositor: remove files not in the source
	Backup bool
}

func (s deployConfigsStep) trees(e *Env) ([]cfgTree, error) {
	var res []cfgTree
	for _, c := range ExtraConfigs {
		src := filepath.Join(e.Payload, "config", c)
		fi, err := os.Stat(src)
		if err != nil {
			continue
		}
		t := cfgTree{Name: c, Src: src, Dst: filepath.Join(e.Home, ".config", c)}
		if fi.IsDir() {
			if t.Files, err = listTree(src); err != nil {
				return nil, err
			}
		} else {
			t.Files = []srcFile{{Rel: ".", Abs: src, Mode: fi.Mode().Perm()}}
		}
		res = append(res, t)
	}
	for _, comp := range e.Opts.Compositors {
		var src string
		for _, d := range []string{"compositors", "compositor"} {
			if p := filepath.Join(e.Payload, d, comp); nonEmptyDir(p) {
				src = p
				break
			}
		}
		if src == "" {
			continue
		}
		t := cfgTree{Name: comp, Src: src, Dst: filepath.Join(e.Home, ".config", compositorDir(comp)), Prune: true, Backup: true}
		var err error
		if t.Files, err = listTree(src); err != nil {
			return nil, err
		}
		res = append(res, t)
	}
	return res, nil
}

type deployConfigsStep struct{ Base }

func (s deployConfigsStep) Check(_ context.Context, e *Env) (bool, error) {
	if e.isUpdate() && e.Mode != ModeRepair {
		return true, nil
	}
	trees, err := s.trees(e)
	if err != nil {
		return false, err
	}
	for _, t := range trees {
		for _, f := range t.Files {
			dst := t.Dst
			if f.Rel != "." {
				dst = filepath.Join(t.Dst, filepath.FromSlash(f.Rel))
			}
			if f.Symlink != "" {
				if l, err := os.Readlink(dst); err != nil || l != f.Symlink {
					return false, nil
				}
				continue
			}
			if e.Mode == ModeRepair {
				if _, err := os.Lstat(dst); err != nil {
					return false, nil
				}
			} else if !sameFile(f.Abs, dst, sizeOf(f.Abs)) {
				return false, nil
			}
		}
	}
	return true, nil
}

// protected files are never pruned: ours from other modules and anything recorded as owned.
func (s deployConfigsStep) protected(e *Env) map[string]bool {
	p := map[string]bool{}
	for k := range e.FS.Owned() {
		p[k] = true
	}
	if e.Set != nil && e.Sel != nil {
		for _, id := range e.Sel.Modules {
			if m, ok := e.Set.Get(id); ok {
				for _, uf := range m.UserFiles {
					p[e.Expand(uf)] = true
				}
			}
		}
	}
	return p
}

func (s deployConfigsStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	trees, err := s.trees(e)
	if err != nil {
		return err
	}
	repair := e.Mode == ModeRepair
	if e.isUpdate() && !repair {
		return nil
	}
	list := readList(e.deployedConfigsList())
	prot := s.protected(e)
	ts := e.now().Format("20060102_150405")
	for _, t := range trees {
		if err := ctx.Err(); err != nil {
			return err
		}
		if t.Backup && !repair && nonEmptyDir(t.Dst) {
			bdir := filepath.Join(e.Home, ".config", filepath.Base(t.Dst)+"_backup", "backup_"+ts)
			if _, err := os.Stat(bdir); err != nil { // one backup per second/run
				if err := copyDirAll(t.Dst, bdir); err != nil {
					return fmt.Errorf("backup of %s failed, nothing replaced: %w", t.Dst, err)
				}
			}
		}
		keep := map[string]bool{}
		for _, f := range t.Files {
			dst := t.Dst
			if f.Rel != "." {
				dst = filepath.Join(t.Dst, filepath.FromSlash(f.Rel))
			}
			keep[dst] = true
			if _, err := e.FS.Check(dst); err != nil {
				return err
			}
			if repair {
				if _, err := os.Lstat(dst); err == nil {
					continue // repair restores missing files, never overwrites
				}
			}
			if f.Symlink != "" {
				if err := e.FS.Symlink("deploy.configs", dst, f.Symlink); err != nil {
					return err
				}
			} else if !sameFile(f.Abs, dst, sizeOf(f.Abs)) {
				if _, err := os.Lstat(dst); err == nil && !list[relHome(e, dst)] && !t.Backup {
					if err := e.FS.Backup("deploy.configs", dst); err != nil {
						return err
					}
				}
				if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
					return err
				}
				if err := copyStream(f.Abs, dst, f.Mode); err != nil {
					return err
				}
			}
			list[relHome(e, dst)] = true
		}
		if t.Prune && !repair {
			filepath.WalkDir(t.Dst, func(p string, d fs.DirEntry, err error) error {
				if err != nil || d.IsDir() {
					return nil
				}
				if !keep[p] && !prot[p] {
					os.Remove(p)
					delete(list, relHome(e, p))
				}
				return nil
			})
			pruneEmpty(t.Dst)
		}
	}
	return writeList(e.deployedConfigsList(), list)
}

func relHome(e *Env, p string) string {
	r, err := filepath.Rel(e.Home, p)
	if err != nil {
		return p
	}
	return r
}

func (s deployConfigsStep) Rollback(_ context.Context, e *Env) error {
	return e.FS.Rollback("deploy.configs")
}

// copyDirAll is `cp -a src/. dst/` for regular files, dirs and symlinks.
func copyDirAll(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		out := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(out, 0o755)
		case d.Type()&fs.ModeSymlink != 0:
			t, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(t, out)
		case d.Type().IsRegular():
			fi, err := d.Info()
			if err != nil {
				return err
			}
			return copyStream(p, out, fi.Mode().Perm())
		}
		return nil
	})
}
