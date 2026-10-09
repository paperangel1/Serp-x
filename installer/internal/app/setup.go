package app

import (
	"os"
	"path/filepath"
	"strings"

	"serpx/installer/internal/config"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/tui"
)

// my-setup.toml names <-> manifest config keys.
var (
	secretKeys = map[string]string{
		config.SecGeminiKey: "ai.gemini_key", config.SecRemnawaveURL: "servers.remnawave_url",
		config.SecRemnawaveToken: "servers.remnawave_token", config.SecVPNSubscription: "vpn.subscription",
	}
	optionKeys = map[string]string{
		"notes_dir": "tools.notes_dir", "gemini_proxy": "ai.proxy", "vpn_mode": "vpn.mode", "vpn_killswitch": "vpn.killswitch",
		"commands_start_daemon": "commands.start_daemon", "commands_examples": "commands.examples", "servers_generate_key": "servers.generate_key",
	}
)

func boolText(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// RequestFromConfig turns my-setup.toml (with resolved secrets) into a
// Request. tags are the detected hardware tags ("gpu:nvidia").
func RequestFromConfig(f *config.File, sec config.Resolved, set *manifest.Set, tags []string, restore string) (tui.Request, error) {
	r := resolve.New(set)
	var explicit []string
	switch f.Preset {
	case resolve.PresetFull, resolve.PresetMinimal:
		l, err := r.Preset(f.Preset, resolve.Detect{Tags: tags})
		if err != nil {
			return tui.Request{}, err
		}
		explicit = l
	}
	explicit = append(explicit, f.Modules...)
	if _, err := r.Resolve(explicit); err != nil {
		return tui.Request{}, err
	}
	req := tui.Request{Mode: tui.ModeInstall, Modules: explicit, Lang: f.Lang, Restore: restore,
		Config: map[string]string{}, Secrets: map[string]string{}}
	if f.Lang != "" {
		req.Config["core.language"] = f.Lang
	}
	for name, key := range secretKeys {
		if v := sec[name]; v != "" {
			req.Secrets[key] = v
		}
	}
	o := f.Options
	req.Config[optionKeys["notes_dir"]] = o.NotesDir
	req.Config[optionKeys["gemini_proxy"]] = o.GeminiProxy
	req.Config[optionKeys["vpn_mode"]] = o.VPNMode
	req.Config[optionKeys["vpn_killswitch"]] = boolText(o.VPNKillswitch)
	req.Config[optionKeys["commands_start_daemon"]] = boolText(o.CommandsStartDaemon)
	req.Config[optionKeys["commands_examples"]] = boolText(o.CommandsExamples)
	req.Config[optionKeys["servers_generate_key"]] = boolText(o.ServersGenerateKey)
	return req, nil
}

// ConfigFromRequest is the reverse mapping for "save as my-setup.toml".
// Secrets are never part of it.
func ConfigFromRequest(req tui.Request) config.File {
	f := config.Defaults()
	f.Preset = resolve.PresetCustom
	f.Modules = append([]string(nil), req.Modules...)
	f.Lang = req.Lang
	c := req.Config
	if v := c["tools.notes_dir"]; v != "" {
		f.Options.NotesDir = v
	}
	f.Options.GeminiProxy = c["ai.proxy"]
	if v := c["vpn.mode"]; v != "" {
		f.Options.VPNMode = v
	}
	f.Options.VPNKillswitch = c["vpn.killswitch"] == "true"
	if v, ok := c["commands.start_daemon"]; ok {
		f.Options.CommandsStartDaemon = v == "true"
	}
	if v, ok := c["commands.examples"]; ok {
		f.Options.CommandsExamples = v == "true"
	}
	if v, ok := c["servers.generate_key"]; ok {
		f.Options.ServersGenerateKey = v == "true"
	}
	return f
}

// ExportSetup implements tui.Backend: ~/serpantinum-backups/my-setup.toml.
func (s *Service) ExportSetup(req tui.Request) (string, error) {
	data, err := ConfigFromRequest(req).Marshal()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(s.BackupDir(), 0o700); err != nil {
		return "", err
	}
	p := filepath.Join(s.BackupDir(), "my-setup.toml")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return "", err
	}
	return s.display(p), nil
}

// ExportConfig renders my-setup.toml for the current system (export-config):
// installed modules, language of the shell and the saved non-secret options.
func (s *Service) ExportConfig(lang string) ([]byte, error) {
	f := config.Defaults()
	f.Preset = resolve.PresetCustom
	f.Lang = lang
	if in := s.Installed(); in != nil {
		f.Modules = in.Modules
	}
	if b, err := os.ReadFile(filepath.Join(s.home, ".config", "serpantinum", "settings.json")); err == nil {
		applySettings(&f, b)
	}
	if b, err := os.ReadFile(filepath.Join(s.home, ".config", "serpantinum-x", "modules.json")); err == nil {
		_ = b // the module flags mirror installed.toml
	}
	return f.Marshal()
}

func applySettings(f *config.File, b []byte) {
	get := func(key string) string { return jsonString(b, key) }
	if v := get("ai.proxy"); v != "" {
		f.Options.GeminiProxy = v
	}
	if v := get("vpn.mode"); v == "ru-direct" || v == "all" {
		f.Options.VPNMode = v
	}
	f.Options.VPNKillswitch = strings.EqualFold(get("vpn.killswitch"), "true")
}
