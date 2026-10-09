package i18n_test

import (
	"os"
	"strings"
	"testing"
	"testing/fstest"

	"serpx/installer"
	"serpx/installer/internal/i18n"
)

func TestShippedCatalogIsComplete(t *testing.T) {
	c, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Verify(); err != nil {
		t.Fatal(err)
	}
	ru, en := c.Keys("ru"), c.Keys("en")
	if len(ru) < 40 || strings.Join(ru, ",") != strings.Join(en, ",") {
		t.Fatalf("ru %d keys, en %d keys", len(ru), len(en))
	}
}

func TestVerifyCatchesProblems(t *testing.T) {
	mk := func(ru, en string) *i18n.Catalog {
		c, err := i18n.Load(fstest.MapFS{
			"d/ru.toml": {Data: []byte(ru)},
			"d/en.toml": {Data: []byte(en)},
		}, "d")
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	cases := []struct{ name, ru, en, want string }{
		{"missing in en", "a = \"x\"\nb = \"y\"", "a = \"x\"", `"b" is in ru but missing in en`},
		{"missing in ru", "a = \"x\"", "a = \"x\"\nb = \"y\"", `"b" is in en but missing in ru`},
		{"placeholder", "a = \"{n} шт\"", "a = \"{m} pcs\"", "placeholders differ"},
		{"empty", "a = \"\"", "a = \"x\"", "empty"},
	}
	for _, c := range cases {
		err := mk(c.ru, c.en).Verify()
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v", c.name, err)
		}
	}
	if err := mk("a = \"{n} шт\"", "a = \"{n} pcs\"").Verify(); err != nil {
		t.Error(err)
	}
}

func TestNestedKeysAndSubstitution(t *testing.T) {
	c, err := i18n.Load(fstest.MapFS{
		"d/ru.toml": {Data: []byte("[screen.modules]\ntitle = \"Модули {n}\"\nonly_ru = \"р\"")},
		"d/en.toml": {Data: []byte("[screen.modules]\ntitle = \"Modules {n}\"\nonly_en = \"e\"")},
	}, "d")
	if err != nil {
		t.Fatal(err)
	}
	if got := c.T("ru", "screen.modules.title", "n", "3"); got != "Модули 3" {
		t.Error(got)
	}
	if got := c.T("en", "screen.modules.title", "n", "3"); got != "Modules 3" {
		t.Error(got)
	}
	if got := c.T("en", "screen.modules.only_ru"); got != "р" { // falls back
		t.Error(got)
	}
	if got := c.T("ru", "nope.key"); got != "nope.key" {
		t.Error(got)
	}
}

func TestDetectLang(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	cases := []struct {
		flag string
		env  map[string]string
		want string
	}{
		{"", map[string]string{"LANG": "ru_RU.UTF-8"}, "ru"},
		{"", map[string]string{"LANG": "en_US.UTF-8"}, "en"},
		{"", map[string]string{}, "en"},
		{"", map[string]string{"LC_ALL": "C", "LANG": "ru_RU.UTF-8"}, "en"}, // POSIX: LC_ALL wins
		{"", map[string]string{"LC_ALL": "ru_RU.UTF-8", "LANG": "en_US"}, "ru"},
		{"", map[string]string{"LC_MESSAGES": "ru_UA", "LANG": "en_US"}, "ru"},
		{"en", map[string]string{"LANG": "ru_RU.UTF-8"}, "en"}, // flag wins
		{"RU", map[string]string{"LANG": "en_US.UTF-8"}, "ru"},
	}
	for _, c := range cases {
		if got := i18n.DetectLang(c.flag, env(c.env)); got != c.want {
			t.Errorf("%v %v: got %s want %s", c.flag, c.env, got, c.want)
		}
	}
}

// Every id the main program asks the catalog for must exist: scan the cmd
// sources for T("...")-style literals and "step."/"err." keys.
func TestKeysUsedInCommandExist(t *testing.T) {
	c, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"../../cmd/serp-installer/main.go", "../../cmd/serp-installer/plan.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, key := range quoted(string(b)) {
			if !looksLikeKey(key) {
				continue
			}
			if !c.Has("ru", key) {
				t.Errorf("%s: i18n key %q not in catalog", f, key)
			}
		}
	}
}

func looksLikeKey(s string) bool {
	for _, p := range []string{"err.", "plan.", "step.", "usage.", "flag.", "app.", "cmd.", "preset.", "group."} {
		if strings.HasPrefix(s, p) {
			return !strings.HasSuffix(s, ".") // "cmd."+name is a prefix
		}
	}
	return false
}

func quoted(src string) []string {
	var out []string
	for {
		i := strings.IndexByte(src, '"')
		if i < 0 {
			return out
		}
		src = src[i+1:]
		j := strings.IndexByte(src, '"')
		if j < 0 {
			return out
		}
		out = append(out, src[:j])
		src = src[j+1:]
	}
}
