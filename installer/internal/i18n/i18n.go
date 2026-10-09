// Package i18n holds the installer's own UI strings (ru/en catalogs) and
// language detection. Strings are addressed by key so the UI can switch
// language at any moment (F2) without rebuilding anything.
package i18n

import (
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"

	"github.com/BurntSushi/toml"
)

// Supported languages.
const (
	RU = "ru"
	EN = "en"
)

// Langs lists the supported languages.
var Langs = []string{RU, EN}

// Catalog holds the flattened strings of every language.
type Catalog struct {
	m map[string]map[string]string
}

// Load reads dir/ru.toml and dir/en.toml. Nested tables are flattened with
// dots: [screen.modules] title = "x" becomes "screen.modules.title".
func Load(fsys fs.FS, dir string) (*Catalog, error) {
	c := &Catalog{m: map[string]map[string]string{}}
	for _, lang := range Langs {
		data, err := fs.ReadFile(fsys, path.Join(dir, lang+".toml"))
		if err != nil {
			return nil, err
		}
		var raw map[string]any
		if err := toml.Unmarshal(data, &raw); err != nil {
			return nil, fmt.Errorf("%s.toml: %w", lang, err)
		}
		flat := map[string]string{}
		if err := flatten("", raw, flat); err != nil {
			return nil, fmt.Errorf("%s.toml: %w", lang, err)
		}
		c.m[lang] = flat
	}
	return c, nil
}

func flatten(prefix string, in map[string]any, out map[string]string) error {
	for k, v := range in {
		key := k
		if prefix != "" {
			key = prefix + "." + k
		}
		switch t := v.(type) {
		case string:
			out[key] = t
		case map[string]any:
			if err := flatten(key, t, out); err != nil {
				return err
			}
		default:
			return fmt.Errorf("key %s: only strings and tables are allowed", key)
		}
	}
	return nil
}

// Keys returns the sorted keys of a language.
func (c *Catalog) Keys(lang string) []string {
	var out []string
	for k := range c.m[lang] {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Has reports whether lang has key.
func (c *Catalog) Has(lang, key string) bool {
	_, ok := c.m[lang][key]
	return ok
}

// T returns the text for key in lang. kv are name,value pairs substituted
// for {name}. A key missing in lang falls back to the other language and
// then to the key itself, so a gap is visible but never fatal.
func (c *Catalog) T(lang, key string, kv ...string) string {
	s, ok := c.m[lang][key]
	if !ok {
		other := RU
		if lang == RU {
			other = EN
		}
		if s, ok = c.m[other][key]; !ok {
			return key
		}
	}
	for i := 0; i+1 < len(kv); i += 2 {
		s = strings.ReplaceAll(s, "{"+kv[i]+"}", kv[i+1])
	}
	return s
}

var rePlaceholder = regexp.MustCompile(`\{[a-z_][a-z0-9_]*\}`)

// Placeholders returns the sorted distinct {name} placeholders of s.
func Placeholders(s string) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range rePlaceholder.FindAllString(s, -1) {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// Verify checks that both languages have exactly the same keys, no value is
// empty, and each key has the same placeholders in both languages.
func (c *Catalog) Verify() error {
	var errs []string
	for _, lang := range Langs {
		other := RU
		if lang == RU {
			other = EN
		}
		for k, v := range c.m[lang] {
			ov, ok := c.m[other][k]
			if !ok {
				errs = append(errs, fmt.Sprintf("key %q is in %s but missing in %s", k, lang, other))
				continue
			}
			if strings.TrimSpace(v) == "" {
				errs = append(errs, fmt.Sprintf("key %q is empty in %s", k, lang))
			}
			if lang == RU && strings.Join(Placeholders(v), ",") != strings.Join(Placeholders(ov), ",") {
				errs = append(errs, fmt.Sprintf("key %q: placeholders differ (%v vs %v)", k, Placeholders(v), Placeholders(ov)))
			}
		}
	}
	if len(errs) > 0 {
		sort.Strings(errs)
		return fmt.Errorf("i18n catalog problems:\n  %s", strings.Join(errs, "\n  "))
	}
	return nil
}

// DetectLang picks the language: explicit flag (ru|en) wins; otherwise the
// first non-empty of LC_ALL, LC_MESSAGES, LANG (POSIX order) decides: "ru*"
// is Russian, anything else English.
func DetectLang(flag string, getenv func(string) string) string {
	switch strings.ToLower(strings.TrimSpace(flag)) {
	case RU:
		return RU
	case EN:
		return EN
	}
	for _, name := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if v := strings.TrimSpace(getenv(name)); v != "" {
			if strings.HasPrefix(strings.ToLower(v), "ru") {
				return RU
			}
			return EN
		}
	}
	return EN
}

// ValidLang reports whether s is "", "ru" or "en" (for flag validation).
func ValidLang(s string) bool {
	s = strings.ToLower(s)
	return s == "" || s == RU || s == EN
}
