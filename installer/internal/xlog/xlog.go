// Package xlog writes log lines in the same format as
// src/scripts/custom/xlog/xlog.py so that `serpantinum-x logs installer`
// and `report` work on them:
//
//	2026-10-07T19:05:02+03:00 INFO installer message key=value
//
// Files: $SERPANTINUM_LOG_DIR or $XDG_STATE_HOME/serpantinum/logs (dir 0700,
// files 0600), rotated at 512 KB keeping 3 files. Every line is redacted
// before it touches the disk. Logging never fails the caller.
package xlog

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// Levels.
const (
	Debug = 10
	Info  = 20
	Warn  = 30
	Error = 40
)

var levelNames = map[string]int{"debug": Debug, "info": Info, "warn": Warn, "error": Error}

// Redacted is what secrets are replaced with.
const Redacted = "«redacted»"

const (
	defaultMaxBytes = 512 * 1024
	keep            = 3
)

var reModule = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,23}$`)

// Dir returns the log directory for the given environment lookup.
func Dir(getenv func(string) string) string {
	if d := getenv("SERPANTINUM_LOG_DIR"); d != "" {
		return d
	}
	state := getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(getenv("HOME"), ".local", "state")
	}
	return filepath.Join(state, "serpantinum", "logs")
}

// Logger is safe for concurrent use.
type Logger struct {
	module    string
	dir       string
	maxBytes  int64
	now       func() time.Time
	threshold int

	mu      sync.Mutex
	secrets []string
}

// Option configures a Logger.
type Option func(*Logger)

// WithMaxBytes overrides the rotation size (tests).
func WithMaxBytes(n int64) Option { return func(l *Logger) { l.maxBytes = n } }

// WithClock injects the clock (tests).
func WithClock(f func() time.Time) Option { return func(l *Logger) { l.now = f } }

// WithDir overrides the log directory.
func WithDir(d string) Option { return func(l *Logger) { l.dir = d } }

// New creates a logger for module. Directory and level come from the
// environment (getenv), like xlog.py: XLOG_LEVEL env or <dir>/.level file.
func New(module string, getenv func(string) string, opts ...Option) *Logger {
	if !reModule.MatchString(module) {
		module = "misc"
	}
	l := &Logger{module: module, dir: Dir(getenv), maxBytes: defaultMaxBytes, now: time.Now}
	for _, o := range opts {
		o(l)
	}
	name := strings.ToLower(strings.TrimSpace(getenv("XLOG_LEVEL")))
	if _, ok := levelNames[name]; !ok {
		if b, err := os.ReadFile(filepath.Join(l.dir, ".level")); err == nil {
			name = strings.ToLower(strings.TrimSpace(string(b)))
		}
	}
	if v, ok := levelNames[name]; ok {
		l.threshold = v
	} else {
		l.threshold = Info
	}
	return l
}

// Path returns the current log file.
func (l *Logger) Path() string { return filepath.Join(l.dir, l.module+".log") }

// AddSecret registers a value that must never reach the disk. Short values
// (< 4 bytes) are ignored to avoid shredding the log.
func (l *Logger) AddSecret(s string) {
	if len(s) < 4 {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, x := range l.secrets {
		if x == s {
			return
		}
	}
	l.secrets = append(l.secrets, s)
	// longest first so a secret that contains another is replaced whole
	sort.Slice(l.secrets, func(i, j int) bool { return len(l.secrets[i]) > len(l.secrets[j]) })
}

var (
	reGemini  = regexp.MustCompile(`AIza[0-9A-Za-z_-]{20,}`)
	reLink    = regexp.MustCompile(`(?i)\b(?:vless|vmess|ss|ssr|trojan|hysteria2|hysteria|hy2|tuic|wireguard)://\S+`)
	rePrivKey = regexp.MustCompile(`(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)`)
	reAuth    = regexp.MustCompile(`(?i)\b(authorization|proxy-authorization)\b(\s*[:=]\s*)(?:bearer\s+|basic\s+|token\s+)?[^\s,;"']+`)
	reBearer  = regexp.MustCompile(`(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}`)
	reKV      = regexp.MustCompile(`(?i)\b(token|secret|password|passwd|pwd|passphrase|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|subscription|sub[_-]?url|panel[_-]?url|remnawave[_-]?(?:url|token)|askpass)\b(["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;&}\]]+)`)
)

// Redact removes registered secrets and well-known secret shapes from s.
func (l *Logger) Redact(s string) string {
	l.mu.Lock()
	secs := append([]string(nil), l.secrets...)
	l.mu.Unlock()
	for _, sec := range secs {
		s = strings.ReplaceAll(s, sec, Redacted)
	}
	return RedactPatterns(s)
}

// RedactPatterns applies only the pattern rules (no registered secrets).
func RedactPatterns(s string) string {
	s = rePrivKey.ReplaceAllString(s, Redacted)
	s = reLink.ReplaceAllString(s, Redacted)
	s = reGemini.ReplaceAllString(s, Redacted)
	s = reAuth.ReplaceAllString(s, "${1}${2}"+Redacted)
	s = reBearer.ReplaceAllString(s, "${1} "+Redacted)
	s = reKV.ReplaceAllString(s, "${1}${2}"+Redacted)
	return s
}

func fmtKV(kv []any) string {
	var parts []string
	for i := 0; i+1 < len(kv); i += 2 {
		k := fmt.Sprint(kv[i])
		if kv[i+1] == nil {
			continue
		}
		v := fmt.Sprint(kv[i+1])
		if v == "" || strings.ContainsAny(v, " \t\n\"=") {
			b, _ := json.Marshal(v)
			v = string(b)
		}
		parts = append(parts, k+"="+v)
	}
	if len(parts) == 0 {
		return ""
	}
	return " " + strings.Join(parts, " ")
}

func (l *Logger) write(level int, name, msg string, kv []any) {
	defer func() { _ = recover() }() // logging must never break a feature
	if level < l.threshold {
		return
	}
	if err := os.MkdirAll(l.dir, 0o700); err != nil {
		return
	}
	lines := strings.Split(strings.TrimRight(msg, "\n"), "\n")
	text := fmt.Sprintf("%s %s %s %s%s", l.now().Format("2006-01-02T15:04:05Z07:00"), name, l.module, lines[0], fmtKV(kv))
	if len(lines) > 1 {
		text += "\n    " + strings.Join(lines[1:], "\n    ")
	}
	text = l.Redact(text) + "\n"
	path := l.Path()
	if st, err := os.Stat(path); err == nil && st.Size() >= l.maxBytes {
		l.rotate(path)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(text)
}

// rotate shifts path -> path.1 -> path.2 (keep files in total), as xlog.py.
func (l *Logger) rotate(path string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if st, err := os.Stat(path); err != nil || st.Size() < l.maxBytes {
		return
	}
	for i := keep - 1; i >= 1; i-- {
		src := path
		if i > 1 {
			src = fmt.Sprintf("%s.%d", path, i-1)
		}
		if _, err := os.Stat(src); err == nil {
			_ = os.Rename(src, fmt.Sprintf("%s.%d", path, i))
		}
	}
}

// Debugf-style helpers take a message and key,value pairs.

func (l *Logger) Debug(msg string, kv ...any) { l.write(Debug, "DEBUG", msg, kv) }
func (l *Logger) Info(msg string, kv ...any)  { l.write(Info, "INFO", msg, kv) }
func (l *Logger) Warn(msg string, kv ...any)  { l.write(Warn, "WARN", msg, kv) }
func (l *Logger) Error(msg string, kv ...any) { l.write(Error, "ERROR", msg, kv) }
