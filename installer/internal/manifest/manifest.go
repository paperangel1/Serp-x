// Package manifest defines the module manifest schema (schema = 1),
// loads manifests from an fs.FS and validates them.
package manifest

import (
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
)

// SchemaVersion is the only supported manifest schema.
const SchemaVersion = 1

// Text is a string in the two supported languages.
type Text struct {
	RU string `toml:"ru"`
	EN string `toml:"en"`
}

// Get returns the text for lang ("ru" or "en"); falls back to English.
func (t Text) Get(lang string) string {
	if lang == "ru" && t.RU != "" {
		return t.RU
	}
	if t.EN != "" {
		return t.EN
	}
	return t.RU
}

// Binary is a pinned release binary (downloaded, sha256-checked, installed).
type Binary struct {
	Name          string   `toml:"name"`
	URL           string   `toml:"url"`
	Version       string   `toml:"version"`
	SHA256        string   `toml:"sha256"`
	ArchiveMember string   `toml:"archive_member"`
	Dest          string   `toml:"dest"`
	Mode          string   `toml:"mode"`
	SkipIfPkg     []string `toml:"skip_if_pkg"`
}

// Config is one wizard question.
type Config struct {
	Key       string   `toml:"key"`
	Kind      string   `toml:"kind"` // secret|text|choice|bool|path
	Label     Text     `toml:"label"`
	Help      Text     `toml:"help"`
	Default   any      `toml:"default"`
	Choices   []string `toml:"choices"`
	Validate  string   `toml:"validate"`
	Skippable bool     `toml:"skippable"`
	Store     string   `toml:"store"`
}

// Step is a module-specific installation step run by the engine.
type Step struct {
	ID        string         `toml:"id"`
	Kind      string         `toml:"kind"`
	Title     Text           `toml:"title"`
	Root      bool           `toml:"root"`
	Args      map[string]any `toml:"args"`
	Check     []string       `toml:"check"`
	Undo      []string       `toml:"undo"`
	EstimateS int            `toml:"estimate_s"`
	After     []string       `toml:"after"`
}

// Estimate is the base time/size estimate of a module.
type Estimate struct {
	DownloadMiB float64 `toml:"download_mib"`
	DiskMiB     float64 `toml:"disk_mib"`
	BuildS      int     `toml:"build_s"`
	InstallS    int     `toml:"install_s"`
}

// Uninstall describes what survives uninstallation.
type Uninstall struct {
	KeepData []string `toml:"keep_data"`
}

// Manifest is one module.
type Manifest struct {
	ID          string    `toml:"id"`
	Schema      int       `toml:"schema"`
	Order       int       `toml:"order"`
	Core        bool      `toml:"core"`
	Group       string    `toml:"group"` // build|upstream|system
	Presets     []string  `toml:"presets"`
	Name        Text      `toml:"name"`
	Desc        Text      `toml:"desc"`
	Notes       Text      `toml:"notes"`
	Requires    []string  `toml:"requires"`
	Conflicts   []string  `toml:"conflicts"`
	Enhances    []string  `toml:"enhances"`
	RecommendIf string    `toml:"recommend_if"`
	Packages    []string  `toml:"packages"`
	AUR         []string  `toml:"aur"`
	Binary      []Binary  `toml:"binary"`
	UserFiles   []string  `toml:"user_files"`
	RootFiles   []string  `toml:"root_files"`
	SystemdUser []string  `toml:"systemd_user"`
	SystemdSys  []string  `toml:"systemd_system"`
	Config      []Config  `toml:"config"`
	Steps       []Step    `toml:"steps"`
	Estimate    Estimate  `toml:"estimate"`
	Uninstall   Uninstall `toml:"uninstall"`
}

// Set is a validated, ordered collection of manifests.
type Set struct {
	List []*Manifest
	byID map[string]*Manifest
}

// Get returns a manifest by id.
func (s *Set) Get(id string) (*Manifest, bool) {
	m, ok := s.byID[id]
	return m, ok
}

// IDs returns module ids in canonical order.
func (s *Set) IDs() []string {
	out := make([]string, len(s.List))
	for i, m := range s.List {
		out[i] = m.ID
	}
	return out
}

// Core returns the core module.
func (s *Set) Core() *Manifest {
	for _, m := range s.List {
		if m.Core {
			return m
		}
	}
	return nil
}

// Parse decodes one manifest strictly (unknown keys are errors).
func Parse(name string, data []byte) (*Manifest, error) {
	var m Manifest
	md, err := toml.Decode(string(data), &m)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	if u := md.Undecoded(); len(u) > 0 {
		var keys []string
		for _, k := range u {
			// steps.args is free-form (a map[string]any); the decoder reports
			// its nested tables as "undecoded", which is not a typo.
			if len(k) >= 2 && k[0] == "steps" && k[1] == "args" {
				continue
			}
			keys = append(keys, k.String())
		}
		if len(keys) > 0 {
			return nil, fmt.Errorf("%s: unknown keys: %s", name, strings.Join(keys, ", "))
		}
	}
	return &m, nil
}

// Load reads dir/*.toml from fsys, validates every manifest and the
// relations between them, and returns them in canonical order
// (by `order`, then id).
func Load(fsys fs.FS, dir string) (*Set, error) {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return nil, err
	}
	var all []*Manifest
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".toml") {
			continue
		}
		p := path.Join(dir, e.Name())
		data, err := fs.ReadFile(fsys, p)
		if err != nil {
			return nil, err
		}
		m, err := Parse(e.Name(), data)
		if err != nil {
			return nil, err
		}
		if want := strings.TrimSuffix(e.Name(), ".toml"); m.ID != want {
			return nil, fmt.Errorf("%s: id %q does not match file name", e.Name(), m.ID)
		}
		all = append(all, m)
	}
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].Order != all[j].Order {
			return all[i].Order < all[j].Order
		}
		return all[i].ID < all[j].ID
	})
	s := &Set{List: all, byID: map[string]*Manifest{}}
	for _, m := range all {
		if _, dup := s.byID[m.ID]; dup {
			return nil, fmt.Errorf("duplicate module id %q", m.ID)
		}
		s.byID[m.ID] = m
	}
	if err := s.Validate(); err != nil {
		return nil, err
	}
	return s, nil
}

var (
	reID     = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	reStepID = regexp.MustCompile(`^[a-z][a-z0-9-]*\.[a-z0-9][a-z0-9._-]*$`)
	reSHA    = regexp.MustCompile(`^[0-9a-f]{64}$`)
	reKey    = regexp.MustCompile(`^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$`)
)

var (
	groups     = map[string]bool{"build": true, "upstream": true, "system": true}
	stepKinds  = map[string]bool{"pacman": true, "aur": true, "binary": true, "files": true, "link": true, "template": true, "hypr": true, "sysuser": true, "root": true, "script": true, "download": true, "secret": true, "restore": true, "builtin": true}
	cfgKinds   = map[string]bool{"secret": true, "text": true, "choice": true, "bool": true, "path": true}
	presetsSet = map[string]bool{"full": true, "minimal": true}
)

// Validate checks every manifest and the cross-module relations. All
// problems found are reported together.
func (s *Set) Validate() error {
	var errs []string
	add := func(m *Manifest, f string, a ...any) {
		errs = append(errs, m.ID+": "+fmt.Sprintf(f, a...))
	}
	cores := 0
	allKeys := map[string]string{}
	for _, m := range s.List {
		if m.Core {
			cores++
		}
		if !reID.MatchString(m.ID) {
			add(m, "bad id")
		}
		if m.Schema != SchemaVersion {
			add(m, "schema must be %d, got %d", SchemaVersion, m.Schema)
		}
		if !groups[m.Group] {
			add(m, "bad group %q", m.Group)
		}
		for _, p := range m.Presets {
			if !presetsSet[p] {
				add(m, "unknown preset %q", p)
			}
		}
		req := func(label string, t Text) {
			if strings.TrimSpace(t.RU) == "" || strings.TrimSpace(t.EN) == "" {
				add(m, "%s needs both ru and en", label)
			}
		}
		req("name", m.Name)
		req("desc", m.Desc)
		if m.Notes.RU != "" || m.Notes.EN != "" {
			req("notes", m.Notes)
		}
		for _, rel := range []struct {
			n string
			v []string
		}{{"requires", m.Requires}, {"conflicts", m.Conflicts}, {"enhances", m.Enhances}} {
			for _, id := range rel.v {
				if id == m.ID {
					add(m, "%s refers to itself", rel.n)
				} else if _, ok := s.byID[id]; !ok {
					add(m, "%s: unknown module %q", rel.n, id)
				}
			}
		}
		if m.Core && len(m.Requires) > 0 {
			add(m, "core must not require anything")
		}
		for _, b := range m.Binary {
			if b.Name == "" || b.URL == "" || b.Dest == "" || b.Version == "" {
				add(m, "binary %q: name, url, version and dest are required", b.Name)
			}
			if !strings.HasPrefix(b.URL, "https://") {
				add(m, "binary %q: url must be https", b.Name)
			}
			if !reSHA.MatchString(b.SHA256) {
				add(m, "binary %q: sha256 must be 64 lowercase hex digits", b.Name)
			}
			if !strings.HasPrefix(b.Dest, "/") && !strings.HasPrefix(b.Dest, "~/") {
				add(m, "binary %q: dest must be absolute", b.Name)
			}
		}
		keys := map[string]bool{}
		for _, c := range m.Config {
			if !reKey.MatchString(c.Key) {
				add(m, "config key %q must look like <area>.<name>", c.Key)
			}
			if prev, dup := allKeys[c.Key]; dup && prev != m.ID {
				add(m, "config key %q already used by %s", c.Key, prev)
			}
			allKeys[c.Key] = m.ID
			if keys[c.Key] {
				add(m, "duplicate config key %q", c.Key)
			}
			keys[c.Key] = true
			if !cfgKinds[c.Kind] {
				add(m, "config %q: bad kind %q", c.Key, c.Kind)
			}
			req("config "+c.Key+" label", c.Label)
			if c.Kind == "choice" && len(c.Choices) == 0 {
				add(m, "config %q: choice without choices", c.Key)
			}
			if c.Kind == "secret" && c.Store == "" {
				add(m, "config %q: secret needs store", c.Key)
			}
			if c.Validate != "" {
				if _, err := regexp.Compile(c.Validate); err != nil {
					add(m, "config %q: bad validate regexp: %v", c.Key, err)
				}
			}
		}
		stepIDs := map[string]bool{}
		for _, st := range m.Steps {
			if !reStepID.MatchString(st.ID) || !strings.HasPrefix(st.ID, m.ID+".") {
				add(m, "step id %q must be %s.<name>", st.ID, m.ID)
			}
			if stepIDs[st.ID] {
				add(m, "duplicate step id %q", st.ID)
			}
			stepIDs[st.ID] = true
			if !stepKinds[st.Kind] {
				add(m, "step %q: bad kind %q", st.ID, st.Kind)
			}
			req("step "+st.ID+" title", st.Title)
		}
		for _, st := range m.Steps {
			for _, a := range st.After {
				if !stepIDs[a] {
					add(m, "step %q: after refers to unknown step %q", st.ID, a)
				}
			}
		}
		if err := checkStepCycle(m); err != nil {
			add(m, "%v", err)
		}
	}
	if cores != 1 {
		errs = append(errs, fmt.Sprintf("exactly one core module required, found %d", cores))
	}
	if len(errs) == 0 {
		if err := s.checkRequiresCycle(); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("manifest validation failed:\n  %s", strings.Join(errs, "\n  "))
	}
	return nil
}

func checkStepCycle(m *Manifest) error {
	after := map[string][]string{}
	for _, st := range m.Steps {
		after[st.ID] = st.After
	}
	state := map[string]int{}
	var visit func(id string) error
	visit = func(id string) error {
		switch state[id] {
		case 1:
			return fmt.Errorf("step cycle at %q", id)
		case 2:
			return nil
		}
		state[id] = 1
		for _, a := range after[id] {
			if err := visit(a); err != nil {
				return err
			}
		}
		state[id] = 2
		return nil
	}
	for _, st := range m.Steps {
		if err := visit(st.ID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Set) checkRequiresCycle() error {
	state := map[string]int{}
	var visit func(id string, stack []string) error
	visit = func(id string, stack []string) error {
		switch state[id] {
		case 1:
			return fmt.Errorf("requires cycle: %s -> %s", strings.Join(stack, " -> "), id)
		case 2:
			return nil
		}
		state[id] = 1
		for _, r := range s.byID[id].Requires {
			if err := visit(r, append(stack, id)); err != nil {
				return err
			}
		}
		state[id] = 2
		return nil
	}
	for _, m := range s.List {
		if err := visit(m.ID, nil); err != nil {
			return err
		}
	}
	return nil
}
