package config

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const good = `schema = 1
lang = "ru"
preset = "custom"
modules = ["core", "hotkeys", "ai-gemini"]
[secrets]
gemini_key       = "file:~/keys/gemini"
remnawave_url    = "env:SERP_REMNAWAVE_URL"
remnawave_token  = ""
[options]
notes_dir     = "~/Notes"
gemini_proxy  = "socks5h://127.0.0.1:1080"
vpn_mode      = "all"
vpn_killswitch = true
[run]
on_error = "abort"
finish   = "hyprland"
`

var known = []string{"core", "hotkeys", "ai-gemini", "vpn"}

func TestParseGood(t *testing.T) {
	f, err := Parse([]byte(good), ParseOptions{Known: known})
	if err != nil {
		t.Fatal(err)
	}
	if f.Lang != "ru" || len(f.Modules) != 3 || f.Options.VPNMode != "all" || !f.Options.VPNKillswitch ||
		!f.Options.CommandsExamples /* default kept */ || f.Run.Finish != "hyprland" {
		t.Fatalf("%+v", f)
	}
}

func TestErrorsHaveLines(t *testing.T) {
	cases := []struct {
		name, src, wantLine, wantMsg string
	}{
		{"unknown top", "schema = 1\nfoo = 1\n", ":2:", `unknown key "foo"`},
		{"unknown nested", "schema = 1\n[options]\nnotes_dir = \"x\"\nbogus = true\n", ":4:", "options.bogus"},
		{"syntax", "schema = 1\npreset = \n", ":2:", ""},
		{"type", "schema = 1\n[options]\nvpn_killswitch = \"yes\"\n", ":3:", ""},
		{"bad enum", "schema = 1\n\n\npreset = \"huge\"\n", ":4:", "preset"},
		{"bad schema", "schema = 2\n", ":1:", "schema"},
		{"unknown module", "schema = 1\npreset=\"custom\"\nmodules = [\"nope\"]\n", ":3:", `unknown module "nope"`},
		{"modules without custom", "schema = 1\nmodules = [\"core\"]\n", ":2:", "custom"},
		{"literal secret", "schema = 1\n[secrets]\ngemini_key = \"AIzaFAKE0123456789\"\n", ":3:", "file:"},
		{"bad env", "schema = 1\n[secrets]\nremnawave_token = \"env:1 BAD\"\n", ":3:", "variable name"},
		{"proxy", "schema = 1\n[options]\ngemini_proxy = \"nonsense\"\n", ":3:", "gemini_proxy"},
		{"on_error", "schema = 1\n[run]\non_error = \"panic\"\n", ":3:", "on_error"},
	}
	for _, c := range cases {
		_, err := Parse([]byte(c.src), ParseOptions{Name: "my-setup.toml", Known: known})
		if err == nil {
			t.Errorf("%s: no error", c.name)
			continue
		}
		s := err.Error()
		if !strings.Contains(s, "my-setup.toml"+c.wantLine) || !strings.Contains(s, c.wantMsg) {
			t.Errorf("%s: %q", c.name, s)
		}
		if strings.Contains(s, "AIzaFAKE") {
			t.Errorf("%s: secret echoed: %q", c.name, s)
		}
	}
}

func TestMultipleErrorsSorted(t *testing.T) {
	_, err := Parse([]byte("schema = 1\nzzz = 1\npreset = \"x\"\n"), ParseOptions{})
	var el Errors
	if !errors.As(err, &el) || len(el) != 2 || el[0].Line != 2 || el[1].Line != 3 {
		t.Fatalf("%v", err)
	}
}

func fakeEnv(files map[string]string, env map[string]string, mode os.FileMode) Env {
	return Env{
		Home: "/home/u",
		Getenv: func(k string) (string, bool) {
			v, ok := env[k]
			return v, ok
		},
		ReadFile: func(p string) ([]byte, error) {
			if v, ok := files[p]; ok {
				return []byte(v), nil
			}
			return nil, fs.ErrNotExist
		},
		Stat: func(p string) (os.FileInfo, error) {
			if _, ok := files[p]; ok {
				return fakeInfo{mode}, nil
			}
			return nil, fs.ErrNotExist
		},
	}
}

type fakeInfo struct{ m os.FileMode }

func (fakeInfo) Name() string        { return "" }
func (fakeInfo) Size() int64         { return 0 }
func (f fakeInfo) Mode() os.FileMode { return f.m }
func (fakeInfo) ModTime() (t timeT)  { return }
func (fakeInfo) IsDir() bool         { return false }
func (fakeInfo) Sys() any            { return nil }

func TestResolveSecrets(t *testing.T) {
	f, err := Parse([]byte(good), ParseOptions{})
	if err != nil {
		t.Fatal(err)
	}
	env := fakeEnv(map[string]string{"/home/u/keys/gemini": "AIzaFAKEkey123\n"},
		map[string]string{"SERP_REMNAWAVE_URL": "https://panel.example.test"}, 0o600)
	r, warns, err := f.ResolveSecrets(env)
	if err != nil || len(warns) != 0 {
		t.Fatalf("%v %v", err, warns)
	}
	if r[SecGeminiKey] != "AIzaFAKEkey123" || r[SecRemnawaveURL] != "https://panel.example.test" || len(r) != 2 {
		t.Fatalf("%v", map[string]string(r))
	}
	if strings.Contains(fmtAll(r), "AIzaFAKE") {
		t.Fatal("Resolved leaks through fmt")
	}
	// readable by others -> warning; missing env -> error without values
	env = fakeEnv(map[string]string{"/home/u/keys/gemini": "AIzaFAKEkey123"}, nil, 0o644)
	_, warns, err = f.ResolveSecrets(env)
	if err == nil || len(warns) != 1 || !strings.Contains(err.Error(), "SERP_REMNAWAVE_URL") || strings.Contains(err.Error(), "AIzaFAKE") {
		t.Fatalf("%v %v", err, warns)
	}
	// missing file
	_, _, err = f.ResolveSecrets(fakeEnv(nil, map[string]string{"SERP_REMNAWAVE_URL": "x"}, 0o600))
	if err == nil || !strings.Contains(err.Error(), "/home/u/keys/gemini") {
		t.Fatalf("%v", err)
	}
}

func TestExportHasNoSecrets(t *testing.T) {
	f := Defaults()
	f.Preset = "custom"
	f.Modules = []string{"core", "vpn"}
	f.Lang = "en"
	f.Secrets = Secrets{GeminiKey: "file:/home/u/keys/AIzaFAKEexport", RemnawaveToken: "env:TOKEN_FAKE_9"}
	b, err := f.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	for _, bad := range []string{"AIzaFAKE", "TOKEN_FAKE", "file:", "env:"} {
		if strings.Contains(s, bad) {
			t.Errorf("export contains %q:\n%s", bad, s)
		}
	}
	// and it parses back to the same thing
	g, err := Parse(b, ParseOptions{Known: known})
	if err != nil {
		t.Fatalf("%v\n%s", err, s)
	}
	if g.Preset != "custom" || len(g.Modules) != 2 || g.Lang != "en" || g.Secrets != (Secrets{}) {
		t.Fatalf("%+v", g)
	}
	// full preset: modules = [] must still parse
	f.Preset, f.Modules = "full", nil
	b, _ = f.Marshal()
	if _, err := Parse(b, ParseOptions{}); err != nil {
		t.Fatalf("%v\n%s", err, b)
	}
}

func TestLoad(t *testing.T) {
	p := filepath.Join(t.TempDir(), "my-setup.toml")
	if err := os.WriteFile(p, []byte(good), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(p, ParseOptions{Known: known}); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(p+".none", ParseOptions{}); err == nil {
		t.Fatal("want error")
	}
}

type timeT = time.Time

func fmtAll(v any) string { return fmt.Sprintf("%v %+v %#v %s", v, v, v, v) }
