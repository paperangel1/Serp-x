package steps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// DetectSystemLanguage is upstream detect_system_language: the language of
// LC_ALL/LC_MESSAGES/LANG if the shell ships a catalog for it, else "en".
func (e *Env) DetectSystemLanguage() string {
	loc := e.getenv("LC_ALL")
	if loc == "" {
		loc = e.getenv("LC_MESSAGES")
	}
	if loc == "" {
		loc = e.getenv("LANG")
	}
	if i := strings.IndexAny(loc, "_.@"); i >= 0 {
		loc = loc[:i]
	}
	lang := strings.ToLower(loc)
	if lang == "uk" {
		lang = "ua" // Ukrainian ships as ua.json
	}
	if lang != "" {
		if _, err := os.Stat(filepath.Join(e.Payload, "src/assets/languages", lang+".json")); err == nil {
			return lang
		}
	}
	return "en"
}

type jsonObj = map[string]any

func decodeObj(b []byte) (jsonObj, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber() // keep numbers verbatim, like jq
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	o, ok := v.(jsonObj)
	if !ok {
		return nil, errors.New("not a JSON object")
	}
	return o, nil
}

// mergeObjects is jq's recursive object multiplication `a * b` (b wins;
// objects merge, everything else is replaced).
func mergeObjects(a, b jsonObj) jsonObj {
	out := jsonObj{}
	for k, v := range a {
		out[k] = v
	}
	for k, bv := range b {
		if av, ok := out[k].(jsonObj); ok {
			if bo, ok := bv.(jsonObj); ok {
				out[k] = mergeObjects(av, bo)
				continue
			}
		}
		out[k] = bv
	}
	return out
}

func encodeObj(o jsonObj) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	enc.Encode(o)
	return buf.Bytes()
}

// BuildSettings is the jq merge of upstream init_serpantinum_config. existing
// may be nil (no/empty settings.json). The key order of the result is sorted
// (jq keeps insertion order); readers do not depend on it.
func BuildSettings(template, existing []byte, wallpaperDir, lang string) ([]byte, error) {
	t, err := decodeObj(template)
	if err != nil {
		return nil, fmt.Errorf("template settings.json: %w", err)
	}
	var wp jsonObj
	if wallpaperDir != "" {
		wp = jsonObj{"wallpaperDir": wallpaperDir}
	}
	if len(bytes.TrimSpace(existing)) == 0 {
		out := t
		if wp != nil {
			out = mergeObjects(out, wp)
		}
		return encodeObj(mergeObjects(out, jsonObj{"general": jsonObj{"language": lang}})), nil
	}
	c, err := decodeObj(existing)
	if err != nil {
		return nil, fmt.Errorf("existing settings.json: %w", err)
	}
	out := mergeObjects(t, c)
	if wp != nil {
		out = mergeObjects(out, wp)
	}
	if g, _ := c["general"].(jsonObj); g == nil || g["language"] == nil {
		out = mergeObjects(out, jsonObj{"general": jsonObj{"language": lang}})
	}
	return encodeObj(out), nil
}

type configStep struct{ Base }

func (e *Env) settingsFile() string { return filepath.Join(e.ConfigDir(), "settings.json") }

func (configStep) Check(_ context.Context, e *Env) (bool, error) {
	if e.isUpdate() {
		if e.Mode == ModeRepair {
			b, _ := os.ReadFile(e.settingsFile())
			return len(bytes.TrimSpace(b)) > 0, nil
		}
		return true, nil
	}
	return false, nil
}

func (configStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	if err := os.MkdirAll(e.ConfigDir(), 0o755); err != nil {
		return err
	}
	file := e.settingsFile()
	tmplPath := filepath.Join(e.Payload, "config/serpantinum/settings.json")
	wp := e.WallpaperDir()
	lang := e.DetectSystemLanguage()
	existing, err := readIfExists(file)
	if err != nil {
		return err
	}
	tmpl, terr := readIfExists(tmplPath)
	switch {
	case terr != nil:
		return terr
	case tmpl != nil:
		out, err := BuildSettings(tmpl, existing, wp, lang)
		if err != nil {
			if len(bytes.TrimSpace(existing)) > 0 {
				// jq failing left the user's file untouched; so do we
				rep.Warn("settings.json was not changed: " + err.Error())
				break
			}
			// no usable merge: cp template (upstream fallback)
			if werr := e.FS.Write("core.config", file, tmpl, 0o644); werr != nil {
				return werr
			}
			break
		}
		if err := e.FS.Write("core.config", file, out, 0o644); err != nil {
			return err
		}
	case existing == nil:
		body := []byte("{}\n")
		if wp != "" {
			b, _ := json.Marshal(wp)
			body = []byte(`{"wallpaperDir": ` + string(b) + "}\n")
		}
		if err := e.FS.Write("core.config", file, body, 0o644); err != nil {
			return err
		}
	}
	if e.Opts.Reinstall || e.Opts.InstallState == StateFresh || e.Opts.InstallState == StateLegacy {
		script := filepath.Join(e.Payload, "src/scripts/location.sh")
		if _, err := os.Stat(script); err != nil {
			script = filepath.Join(e.TargetBase(), "src/scripts/location.sh")
			if _, err := os.Stat(script); err != nil {
				return nil
			}
		}
		_, _ = e.Runner.Run(ctx, runCmd("bash", script, "--refresh")) // >/dev/null 2>&1 || true
	}
	return nil
}

// Verify: the file exists. A user file that is not valid JSON was left
// untouched on purpose (upstream: jq failure keeps it), so it only warns.
func (configStep) Verify(_ context.Context, e *Env) error {
	b, err := os.ReadFile(e.settingsFile())
	if err != nil {
		return err
	}
	if _, err := decodeObj(b); err != nil {
		e.rep().Warn(fmt.Sprintf("settings.json is not valid JSON: %v", err))
	}
	return nil
}

func (configStep) Rollback(_ context.Context, e *Env) error { return e.FS.Rollback("core.config") }
