// Package backup exports and imports the user's data (settings, commands,
// servers lists, colors, notes) as serpantinum-backup-<host>-<date>.tar.zst.
// Secrets are NEVER put into the archive: the file set is an allow-list and
// settings.json is filtered. See plan 4.6.
package backup

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"serpx/installer/internal/journal"
	"serpx/installer/internal/run"
)

// FormatVersion of manifest.json.
const FormatVersion = 1

// Limits protect import from hostile archives.
const (
	maxFileBytes  = 128 << 20
	maxTotalBytes = 1 << 30
)

// StrippedKeys are removed from settings.json on export (personal data).
var StrippedKeys = []string{"general.location"}

// SecretsNotIncluded is written to manifest.json; import turns it into the
// "enter again" list.
var SecretsNotIncluded = []string{"gemini_key", "remnawave_url", "remnawave_token", "vpn_subscription", "servers/id_serp"}

// secretModule says which module owns a secret (for the "enter again" list).
var secretModule = map[string]string{
	"gemini_key": "ai-gemini", "remnawave_url": "servers", "remnawave_token": "servers",
	"vpn_subscription": "vpn", "servers/id_serp": "servers",
}

// secretKeyRe: any settings key that looks like a secret is dropped as a
// second line of defence (settings.json is not supposed to hold any).
var secretKeyRe = regexp.MustCompile(`(?i)(api[_-]?key|token|secret|passw(or)?d|passwd|subscription|private[_-]?key|credential)`)

// Roots are the base directories the data lives in.
type Roots struct {
	Config string // ~/.config
	State  string // ~/.local/state
	Notes  string // notes dir (default ~/Notes)
}

// Archive layout prefixes.
const (
	pfxConfig = "data/config/"
	pfxState  = "data/state/"
	pfxNotes  = "data/notes/"
)

func (r Roots) toTarget(arch string) (string, bool) {
	switch {
	case strings.HasPrefix(arch, pfxConfig):
		return filepath.Join(r.Config, filepath.FromSlash(arch[len(pfxConfig):])), true
	case strings.HasPrefix(arch, pfxState):
		return filepath.Join(r.State, filepath.FromSlash(arch[len(pfxState):])), true
	case strings.HasPrefix(arch, pfxNotes):
		return filepath.Join(r.Notes, filepath.FromSlash(arch[len(pfxNotes):])), true
	}
	return "", false
}

// FileEntry is one file in manifest.json.
type FileEntry struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}

// Manifest is manifest.json.
type Manifest struct {
	Format             int         `json:"format"`
	Build              string      `json:"build"`
	Created            string      `json:"created"`
	Host               string      `json:"host"`
	Modules            []string    `json:"modules"`
	Files              []FileEntry `json:"files"`
	Stripped           []string    `json:"stripped"`
	SecretsNotIncluded []string    `json:"secrets_not_included"`
}

// Compressor wraps the stream; the real one is zstd.
type Compressor interface {
	Compress(w io.Writer) (io.WriteCloser, error)
	Decompress(r io.Reader) (io.ReadCloser, error)
}

// Identity does no compression (tests, or when zstd is missing).
type Identity struct{}

type nopWC struct{ io.Writer }

func (nopWC) Close() error { return nil }

func (Identity) Compress(w io.Writer) (io.WriteCloser, error)  { return nopWC{w}, nil }
func (Identity) Decompress(r io.Reader) (io.ReadCloser, error) { return io.NopCloser(r), nil }

// Zstd runs the zstd binary (it is part of the base system).
type Zstd struct{ Bin string }

type procWC struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	err *bytes.Buffer
}

func (p *procWC) Write(b []byte) (int, error) { return p.in.Write(b) }
func (p *procWC) Close() error {
	_ = p.in.Close()
	if err := p.cmd.Wait(); err != nil {
		return fmt.Errorf("zstd: %w: %s", err, strings.TrimSpace(p.err.String()))
	}
	return nil
}

func (z Zstd) bin() string {
	if z.Bin != "" {
		return z.Bin
	}
	return "zstd"
}

func (z Zstd) Compress(w io.Writer) (io.WriteCloser, error) {
	cmd := exec.Command(z.bin(), "-q", "-c", "-T0")
	cmd.Stdout = w
	eb := &bytes.Buffer{}
	cmd.Stderr = eb
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &procWC{cmd: cmd, in: in, err: eb}, nil
}

type procRC struct {
	cmd *exec.Cmd
	out io.ReadCloser
	err *bytes.Buffer
}

func (p *procRC) Read(b []byte) (int, error) { return p.out.Read(b) }
func (p *procRC) Close() error {
	_, _ = io.Copy(io.Discard, p.out)
	if err := p.cmd.Wait(); err != nil {
		return fmt.Errorf("zstd: %w: %s", err, strings.TrimSpace(p.err.String()))
	}
	return nil
}

func (z Zstd) Decompress(r io.Reader) (io.ReadCloser, error) {
	cmd := exec.Command(z.bin(), "-q", "-d", "-c")
	cmd.Stdin = r
	eb := &bytes.Buffer{}
	cmd.Stderr = eb
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &procRC{cmd: cmd, out: out, err: eb}, nil
}

// ExportOptions for Export.
type ExportOptions struct {
	Roots      Roots
	Build      string   // e.g. 2.2.4-s3
	Modules    []string // installed modules
	Host       string
	Now        time.Time
	OutDir     string // where the archive goes
	Compressor Compressor
}

type collected struct {
	arch string
	data []byte
	mode uint32
}

// FileName returns serpantinum-backup-<host>-<YYYYmmdd-HHMM>.tar.zst
func FileName(host string, now time.Time) string {
	return fmt.Sprintf("serpantinum-backup-%s-%s.tar.zst", sanitizeHost(host), now.Format("20060102-1504"))
}

var hostBad = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func sanitizeHost(h string) string {
	h = hostBad.ReplaceAllString(h, "_")
	if h == "" {
		h = "host"
	}
	return h
}

// Export writes the archive and returns its path.
func Export(o ExportOptions) (string, error) {
	if o.Compressor == nil {
		o.Compressor = Zstd{}
	}
	if o.Now.IsZero() {
		o.Now = time.Now()
	}
	files, stripped, err := collect(o.Roots)
	if err != nil {
		return "", err
	}
	man := Manifest{
		Format: FormatVersion, Build: o.Build, Created: o.Now.Format(time.RFC3339), Host: o.Host,
		Modules: append([]string{}, o.Modules...), Stripped: stripped,
		SecretsNotIncluded: append([]string{}, SecretsNotIncluded...),
	}
	for _, f := range files {
		sum := sha256.Sum256(f.data)
		man.Files = append(man.Files, FileEntry{Path: f.arch, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(f.data)), Mode: f.mode})
	}
	mb, err := json.MarshalIndent(man, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(o.OutDir, 0o700); err != nil {
		return "", err
	}
	out := filepath.Join(o.OutDir, FileName(o.Host, o.Now))
	var raw bytes.Buffer
	zw, err := o.Compressor.Compress(&raw)
	if err != nil {
		return "", err
	}
	tw := tar.NewWriter(zw)
	put := func(name string, data []byte, mode int64) error {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(data)), ModTime: o.Now, Typeflag: tar.TypeReg}); err != nil {
			return err
		}
		_, err := tw.Write(data)
		return err
	}
	if err := put("manifest.json", mb, 0o644); err != nil {
		return "", err
	}
	for _, f := range files {
		if err := put(f.arch, f.data, int64(f.mode)); err != nil {
			return "", err
		}
	}
	if err := tw.Close(); err != nil {
		return "", err
	}
	if err := zw.Close(); err != nil {
		return "", err
	}
	if err := journal.WriteAtomic(out, raw.Bytes(), 0o600); err != nil {
		return "", err
	}
	return out, nil
}

// collect gathers the allow-listed files, sorted by archive path.
func collect(r Roots) ([]collected, []string, error) {
	var out []collected
	var stripped []string
	add := func(arch, src string, filter func([]byte) ([]byte, []string, error)) error {
		st, err := os.Lstat(src)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() {
			return nil // symlinks and specials are never followed
		}
		b, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		if filter != nil {
			var s []string
			if b, s, err = filter(b); err != nil {
				return fmt.Errorf("%s: %w", arch, err)
			}
			stripped = append(stripped, s...)
		}
		out = append(out, collected{arch: arch, data: b, mode: uint32(st.Mode().Perm())})
		return nil
	}
	cfg := filepath.Join(r.Config, "serpantinum")
	if err := add(pfxConfig+"serpantinum/settings.json", filepath.Join(cfg, "settings.json"), FilterSettings); err != nil {
		return nil, nil, err
	}
	cmds, _ := filepath.Glob(filepath.Join(cfg, "commands", "*.cmd.json"))
	for _, c := range cmds {
		if err := add(pfxConfig+"serpantinum/commands/"+filepath.Base(c), c, nil); err != nil {
			return nil, nil, err
		}
	}
	for _, n := range []string{"servers.toml", "commands.toml"} {
		if err := add(pfxConfig+"serpantinum/servers/"+n, filepath.Join(cfg, "servers", n), nil); err != nil {
			return nil, nil, err
		}
	}
	if err := add(pfxState+"serpantinum/x_colors.json", filepath.Join(r.State, "serpantinum", "x_colors.json"), nil); err != nil {
		return nil, nil, err
	}
	if r.Notes != "" {
		err := filepath.WalkDir(r.Notes, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				if p == r.Notes && errors.Is(err, fs.ErrNotExist) {
					return nil
				}
				return err
			}
			if d.Type().IsRegular() {
				rel, _ := filepath.Rel(r.Notes, p)
				return add(pfxNotes+filepath.ToSlash(rel), p, nil)
			}
			return nil
		})
		if err != nil {
			return nil, nil, err
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].arch < out[j].arch })
	sort.Strings(stripped)
	return out, stripped, nil
}

// FilterSettings removes StrippedKeys and anything that looks like a secret.
// It returns the cleaned JSON and the list of removed dotted paths.
func FilterSettings(in []byte) ([]byte, []string, error) {
	var doc map[string]any
	if err := json.Unmarshal(in, &doc); err != nil {
		return nil, nil, fmt.Errorf("settings.json is not valid JSON: %w", err)
	}
	var removed []string
	for _, k := range StrippedKeys {
		if deletePath(doc, strings.Split(k, ".")) {
			removed = append(removed, k)
		}
	}
	removed = append(removed, stripSecrets("", doc)...)
	if len(removed) == 0 {
		return in, nil, nil // nothing to strip: keep the user's bytes (key order, formatting) as they are
	}
	out, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, nil, err
	}
	return append(out, '\n'), removed, nil
}

func stripSecrets(prefix string, m map[string]any) []string {
	var removed []string
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		full := k
		if prefix != "" {
			full = prefix + "." + k
		}
		if secretKeyRe.MatchString(k) {
			delete(m, k)
			removed = append(removed, full)
			continue
		}
		if sub, ok := m[k].(map[string]any); ok {
			removed = append(removed, stripSecrets(full, sub)...)
		}
	}
	return removed
}

func deletePath(m map[string]any, p []string) bool {
	if len(p) == 1 {
		if _, ok := m[p[0]]; ok {
			delete(m, p[0])
			return true
		}
		return false
	}
	sub, ok := m[p[0]].(map[string]any)
	if !ok {
		return false
	}
	return deletePath(sub, p[1:])
}

func getPath(m map[string]any, p []string) (any, bool) {
	for i, k := range p {
		v, ok := m[k]
		if !ok {
			return nil, false
		}
		if i == len(p)-1 {
			return v, true
		}
		if m, ok = v.(map[string]any); !ok {
			return nil, false
		}
	}
	return nil, false
}

func setPath(m map[string]any, p []string, v any) {
	for _, k := range p[:len(p)-1] {
		sub, ok := m[k].(map[string]any)
		if !ok {
			sub = map[string]any{}
			m[k] = sub
		}
		m = sub
	}
	m[p[len(p)-1]] = v
}

// ---- import ----

// Writer is what fsx.FS provides: a transactional write with backup of
// foreign files.
type Writer interface {
	Write(tag, path string, data []byte, perm os.FileMode) error
}

// ImportOptions for Import.
type ImportOptions struct {
	Roots      Roots
	FS         Writer
	Tag        string   // fsx tag, e.g. "restore"
	Modules    []string // selected modules; nil = all (filters the "enter again" list)
	Compressor Compressor
	// After runs once the files are written (x_keybinds.sh generate). Optional.
	Runner run.Runner
	After  *run.Cmd
}

// ImportResult describes what happened.
type ImportResult struct {
	Manifest Manifest
	Restored []string // target paths
	Retype   []string // secrets the user has to enter again
	Warnings []string
}

// ReadManifest returns only manifest.json of an archive (first entry).
func ReadManifest(archive string, c Compressor) (*Manifest, error) {
	m, _, err := readArchive(archive, c, true)
	return m, err
}

func readArchive(archive string, c Compressor, onlyManifest bool) (*Manifest, map[string][]byte, error) {
	if c == nil {
		c = Zstd{}
	}
	f, err := os.Open(archive)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	zr, err := c.Decompress(f)
	if err != nil {
		return nil, nil, err
	}
	data := map[string][]byte{}
	var man *Manifest
	var total int64
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			_ = zr.Close()
			return nil, nil, fmt.Errorf("backup: broken archive: %w", err)
		}
		if h.Typeflag == tar.TypeDir {
			continue
		}
		if h.Typeflag != tar.TypeReg {
			_ = zr.Close()
			return nil, nil, fmt.Errorf("backup: %q: only regular files are allowed", h.Name)
		}
		if !safeName(h.Name) {
			_ = zr.Close()
			return nil, nil, fmt.Errorf("backup: unsafe path %q", h.Name)
		}
		if h.Size > maxFileBytes || total+h.Size > maxTotalBytes {
			_ = zr.Close()
			return nil, nil, errors.New("backup: archive too large")
		}
		total += h.Size
		b, err := io.ReadAll(io.LimitReader(tr, h.Size))
		if err != nil {
			_ = zr.Close()
			return nil, nil, err
		}
		if h.Name == "manifest.json" {
			man = &Manifest{}
			if err := json.Unmarshal(b, man); err != nil {
				_ = zr.Close()
				return nil, nil, fmt.Errorf("backup: bad manifest.json: %w", err)
			}
			if onlyManifest {
				_ = zr.Close()
				return man, nil, nil
			}
			continue
		}
		if _, dup := data[h.Name]; dup {
			_ = zr.Close()
			return nil, nil, fmt.Errorf("backup: duplicate entry %q", h.Name)
		}
		data[h.Name] = b
	}
	if err := zr.Close(); err != nil {
		return nil, nil, err
	}
	if man == nil {
		return nil, nil, errors.New("backup: manifest.json missing")
	}
	return man, data, nil
}

func safeName(n string) bool {
	if n == "" || strings.HasPrefix(n, "/") || strings.Contains(n, "\\") || strings.Contains(n, "\x00") {
		return false
	}
	return path.Clean(n) == n && !strings.HasPrefix(n, "../") && n != ".."
}

// Import verifies every file against manifest.json and only then writes.
func Import(ctx context.Context, archive string, o ImportOptions) (*ImportResult, error) {
	man, data, err := readArchive(archive, o.Compressor, false)
	if err != nil {
		return nil, err
	}
	if man.Format != FormatVersion {
		return nil, fmt.Errorf("backup: unsupported format %d", man.Format)
	}
	listed := map[string]FileEntry{}
	for _, fe := range man.Files {
		if !safeName(fe.Path) {
			return nil, fmt.Errorf("backup: unsafe path %q in manifest", fe.Path)
		}
		listed[fe.Path] = fe
		b, ok := data[fe.Path]
		if !ok {
			return nil, fmt.Errorf("backup: %s is listed but missing", fe.Path)
		}
		sum := sha256.Sum256(b)
		if hex.EncodeToString(sum[:]) != fe.SHA256 || int64(len(b)) != fe.Size {
			return nil, fmt.Errorf("backup: checksum mismatch: %s", fe.Path)
		}
	}
	for n := range data {
		if _, ok := listed[n]; !ok {
			return nil, fmt.Errorf("backup: %s is not listed in manifest", n)
		}
	}
	res := &ImportResult{Manifest: *man}
	names := make([]string, 0, len(listed))
	for n := range listed {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		target, ok := o.Roots.toTarget(n)
		if !ok {
			return nil, fmt.Errorf("backup: %s is outside data/", n)
		}
		b := data[n]
		if strings.HasSuffix(n, "serpantinum/settings.json") && n == pfxConfig+"serpantinum/settings.json" {
			b = keepStripped(target, b, man.Stripped)
		}
		perm := os.FileMode(listed[n].Mode) & 0o777
		if perm == 0 {
			perm = 0o644
		}
		if err := o.FS.Write(o.Tag, target, b, perm); err != nil {
			return res, fmt.Errorf("backup: write %s: %w", target, err)
		}
		res.Restored = append(res.Restored, target)
	}
	res.Retype = retypeList(man.SecretsNotIncluded, o.Modules)
	if o.Runner != nil && o.After != nil {
		if _, err := o.Runner.Run(ctx, *o.After); err != nil {
			res.Warnings = append(res.Warnings, "after-import command failed: "+err.Error())
		}
	}
	return res, nil
}

// keepStripped copies the stripped (personal) keys of the CURRENT settings
// into the restored one, so e.g. general.location is not lost.
func keepStripped(target string, restored []byte, stripped []string) []byte {
	cur, err := os.ReadFile(target)
	if err != nil {
		return restored
	}
	var cd, rd map[string]any
	if json.Unmarshal(cur, &cd) != nil || json.Unmarshal(restored, &rd) != nil {
		return restored
	}
	changed := false
	for _, k := range stripped {
		if !isStrippedKey(k) {
			continue
		}
		if v, ok := getPath(cd, strings.Split(k, ".")); ok {
			setPath(rd, strings.Split(k, "."), v)
			changed = true
		}
	}
	if !changed {
		return restored
	}
	out, err := json.MarshalIndent(rd, "", "  ")
	if err != nil {
		return restored
	}
	return append(out, '\n')
}

func isStrippedKey(k string) bool {
	for _, s := range StrippedKeys {
		if s == k {
			return true
		}
	}
	return false
}

func retypeList(notIncluded, modules []string) []string {
	sel := map[string]bool{}
	for _, m := range modules {
		sel[m] = true
	}
	var out []string
	for _, s := range notIncluded {
		mod, known := secretModule[s]
		if modules == nil || !known || sel[mod] {
			out = append(out, s)
		}
	}
	return out
}
