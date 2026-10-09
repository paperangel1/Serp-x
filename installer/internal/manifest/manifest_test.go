package manifest_test

import (
	"strings"
	"testing"
	"testing/fstest"

	"serpx/installer"
	"serpx/installer/internal/manifest"
)

var wantIDs = []string{
	"core", "hotkeys", "emoji", "tools", "ocr", "ai-gemini", "servers",
	"vpn", "commands", "commands-media", "nvidia", "sddm", "wallpapers",
}

func load(t *testing.T) *manifest.Set {
	t.Helper()
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		t.Fatal(err)
	}
	return set
}

func TestAllManifestsLoadInCanonicalOrder(t *testing.T) {
	set := load(t)
	got := set.IDs()
	if strings.Join(got, ",") != strings.Join(wantIDs, ",") {
		t.Fatalf("modules\n got %v\nwant %v", got, wantIDs)
	}
	if set.Core() == nil || set.Core().ID != "core" {
		t.Fatal("core module missing")
	}
}

func TestEveryTextHasRuAndEn(t *testing.T) {
	for _, m := range load(t).List {
		check := func(what string, tx manifest.Text, optional bool) {
			if optional && tx.RU == "" && tx.EN == "" {
				return
			}
			if tx.RU == "" || tx.EN == "" {
				t.Errorf("%s: %s lacks ru or en", m.ID, what)
			}
		}
		check("name", m.Name, false)
		check("desc", m.Desc, false)
		check("notes", m.Notes, true)
		for _, c := range m.Config {
			check("config "+c.Key+" label", c.Label, false)
		}
		for _, s := range m.Steps {
			check("step "+s.ID+" title", s.Title, false)
		}
	}
}

func TestRelationsReferToExistingModules(t *testing.T) {
	set := load(t)
	for _, m := range set.List {
		for _, rel := range [][]string{m.Requires, m.Conflicts, m.Enhances} {
			for _, id := range rel {
				if _, ok := set.Get(id); !ok {
					t.Errorf("%s refers to missing module %s", m.ID, id)
				}
			}
		}
	}
}

func TestPinnedBinariesAndSecrets(t *testing.T) {
	set := load(t)
	vpn, _ := set.Get("vpn")
	if len(vpn.Binary) != 1 || vpn.Binary[0].SHA256 == "" || vpn.Binary[0].Dest != "/usr/local/bin/xray" {
		t.Fatalf("vpn xray binary not pinned: %+v", vpn.Binary)
	}
	for _, m := range set.List {
		for _, c := range m.Config {
			if c.Kind == "secret" && !c.Skippable {
				t.Errorf("%s: secret %s must be skippable", m.ID, c.Key)
			}
		}
	}
}

func TestPlanFacts(t *testing.T) {
	set := load(t)
	cm, _ := set.Get("commands-media")
	if strings.Join(cm.Requires, ",") != "commands" {
		t.Errorf("commands-media requires %v", cm.Requires)
	}
	nv, _ := set.Get("nvidia")
	if nv.RecommendIf != "gpu:nvidia" || nv.Notes.RU == "" {
		t.Error("nvidia must be recommend_if gpu:nvidia with a not-verified note")
	}
	core, _ := set.Get("core")
	if len(core.Packages) < 60 {
		t.Errorf("core has only %d packages", len(core.Packages))
	}
}

const good = `
id = "%s"
schema = 1
group = "build"
name = { ru = "а", en = "a" }
desc = { ru = "б", en = "b" }
`

func mk(files map[string]string) fstest.MapFS {
	fs := fstest.MapFS{}
	for n, c := range files {
		fs["m/"+n] = &fstest.MapFile{Data: []byte(c)}
	}
	return fs
}

func g(id string, extra ...string) string {
	return strings.Replace(good, "%s", id, 1) + strings.Join(extra, "\n")
}

func TestValidationErrors(t *testing.T) {
	core := g("core", "core = true")
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{"unknown key", map[string]string{"core.toml": core + "\nbogus = 1"}, "unknown keys: bogus"},
		{"id mismatch", map[string]string{"core.toml": g("other", "core = true")}, "does not match file name"},
		{"missing requires", map[string]string{"core.toml": core, "a.toml": g("a", `requires = ["zzz"]`)}, `unknown module "zzz"`},
		{"cycle", map[string]string{"core.toml": core, "a.toml": g("a", `requires = ["b"]`), "b.toml": g("b", `requires = ["a"]`)}, "requires cycle"},
		{"no core", map[string]string{"a.toml": g("a")}, "exactly one core"},
		{"two cores", map[string]string{"core.toml": core, "a.toml": g("a", "core = true")}, "exactly one core"},
		{"missing en", map[string]string{"core.toml": core + "\n" + "[[steps]]\nid=\"core.x\"\nkind=\"script\"\ntitle={ru=\"я\",en=\"\"}"}, "title needs both ru and en"},
		{"bad sha", map[string]string{"core.toml": core + "\n[[binary]]\nname=\"x\"\nurl=\"https://e/x\"\nversion=\"1\"\ndest=\"/usr/local/bin/x\"\nsha256=\"abc\""}, "sha256 must be 64"},
		{"http url", map[string]string{"core.toml": core + "\n[[binary]]\nname=\"x\"\nurl=\"http://e/x\"\nversion=\"1\"\ndest=\"/usr/local/bin/x\"\nsha256=\"" + strings.Repeat("a", 64) + "\""}, "url must be https"},
		{"step prefix", map[string]string{"core.toml": core + "\n[[steps]]\nid=\"zzz.x\"\nkind=\"script\"\ntitle={ru=\"я\",en=\"i\"}"}, "must be core.<name>"},
		{"step cycle", map[string]string{"core.toml": core + "\n[[steps]]\nid=\"core.a\"\nkind=\"script\"\nafter=[\"core.b\"]\ntitle={ru=\"я\",en=\"i\"}\n[[steps]]\nid=\"core.b\"\nkind=\"script\"\nafter=[\"core.a\"]\ntitle={ru=\"я\",en=\"i\"}"}, "step cycle"},
		{"secret w/o store", map[string]string{"core.toml": core + "\n[[config]]\nkey=\"core.k\"\nkind=\"secret\"\nlabel={ru=\"я\",en=\"i\"}"}, "secret needs store"},
		{"bad toml", map[string]string{"core.toml": "id = "}, "core.toml"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := manifest.Load(mk(c.files), "m")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("want error containing %q, got %v", c.want, err)
			}
		})
	}
}

func TestValidMinimalSetLoads(t *testing.T) {
	set, err := manifest.Load(mk(map[string]string{
		"core.toml": g("core", "core = true"),
		"a.toml":    g("a", `requires = ["core"]`),
	}), "m")
	if err != nil || len(set.List) != 2 {
		t.Fatalf("%v", err)
	}
}
