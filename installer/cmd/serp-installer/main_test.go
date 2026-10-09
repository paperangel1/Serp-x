package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runCLI runs the program with a temporary HOME/XDG so nothing outside the
// temp dir is touched.
func runCLI(t *testing.T, env map[string]string, args ...string) (code int, out, errOut string, home string) {
	t.Helper()
	home = t.TempDir()
	e := map[string]string{
		"HOME": home, "XDG_STATE_HOME": filepath.Join(home, "state"),
		"XDG_CONFIG_HOME": filepath.Join(home, "config"), "LANG": "en_US.UTF-8",
	}
	for k, v := range env {
		e[k] = v
	}
	var o, er bytes.Buffer
	code = run(args, &o, &er, func(k string) string { return e[k] })
	return code, o.String(), er.String(), home
}

func TestDryRunFullPlanEnglish(t *testing.T) {
	code, out, errOut, home := runCLI(t, nil, "install", "--dry-run", "--plain")
	if code != 0 || errOut != "" {
		t.Fatalf("code %d err %q", code, errOut)
	}
	for _, want := range []string{
		"Plan: ", "(core, hotkeys, emoji, tools, ocr, ai-gemini, servers, vpn, commands, commands-media)",
		"[ 1/33] System check", "AUR package: wl-gammarelay-rs", "Download and verify: xray",
		"VPN: system service (disabled)", "(needs sudo)", "Dry run: nothing was changed.", "Final check", "Done",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "nvidia") || strings.Contains(out, "sddm") {
		t.Error("optional system modules in the full plan without detection")
	}
	// only the log may appear under HOME
	var files []string
	_ = filepath.Walk(home, func(p string, i os.FileInfo, _ error) error {
		if !i.IsDir() {
			files = append(files, strings.TrimPrefix(p, home))
		}
		return nil
	})
	if len(files) != 1 || files[0] != "/state/serpantinum/logs/installer.log" {
		t.Errorf("unexpected files %v", files)
	}
}

func TestDryRunRussianByLocale(t *testing.T) {
	code, out, _, _ := runCLI(t, map[string]string{"LANG": "ru_RU.UTF-8"}, "install", "--dry-run", "--plain")
	if code != 0 || !strings.Contains(out, "Проверка системы") || !strings.Contains(out, "Пробный запуск") {
		t.Fatalf("code %d\n%s", code, out)
	}
	_, out, _, _ = runCLI(t, map[string]string{"LANG": "ru_RU.UTF-8"}, "install", "--dry-run", "--lang", "en")
	if !strings.Contains(out, "System check") {
		t.Error("--lang en ignored")
	}
}

func TestFlagsAfterSubcommand(t *testing.T) {
	code, out, _, _ := runCLI(t, nil, "--plain", "install", "--preset", "minimal", "--dry-run")
	if code != 0 || !strings.Contains(out, "(core, hotkeys, emoji)") {
		t.Fatalf("code %d\n%s", code, out)
	}
	if strings.Contains(out, "AUR") && !strings.Contains(out, "wl-gammarelay") {
		t.Error("odd plan")
	}
}

func TestCustomAndAutoDependencies(t *testing.T) {
	code, out, _, _ := runCLI(t, nil, "install", "--dry-run", "--preset", "custom", "--modules", "commands-media")
	if code != 0 || !strings.Contains(out, "(core, commands, commands-media)") ||
		!strings.Contains(out, "commands: auto: needed for commands-media") {
		t.Fatalf("code %d\n%s", code, out)
	}
	if strings.Contains(out, "xray") {
		t.Error("vpn pulled in unexpectedly")
	}
}

func TestNvidiaOnlyWithDetection(t *testing.T) {
	_, out, _, _ := runCLI(t, nil, "install", "--dry-run", "--gpu", "nvidia")
	if !strings.Contains(out, "NVIDIA: enable modeset") {
		t.Errorf("nvidia missing:\n%s", out)
	}
}

func TestRestoreAddsStep(t *testing.T) {
	_, out, _, _ := runCLI(t, nil, "install", "--dry-run", "--restore", "b.tar.zst", "--preset", "minimal")
	if !strings.Contains(out, "Restoring from backup") {
		t.Errorf("no restore step:\n%s", out)
	}
}

func TestExitCodes(t *testing.T) {
	cases := []struct {
		name string
		args []string
		code int
		err  string
	}{
		{"no command", nil, exitUsage, ""},
		{"unknown command", []string{"frobnicate"}, exitUsage, "Unknown command: frobnicate"},
		{"unknown flag", []string{"--nope", "install"}, exitUsage, "nope"},
		{"bad lang", []string{"--lang", "de", "install"}, exitUsage, "--lang"},
		{"bad glyphs", []string{"--glyphs", "x", "install"}, exitUsage, "--glyphs"},
		{"bad preset", []string{"install", "--dry-run", "--preset", "huge"}, exitUsage, "Unknown preset: huge"},
		{"unknown module", []string{"install", "--dry-run", "--preset", "custom", "--modules", "zzz"}, exitUsage, "Unknown module: zzz"},
		{"backup without action", []string{"backup"}, exitUsage, "backup export"},
		{"backup unknown action", []string{"backup", "frob"}, exitUsage, "backup export"},
	}
	for _, c := range cases {
		code, _, errOut, _ := runCLI(t, nil, c.args...)
		if code != c.code || !strings.Contains(errOut, c.err) {
			t.Errorf("%s: code %d (want %d), stderr %q (want %q)", c.name, code, c.code, errOut, c.err)
		}
	}
}

func TestVersionAndUsage(t *testing.T) {
	code, out, _, _ := runCLI(t, nil, "--version")
	if code != 0 || !strings.HasPrefix(out, "serp-installer dev") {
		t.Errorf("%d %q", code, out)
	}
	code, out, _, _ = runCLI(t, map[string]string{"LANG": "ru_RU.UTF-8"})
	if code != exitUsage || !strings.Contains(out, "Использование") || !strings.Contains(out, "export-config") {
		t.Errorf("%d %q", code, out)
	}
}

func TestNoSecretsOrTelemetryInPlan(t *testing.T) {
	_, out, _, _ := runCLI(t, nil, "install", "--dry-run")
	for _, bad := range []string{"telemetry", "workers.dev", "AIza"} {
		if strings.Contains(strings.ToLower(out), strings.ToLower(bad)) {
			t.Errorf("%q in plan", bad)
		}
	}
}
