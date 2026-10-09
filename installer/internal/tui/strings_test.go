package tui

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"serpx/installer/internal/plain"
)

var verbRe = regexp.MustCompile(`%[sd]`)

func TestStringsComplete(t *testing.T) {
	for k, v := range msgs {
		if v[0] == "" || v[1] == "" {
			t.Errorf("%s: empty translation", k)
		}
		if a, b := verbRe.FindAllString(v[0], -1), verbRe.FindAllString(v[1], -1); strings.Join(a, "") != strings.Join(b, "") {
			t.Errorf("%s: format verbs differ: %v vs %v", k, a, b)
		}
	}
}

func TestStringKeysExist(t *testing.T) {
	files, _ := filepath.Glob("*.go")
	re := regexp.MustCompile(`\bt\("([^"]+)"`)
	var dyn []string
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, _ := os.ReadFile(f)
		for _, m := range re.FindAllStringSubmatch(string(b), -1) {
			k := m[1]
			if strings.HasSuffix(k, ".") || strings.HasSuffix(k, "_") {
				dyn = append(dyn, k)
				continue
			}
			if _, ok := msgs[k]; !ok {
				t.Errorf("%s: key %q is not defined", f, k)
			}
		}
	}
	has := func(k string) {
		if _, ok := msgs[k]; !ok {
			t.Errorf("missing key %q", k)
		}
	}
	modes := []string{ModeInstall, ModeRepair, ModeModules, ModeUninstall}
	for _, o := range []string{optResume, optRepair, optModules, optUninstall, optReinstall, optInstall} {
		for _, suf := range []string{"", ".sub", ".what", ".time"} {
			has("i2." + o + suf)
		}
		has("i2.title_" + o)
	}
	for _, md := range modes {
		has("s.ready." + md)
		has("s.will_do." + md)
		has("b.start." + md)
		has("fin.done_in." + md)
	}
	for _, p := range []string{"full", "minimal", "custom"} {
		has("i3.p_" + p)
	}
	for _, b := range []string{"save", "check", "skip", "next"} {
		has("b." + b)
	}
	for _, k := range []string{"net", "keys", "disk", "lock", "generic"} {
		has("e.hint." + k)
	}
	for _, d := range []plain.Decision{plain.Retry, plain.Skip, plain.Abort} {
		has("e.b." + d.String())
	}
	for _, a := range []string{ActionReboot, ActionHyprland, ActionExit} {
		has("fin.b." + a)
	}
	set := loadSet(t)
	for _, x := range set.List {
		if len(x.Config) > 0 {
			has("w.title." + x.ID)
			has("w.intro." + x.ID)
		}
		for _, c := range x.Config {
			for _, ch := range c.Choices {
				has("ch." + ch)
			}
		}
	}
	_ = dyn
}

func TestTrDoesNotBreakOnPercent(t *testing.T) {
	if got := tr("ru", "i1.title"); got == "" {
		t.Fatal("empty")
	}
	if tr("ru", "nope") != "nope" {
		t.Fatal("unknown key must come back as is")
	}
}
