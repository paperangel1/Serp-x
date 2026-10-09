// Package journal implements the append-only installer journal (JSONL with
// per-line CRC32) and atomic file writes. See plan section 4.4.
package journal

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// Events.
const (
	EvStart  = "start"
	EvDone   = "done"
	EvFail   = "fail"
	EvSkip   = "skip"
	EvUndo   = "undo"
	EvFinish = "finish" // step is empty; run completed
)

const (
	FileJournal = "journal.jsonl"
	FilePlan    = "plan.json"
	FileTimings = "timings.json"
)

// Entry is one journal line.
type Entry struct {
	V    int            `json:"v"`
	Seq  int            `json:"seq"`
	Run  string         `json:"run"`
	TS   string         `json:"ts"`
	Step string         `json:"step"`
	Ev   string         `json:"ev"`
	Info map[string]any `json:"info,omitempty"`
	CRC  string         `json:"-"`
}

var secretKey = regexp.MustCompile(`(?i)(key|token|secret|pass|pwd|uuid)`)

// redact hides values of suspicious keys: secrets never go to the journal.
func redact(info map[string]any) map[string]any {
	if info == nil {
		return nil
	}
	out := make(map[string]any, len(info))
	for k, v := range info {
		if secretKey.MatchString(k) {
			out[k] = "set"
			continue
		}
		out[k] = v
	}
	return out
}

func crcHex(b []byte) string { return fmt.Sprintf("%08x", crc32.ChecksumIEEE(b)) }

// encode renders the entry as a line without trailing newline.
func encode(e Entry) ([]byte, error) {
	b, err := json.Marshal(e)
	if err != nil {
		return nil, err
	}
	// b ends with '}': splice the crc of everything before it.
	body := b[:len(b)-1]
	line := append([]byte{}, body...)
	line = append(line, []byte(`,"crc":"`+crcHex(b)+`"}`)...)
	return line, nil
}

var crcTail = regexp.MustCompile(`,"crc":"([0-9a-f]{8})"\}$`)

// decode verifies the CRC and parses the line.
func decode(line []byte) (Entry, error) {
	m := crcTail.FindSubmatchIndex(line)
	if m == nil {
		return Entry{}, errors.New("no crc")
	}
	orig := append(append([]byte{}, line[:m[0]]...), '}')
	if crcHex(orig) != string(line[m[2]:m[3]]) {
		return Entry{}, errors.New("bad crc")
	}
	var e Entry
	if err := json.Unmarshal(orig, &e); err != nil {
		return Entry{}, err
	}
	e.CRC = string(line[m[2]:m[3]])
	return e, nil
}

// Journal is a writer handle on journal.jsonl.
type Journal struct {
	mu  sync.Mutex
	dir string
	run string
	f   *os.File
	seq int
	now func() time.Time
}

// Open creates dir (0700), repairs the journal (truncating a torn or corrupt
// tail) and opens it for appending.
func Open(dir, run string) (*Journal, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, FileJournal)
	_, existed := statExists(path)
	entries, err := Repair(path)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if !existed {
		if err := syncDir(dir); err != nil {
			f.Close()
			return nil, err
		}
	}
	j := &Journal{dir: dir, run: run, f: f, now: time.Now}
	if n := len(entries); n > 0 {
		j.seq = entries[n-1].Seq
	}
	return j, nil
}

func statExists(p string) (os.FileInfo, bool) {
	fi, err := os.Stat(p)
	return fi, err == nil
}

// Append writes one event: single write + fsync.
func (j *Journal) Append(step, ev string, info map[string]any) error {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.seq++
	e := Entry{V: 1, Seq: j.seq, Run: j.run, TS: j.now().Format(time.RFC3339), Step: step, Ev: ev, Info: redact(info)}
	line, err := encode(e)
	if err != nil {
		j.seq--
		return err
	}
	line = append(line, '\n')
	if _, err := j.f.Write(line); err != nil {
		return err
	}
	return j.f.Sync()
}

func (j *Journal) Dir() string { return j.dir }

func (j *Journal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.f.Close()
}

// Read parses a journal file leniently: it stops at the first bad line and
// reports the byte offset of the end of the last good line.
func read(path string) (entries []Entry, good int64, size int64, err error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, 0, nil
	}
	if err != nil {
		return nil, 0, 0, err
	}
	size = int64(len(data))
	off := 0
	for off < len(data) {
		i := bytes.IndexByte(data[off:], '\n')
		if i < 0 {
			break // no newline: torn tail
		}
		e, derr := decode(data[off : off+i])
		if derr != nil {
			break
		}
		entries = append(entries, e)
		off += i + 1
	}
	return entries, int64(off), size, nil
}

// Read returns all good entries without modifying the file.
func Read(path string) ([]Entry, error) {
	e, _, _, err := read(path)
	return e, err
}

// Repair truncates the file to the last good line and returns the entries.
func Repair(path string) ([]Entry, error) {
	e, good, size, err := read(path)
	if err != nil {
		return nil, err
	}
	if good < size {
		if err := os.Truncate(path, good); err != nil {
			return nil, err
		}
	}
	return e, nil
}

// States maps step -> last event.
func States(entries []Entry) map[string]string {
	m := map[string]string{}
	for _, e := range entries {
		if e.Step != "" {
			m[e.Step] = e.Ev
		}
	}
	return m
}

// Finished reports whether a finish event exists.
func Finished(entries []Entry) bool {
	for _, e := range entries {
		if e.Ev == EvFinish {
			return true
		}
	}
	return false
}

// NeedsResume: plan.json exists and the journal has no finish event.
func NeedsResume(dir string) (bool, error) {
	if _, err := os.Stat(filepath.Join(dir, FilePlan)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	e, err := Read(filepath.Join(dir, FileJournal))
	if err != nil {
		return false, err
	}
	return !Finished(e), nil
}

// StepFinished: done or skipped steps need no re-run on resume; everything else
// (start without done, fail, unseen) must be re-checked.
func StepFinished(st map[string]string, step string) bool {
	return st[step] == EvDone || st[step] == EvSkip
}

// NewRunID returns an id like 20261007-1904 (with seconds if needed to be unique by caller).
func NewRunID(t time.Time) string { return t.Format("20060102-1504") }

// WriteAtomic writes data via tmp -> fsync -> rename -> fsync dir.
func WriteAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	cleanup := func() { os.Remove(tmp) }
	if _, err := f.Write(data); err != nil {
		f.Close()
		cleanup()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		cleanup()
		return err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		cleanup()
		return err
	}
	return syncDir(dir)
}

func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// WriteJSON is WriteAtomic for a value (mode 0600).
func WriteJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return WriteAtomic(path, append(b, '\n'), 0o600)
}
