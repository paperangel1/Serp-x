package plan_test

import (
	"encoding/json"
	"strings"
	"testing"

	"serpx/installer"
	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plan"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/steps"
)

func load(t *testing.T) (*manifest.Set, *i18n.Catalog) {
	t.Helper()
	set, err := manifest.Load(installer.Manifests, "manifests")
	if err != nil {
		t.Fatal(err)
	}
	cat, err := i18n.Load(installer.I18N, "i18n")
	if err != nil {
		t.Fatal(err)
	}
	return set, cat
}

func build(t *testing.T, ids []string, mod func(*plan.Input)) []string {
	t.Helper()
	set, cat := load(t)
	sel, err := resolve.New(set).Resolve(ids)
	if err != nil {
		t.Fatal(err)
	}
	in := plan.Input{Set: set, Sel: sel, Cat: cat, Opts: steps.Options{Compositors: []string{"hyprland"}, InstallState: steps.StateFresh}}
	if mod != nil {
		mod(&in)
	}
	list, err := plan.Build(in)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, s := range list {
		out = append(out, s.ID())
	}
	return out
}

func idx(l []string, id string) int {
	for i, x := range l {
		if x == id {
			return i
		}
	}
	return -1
}

func TestFullSkeletonOrder(t *testing.T) {
	ids := build(t, []string{"core", "vpn", "commands", "sddm"}, nil)
	want := []string{
		"preflight", "sudo", "core.pre.multilib", "core.pre.tools", "core.pre.migrate", "core.pre.cleanup", "keyring", "aur-helper", "pkg.sync",
		"pkg.repo", "aur.wl-gammarelay-rs", "binary.xray", "deploy.code", "deploy.configs", "core.fonts", "core.config", "core.links",
		"vpn.root", "vpn.geo", "commands.unit", "commands.desktop", "sddm.theme", "sddm.enable", "secrets", "services", "core.state", "verify", "finish",
	}
	if strings.Join(ids, " ") != strings.Join(want, " ") {
		t.Fatalf("got\n%s\nwant\n%s", strings.Join(ids, "\n"), strings.Join(want, "\n"))
	}
}

func TestConditionalSteps(t *testing.T) {
	cur := build(t, []string{"core"}, func(in *plan.Input) { in.Opts.InstallState = steps.StateCurrent })
	if idx(cur, "pkg.sync") >= 0 {
		t.Error("a current install does not sync the system")
	}
	re := build(t, []string{"core"}, func(in *plan.Input) { in.Opts.Reinstall = true })
	if idx(re, "pkg.sync") >= 0 {
		t.Error("a reinstall does not sync the system")
	}
	if idx(build(t, []string{"core"}, nil), "core.wallpapers") >= 0 {
		t.Error("wallpaper sample is opt-in")
	}
	if idx(build(t, []string{"core"}, func(in *plan.Input) { in.Opts.WallpaperSample = true }), "core.wallpapers") < 0 {
		t.Error("wallpaper sample requested but missing")
	}
	if idx(build(t, []string{"core", "wallpapers"}, func(in *plan.Input) { in.Opts.WallpaperSample = true }), "core.wallpapers") >= 0 {
		t.Error("the full pack replaces the sample")
	}
	if idx(build(t, []string{"core"}, func(in *plan.Input) { in.Restore = true }), "restore") < 0 {
		t.Error("restore step missing")
	}
	if idx(build(t, []string{"core", "emoji"}, nil), "secrets") >= 0 || idx(build(t, []string{"core", "emoji"}, nil), "aur-helper") < 0 {
		t.Error("secrets only with secret questions; core always has the AUR package")
	}
	// secrets covered by a module step are not stored twice
	ids := build(t, []string{"core", "ai-gemini"}, nil)
	if idx(ids, "secrets") >= 0 || idx(ids, "ai-gemini.secret") < 0 {
		t.Errorf("ai-gemini: %v", ids)
	}
}

func TestPartialPlanForAddedModules(t *testing.T) {
	ids := build(t, []string{"core", "tools", "ocr"}, func(in *plan.Input) { in.Only = map[string]bool{"tools": true, "ocr": true} })
	want := "preflight sudo pkg.repo tools.notes core.state verify finish"
	if strings.Join(ids, " ") != want {
		t.Fatalf("got %v", ids)
	}
	none := build(t, []string{"core"}, func(in *plan.Input) { in.Only = map[string]bool{} })
	if strings.Join(none, " ") != "preflight sudo core.state verify finish" {
		t.Fatalf("got %v", none)
	}
}

func TestDocHidesSecretValues(t *testing.T) {
	set, cat := load(t)
	sel, _ := resolve.New(set).Resolve([]string{"core", "ai-gemini"})
	opts := steps.Options{Compositors: []string{"hyprland"}, InstallState: steps.StateFresh, Secrets: map[string]string{"ai.gemini_key": "AIzaFAKEkey0123456789abcdef", "servers.remnawave_token": ""}}
	list, err := plan.Build(plan.Input{Set: set, Sel: sel, Cat: cat, Opts: opts})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(plan.NewDoc("run", steps.ModeInstall, "2.2.4-s3", "abc", sel.Modules, opts, list))
	if strings.Contains(string(b), "AIzaFAKE") || !strings.Contains(string(b), `"ai.gemini_key":"set"`) || strings.Contains(string(b), "remnawave_token") {
		t.Fatalf("plan.json: %s", b)
	}
}

func TestEveryModuleCombinationBuilds(t *testing.T) {
	set, _ := load(t)
	for _, m := range set.List {
		ids := build(t, []string{m.ID}, nil)
		if idx(ids, "finish") != len(ids)-1 || idx(ids, "preflight") != 0 {
			t.Errorf("%s: bad plan %v", m.ID, ids)
		}
		for _, st := range m.Steps {
			if idx(ids, st.ID) < 0 && st.ID != "core.wallpapers" && !strings.HasPrefix(st.ID, "core.pre.") {
				t.Errorf("%s: step %s missing from the plan", m.ID, st.ID)
			}
		}
	}
}
