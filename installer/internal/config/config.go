// Package config reads and writes my-setup.toml, the non-interactive install
// description (plan section 6). Parsing is strict: unknown keys are errors,
// every error carries a line number, secret values are never accepted (only
// "file:" / "env:" references) and never echoed.
package config

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"
)

// Schema is the supported file format version.
const Schema = 1

// Secrets holds references only ("file:PATH", "env:NAME" or "" = skip).
type Secrets struct {
	GeminiKey       string `toml:"gemini_key"`
	RemnawaveURL    string `toml:"remnawave_url"`
	RemnawaveToken  string `toml:"remnawave_token"`
	VPNSubscription string `toml:"vpn_subscription"`
}

// Options are the wizard answers.
type Options struct {
	NotesDir            string `toml:"notes_dir"`
	GeminiProxy         string `toml:"gemini_proxy"`
	VPNMode             string `toml:"vpn_mode"`
	VPNKillswitch       bool   `toml:"vpn_killswitch"`
	CommandsStartDaemon bool   `toml:"commands_start_daemon"`
	CommandsExamples    bool   `toml:"commands_examples"`
	ServersGenerateKey  bool   `toml:"servers_generate_key"`
}

// Run controls error handling and the final action.
type Run struct {
	OnError string `toml:"on_error"` // ask | skip-optional | abort
	Finish  string `toml:"finish"`   // exit | reboot | hyprland
}

// File is the whole my-setup.toml.
type File struct {
	Schema  int      `toml:"schema"`
	Lang    string   `toml:"lang"`   // ru | en | "" (auto)
	Preset  string   `toml:"preset"` // full | minimal | custom
	Modules []string `toml:"modules"`
	Secrets Secrets  `toml:"secrets"`
	Options Options  `toml:"options"`
	Run     Run      `toml:"run"`
}

// Defaults returns the values used for keys missing in the file.
func Defaults() File {
	return File{
		Schema: Schema,
		Preset: "full",
		Options: Options{
			NotesDir: "~/Notes", VPNMode: "ru-direct",
			CommandsStartDaemon: true, CommandsExamples: true, ServersGenerateKey: true,
		},
		Run: Run{OnError: "skip-optional", Finish: "exit"},
	}
}

// Error is one problem; Line is 0 when it is not tied to a line.
type Error struct {
	File string
	Line int
	Msg  string
}

func (e *Error) Error() string {
	name := e.File
	if name == "" {
		name = "my-setup.toml"
	}
	if e.Line > 0 {
		return fmt.Sprintf("%s:%d: %s", name, e.Line, e.Msg)
	}
	return fmt.Sprintf("%s: %s", name, e.Msg)
}

// Errors is a list of problems; it implements error.
type Errors []*Error

func (l Errors) Error() string {
	parts := make([]string, len(l))
	for i, e := range l {
		parts[i] = e.Error()
	}
	return strings.Join(parts, "\n")
}

// ParseOptions tune Parse.
type ParseOptions struct {
	Name  string   // file name used in messages
	Known []string // known module ids; nil = do not check
}

var (
	envName   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	proxyRe   = regexp.MustCompile(`^(socks5h?|socks5|https?)://[^/\s]+:\d{1,5}$`)
	lineRe    = regexp.MustCompile(`line (\d+)`)
	secretMsg = "secret value must not be written in the file: use file:PATH or env:NAME"
)

// Parse decodes and validates a my-setup.toml.
func Parse(data []byte, po ParseOptions) (*File, error) {
	f := Defaults()
	f.Schema = 0
	lines := locate(data)
	var errs Errors
	add := func(key, msg string) {
		errs = append(errs, &Error{File: po.Name, Line: lines[key], Msg: msg})
	}

	md, err := toml.Decode(string(data), &f)
	if err != nil {
		var pe toml.ParseError
		line := 0
		if errors.As(err, &pe) {
			line = pe.Position.Line
			return nil, Errors{{File: po.Name, Line: line, Msg: pe.Message}}
		}
		msg := err.Error()
		if m := lineRe.FindStringSubmatch(msg); m != nil {
			line, _ = strconv.Atoi(m[1])
			msg = strings.TrimPrefix(msg, "toml: ")
		}
		return nil, Errors{{File: po.Name, Line: line, Msg: msg}}
	}
	und := md.Undecoded()
	sort.Slice(und, func(i, j int) bool { return lines[und[i].String()] < lines[und[j].String()] })
	for _, k := range und {
		add(k.String(), fmt.Sprintf("unknown key %q", k.String()))
	}

	if f.Schema != Schema {
		add("schema", fmt.Sprintf("schema must be %d", Schema))
	}
	oneOf := func(key, val string, allowed ...string) {
		for _, a := range allowed {
			if val == a {
				return
			}
		}
		add(key, fmt.Sprintf("%s must be one of: %s", key, strings.Join(quoteAll(allowed), ", ")))
	}
	if f.Lang != "" {
		oneOf("lang", f.Lang, "ru", "en")
	}
	oneOf("preset", f.Preset, "full", "minimal", "custom")
	if f.Preset != "custom" && len(f.Modules) > 0 {
		add("modules", `modules is only allowed with preset = "custom"`)
	}
	if f.Preset == "custom" && len(f.Modules) == 0 {
		add("preset", `preset "custom" needs a non-empty modules list`)
	}
	if po.Known != nil {
		known := map[string]bool{}
		for _, k := range po.Known {
			known[k] = true
		}
		seen := map[string]bool{}
		for _, m := range f.Modules {
			switch {
			case !known[m]:
				add("modules", fmt.Sprintf("unknown module %q", m))
			case seen[m]:
				add("modules", fmt.Sprintf("module %q listed twice", m))
			}
			seen[m] = true
		}
	}

	for _, s := range []struct{ key, val string }{
		{"secrets.gemini_key", f.Secrets.GeminiKey},
		{"secrets.remnawave_url", f.Secrets.RemnawaveURL},
		{"secrets.remnawave_token", f.Secrets.RemnawaveToken},
		{"secrets.vpn_subscription", f.Secrets.VPNSubscription},
	} {
		if msg := checkRef(s.val); msg != "" {
			add(s.key, msg)
		}
	}

	oneOf("options.vpn_mode", f.Options.VPNMode, "ru-direct", "all")
	if p := f.Options.GeminiProxy; p != "" && !proxyRe.MatchString(p) {
		add("options.gemini_proxy", `gemini_proxy must be "" or look like socks5h://host:port`)
	}
	if strings.TrimSpace(f.Options.NotesDir) == "" {
		add("options.notes_dir", "notes_dir must not be empty")
	}
	oneOf("run.on_error", f.Run.OnError, "ask", "skip-optional", "abort")
	oneOf("run.finish", f.Run.Finish, "exit", "reboot", "hyprland")

	if len(errs) > 0 {
		sort.SliceStable(errs, func(i, j int) bool { return errs[i].Line < errs[j].Line })
		return nil, errs
	}
	return &f, nil
}

func quoteAll(in []string) []string {
	out := make([]string, len(in))
	for i, s := range in {
		out[i] = `"` + s + `"`
	}
	return out
}

// checkRef validates a secret reference WITHOUT echoing it.
func checkRef(v string) string {
	switch {
	case v == "":
		return ""
	case strings.HasPrefix(v, "file:"):
		if strings.TrimSpace(v[5:]) == "" {
			return "file: reference has an empty path"
		}
		return ""
	case strings.HasPrefix(v, "env:"):
		if !envName.MatchString(v[4:]) {
			return "env: reference needs a valid variable name"
		}
		return ""
	}
	return secretMsg
}

// Load reads and parses a file.
func Load(path string, po ParseOptions) (*File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if po.Name == "" {
		po.Name = filepath.Base(path)
	}
	return Parse(b, po)
}

// locate maps "table.key" (and bare "key", "table") to the line it is on.
func locate(data []byte) map[string]int {
	out := map[string]int{}
	table := ""
	keyRe := regexp.MustCompile(`^\s*([A-Za-z0-9_-]+|"[^"]*")\s*=`)
	for i, ln := range strings.Split(string(data), "\n") {
		t := strings.TrimSpace(ln)
		switch {
		case t == "" || strings.HasPrefix(t, "#"):
		case strings.HasPrefix(t, "["):
			table = strings.Trim(strings.SplitN(t, "#", 2)[0], "[] \t")
			if _, ok := out[table]; !ok {
				out[table] = i + 1
			}
		default:
			if m := keyRe.FindStringSubmatch(ln); m != nil {
				k := strings.Trim(m[1], `"`)
				if table != "" {
					k = table + "." + k
				}
				if _, ok := out[k]; !ok {
					out[k] = i + 1
				}
			}
		}
	}
	return out
}

// ---- secret resolution ----

// Names of secrets, as used by the installer and the backup list.
const (
	SecGeminiKey       = "gemini_key"
	SecRemnawaveURL    = "remnawave_url"
	SecRemnawaveToken  = "remnawave_token"
	SecVPNSubscription = "vpn_subscription"
)

// Refs returns name -> reference, only non-empty ones.
func (s Secrets) Refs() map[string]string {
	m := map[string]string{
		SecGeminiKey: s.GeminiKey, SecRemnawaveURL: s.RemnawaveURL,
		SecRemnawaveToken: s.RemnawaveToken, SecVPNSubscription: s.VPNSubscription,
	}
	for k, v := range m {
		if v == "" {
			delete(m, k)
		}
	}
	return m
}

// Resolved secret values live only in memory. String/GoString hide them.
type Resolved map[string]string

func (Resolved) String() string   { return "config.Resolved{***}" }
func (Resolved) GoString() string { return "config.Resolved{***}" }

// Values returns the secret values (for redaction registration).
func (r Resolved) Values() []string {
	var out []string
	for _, v := range r {
		out = append(out, v)
	}
	return out
}

// Env abstracts the process environment for ResolveSecrets.
type Env struct {
	Getenv   func(string) (string, bool)
	ReadFile func(string) ([]byte, error)
	Stat     func(string) (os.FileInfo, error)
	Home     string
}

// OSEnv is the real environment.
func OSEnv() Env {
	h, _ := os.UserHomeDir()
	return Env{Getenv: os.LookupEnv, ReadFile: os.ReadFile, Stat: os.Stat, Home: h}
}

// ResolveSecrets reads every referenced secret. Warnings mention files that
// other users can read. Errors never contain secret values.
func (f *File) ResolveSecrets(env Env) (Resolved, []string, error) {
	out := Resolved{}
	var warns []string
	var errs []string
	names := make([]string, 0)
	refs := f.Secrets.Refs()
	for n := range refs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		ref := refs[n]
		switch {
		case strings.HasPrefix(ref, "env:"):
			v, ok := env.Getenv(ref[4:])
			if !ok || strings.TrimSpace(v) == "" {
				errs = append(errs, fmt.Sprintf("secret %s: variable %s is empty or not set", n, ref[4:]))
				continue
			}
			out[n] = strings.TrimRight(v, "\r\n")
		case strings.HasPrefix(ref, "file:"):
			p := expandHome(strings.TrimSpace(ref[5:]), env.Home)
			if st, err := env.Stat(p); err == nil && st.Mode().Perm()&0o077 != 0 {
				warns = append(warns, fmt.Sprintf("secret %s: file %s is readable by other users (chmod 600)", n, p))
			}
			b, err := env.ReadFile(p)
			if err != nil {
				errs = append(errs, fmt.Sprintf("secret %s: cannot read %s", n, p))
				continue
			}
			v := strings.TrimRight(string(b), "\r\n")
			if strings.TrimSpace(v) == "" {
				errs = append(errs, fmt.Sprintf("secret %s: file %s is empty", n, p))
				continue
			}
			out[n] = v
		default:
			errs = append(errs, fmt.Sprintf("secret %s: bad reference", n))
		}
	}
	if len(errs) > 0 {
		return nil, warns, errors.New(strings.Join(errs, "; "))
	}
	return out, warns, nil
}

func expandHome(p, home string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return p
}

// ---- export ----

// Marshal renders the file. Secrets are ALWAYS written empty: export-config
// never puts references or values from the system into the file.
func (f File) Marshal() ([]byte, error) {
	f.Schema = Schema
	f.Secrets = Secrets{}
	if f.Modules == nil {
		f.Modules = []string{}
	}
	var buf bytes.Buffer
	buf.WriteString("# serp-installer my-setup.toml (secrets are never exported)\n")
	if err := toml.NewEncoder(&buf).Encode(f); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
