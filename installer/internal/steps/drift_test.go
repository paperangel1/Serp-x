package steps_test

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The steps in this package are ports of the upstream bash installer. When a
// merge from upstream changes one of those scripts, this test fails so that
// somebody re-reads the script and updates the port ("пересмотри порт").
//
// Ported from:
//   install/modules/deps.sh     -> packages.go, fonts.go, binary.go (bootstrap, install_pkg, install_fonts)
//   install/modules/deploy.sh   -> deploy.go, sddm.go, wallpapers.go
//   install/modules/config.sh   -> config.go
//   install/modules/service.sh  -> services.go
//   install/modules/migrate.sh  -> migrate.go
//   install/modules/state.sh    -> state.go (DetectInstallState)
//   install/modules/version.sh  -> state.go (write_version_state)
//   install/install.sh          -> plan/plan.go (order of the steps)
// ui.sh is not ported (the TUI replaces it) but a change is still reported.
//
// After the port was reviewed:  UPDATE_UPSTREAM_HASHES=1 go test ./internal/steps -run Drift

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, _ := os.Getwd()
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "install/modules/deps.sh")); err == nil {
			return dir
		}
		dir = filepath.Dir(dir)
	}
	t.Fatal("repo root with install/modules not found")
	return ""
}

func upstreamHashes(t *testing.T) map[string]string {
	t.Helper()
	root := repoRoot(t)
	files, _ := filepath.Glob(filepath.Join(root, "install/modules/*.sh"))
	files = append(files, filepath.Join(root, "install/install.sh"))
	out := map[string]string{}
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(b)
		rel, _ := filepath.Rel(root, f)
		out[filepath.ToSlash(rel)] = hex.EncodeToString(sum[:])
	}
	return out
}

func TestUpstreamInstallScriptsDrift(t *testing.T) {
	got := upstreamHashes(t)
	goldenPath := filepath.Join("testdata", "upstream.sha256")
	if os.Getenv("UPDATE_UPSTREAM_HASHES") == "1" {
		var keys []string
		for k := range got {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		for _, k := range keys {
			fmt.Fprintf(&b, "%s  %s\n", got[k], k)
		}
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(goldenPath, []byte(b.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	raw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 {
			want[f[1]] = f[0]
		}
	}
	for name, h := range got {
		w, ok := want[name]
		switch {
		case !ok:
			t.Errorf("%s is new upstream: review it and add it to the port (then UPDATE_UPSTREAM_HASHES=1)", name)
		case w != h:
			t.Errorf("%s changed upstream: пересмотри порт (see the header of this file), then UPDATE_UPSTREAM_HASHES=1", name)
		}
	}
	for name := range want {
		if _, ok := got[name]; !ok {
			t.Errorf("%s disappeared upstream: the port may be obsolete", name)
		}
	}
}

// Every package of upstream REQUIRED_PKGS (except the AUR-only one handled
// separately) must be in manifests/core.toml.
func TestCorePackagesCoverUpstreamRequired(t *testing.T) {
	root := repoRoot(t)
	sh, err := os.ReadFile(filepath.Join(root, "install/modules/deps.sh"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(sh)
	i := strings.Index(s, "REQUIRED_PKGS=(")
	if i < 0 {
		t.Fatal("REQUIRED_PKGS not found in deps.sh")
	}
	s = s[i:]
	s = s[:strings.Index(s, "\n)")]
	toml, err := os.ReadFile(filepath.Join(root, "installer/manifests/core.toml"))
	if err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(string(toml), -1) {
		have[m[1]] = true
	}
	n := 0
	for _, m := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(s, -1) {
		n++
		if !have[m[1]] {
			t.Errorf("upstream package %q is missing from installer/manifests/core.toml", m[1])
		}
	}
	if n < 60 {
		t.Errorf("parsed only %d packages from deps.sh", n)
	}
}
