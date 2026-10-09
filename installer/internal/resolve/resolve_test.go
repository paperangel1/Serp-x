package resolve_test

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"serpx/installer"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
)

func newResolver(t *testing.T) *resolve.Resolver {
	t.Helper()
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		t.Fatal(err)
	}
	return resolve.New(set)
}

func TestResolveTable(t *testing.T) {
	r := newResolver(t)
	cases := []struct {
		name     string
		explicit []string
		modules  []string
		auto     map[string][]string
	}{
		{"nothing -> core only", nil, []string{"core"}, map[string][]string{}},
		{"commands-media pulls commands", []string{"commands-media"},
			[]string{"core", "commands", "commands-media"},
			map[string][]string{"commands": {"commands-media"}}},
		{"explicit commands is not auto", []string{"commands", "commands-media"},
			[]string{"core", "commands", "commands-media"}, map[string][]string{}},
		{"order follows manifests, not input", []string{"vpn", "emoji"},
			[]string{"core", "emoji", "vpn"}, map[string][]string{}},
		{"duplicates collapse", []string{"emoji", "emoji", "core"},
			[]string{"core", "emoji"}, map[string][]string{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			sel, err := r.Resolve(c.explicit)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(sel.Modules, c.modules) {
				t.Errorf("modules %v want %v", sel.Modules, c.modules)
			}
			if !reflect.DeepEqual(sel.Auto, c.auto) {
				t.Errorf("auto %v want %v", sel.Auto, c.auto)
			}
		})
	}
}

func TestUnknownModule(t *testing.T) {
	_, err := newResolver(t).Resolve([]string{"nope"})
	var ue *resolve.UnknownError
	if !errors.As(err, &ue) || ue.ID != "nope" {
		t.Fatalf("got %v", err)
	}
}

func TestEnhancesIsOnlyAHint(t *testing.T) {
	sel, err := newResolver(t).Resolve([]string{"commands"})
	if err != nil {
		t.Fatal(err)
	}
	if sel.Has("ai-gemini") {
		t.Error("enhances must not pull the module in")
	}
	found := false
	for _, w := range sel.Warnings {
		if w.Kind == resolve.Enhances && w.Module == "commands" && reflect.DeepEqual(w.Affected, []string{"ai-gemini"}) {
			found = true
		}
	}
	if !found {
		t.Errorf("no enhances hint: %+v", sel.Warnings)
	}
}

func TestDeselectCascade(t *testing.T) {
	r := newResolver(t)
	explicit := []string{"emoji", "commands-media"} // commands is auto

	// Removing commands warns that commands-media goes too.
	out, w, err := r.Deselect(explicit, "commands", false)
	if err != nil {
		t.Fatal(err)
	}
	if w == nil || w.Kind != resolve.CascadeOff || !reflect.DeepEqual(w.Affected, []string{"commands-media"}) {
		t.Fatalf("warning %+v", w)
	}
	if !reflect.DeepEqual(out, explicit) {
		t.Errorf("selection must stay unchanged on warning, got %v", out)
	}

	// Confirming removes both.
	out, w, err = r.Deselect(explicit, "commands", true)
	if err != nil || w != nil {
		t.Fatalf("%v %v", err, w)
	}
	if !reflect.DeepEqual(out, []string{"emoji"}) {
		t.Errorf("after cascade %v", out)
	}
	sel, _ := r.Resolve(out)
	if sel.Has("commands") || sel.Has("commands-media") {
		t.Error("still selected")
	}
}

func TestDeselectLeafHasNoWarning(t *testing.T) {
	out, w, err := newResolver(t).Deselect([]string{"emoji", "ocr"}, "ocr", false)
	if err != nil || w != nil || !reflect.DeepEqual(out, []string{"emoji"}) {
		t.Fatalf("%v %v %v", out, w, err)
	}
}

func TestCoreCannotBeDeselected(t *testing.T) {
	_, _, err := newResolver(t).Deselect([]string{"core", "emoji"}, "core", true)
	if !errors.Is(err, resolve.ErrCoreRequired) {
		t.Fatalf("got %v", err)
	}
}

func TestPresets(t *testing.T) {
	r := newResolver(t)
	full, err := r.Preset("full", resolve.Detect{})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"wallpapers", "sddm", "nvidia"} {
		if contains(full, id) {
			t.Errorf("full must not contain %s without detection", id)
		}
	}
	if len(full) != 10 {
		t.Errorf("full = %v", full)
	}
	withNV, _ := r.Preset("full", resolve.Detect{Tags: []string{"gpu:nvidia"}})
	if !contains(withNV, "nvidia") || contains(withNV, "sddm") {
		t.Errorf("full+nvidia = %v", withNV)
	}
	amd, _ := r.Preset("full", resolve.Detect{Tags: []string{"gpu:amd"}})
	if contains(amd, "nvidia") {
		t.Error("nvidia must not be offered on AMD")
	}
	min, _ := r.Preset("minimal", resolve.Detect{Tags: []string{"gpu:nvidia"}})
	if !reflect.DeepEqual(min, []string{"core", "hotkeys", "emoji"}) {
		t.Errorf("minimal = %v", min)
	}
	if c, err := r.Preset("custom", resolve.Detect{}); err != nil || c != nil {
		t.Errorf("custom = %v %v", c, err)
	}
	if _, err := r.Preset("bogus", resolve.Detect{}); err == nil {
		t.Error("bogus preset accepted")
	}
	// every preset must resolve cleanly
	for _, p := range [][]string{full, withNV, min} {
		if _, err := r.Resolve(p); err != nil {
			t.Error(err)
		}
	}
}

func TestConflictsAreRejected(t *testing.T) {
	core := "core = true\n"
	mk := func(id, extra string) string {
		return "id = \"" + id + "\"\nschema = 1\ngroup = \"build\"\nname = {ru=\"а\",en=\"a\"}\ndesc = {ru=\"б\",en=\"b\"}\n" + extra
	}
	files := map[string]string{
		"core.toml": mk("core", core),
		"a.toml":    mk("a", "order = 2\nrequires = [\"core\"]\nconflicts = [\"b\"]\n"),
		"b.toml":    mk("b", "order = 3\nrequires = [\"core\"]\n"),
	}
	set, err := manifest.Load(mapFS(files), "m")
	if err != nil {
		t.Fatal(err)
	}
	r := resolve.New(set)
	_, err = r.Resolve([]string{"b", "a"})
	var ce *resolve.ConflictError
	if !errors.As(err, &ce) || ce.A != "a" || ce.B != "b" {
		t.Fatalf("got %v", err)
	}
	if !strings.Contains(err.Error(), "cannot be installed together") {
		t.Error(err)
	}
	if _, err := r.Resolve([]string{"a"}); err != nil {
		t.Error(err)
	}
}

func TestParseList(t *testing.T) {
	if got := resolve.ParseList("a, b,c  d"); !reflect.DeepEqual(got, []string{"a", "b", "c", "d"}) {
		t.Errorf("%v", got)
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}
