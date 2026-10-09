// Package plan builds the ordered step list (installer plan 4.2) from the
// manifests, the resolved module selection and the run options, and
// serialises it to plan.json (never with secret values).
package plan

import (
	"fmt"
	"sort"
	"strings"

	"serpx/installer/internal/i18n"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/resolve"
	"serpx/installer/internal/steps"
)

// Input of Build.
type Input struct {
	Set     *manifest.Set
	Sel     *resolve.Selection
	Cat     *i18n.Catalog
	Opts    steps.Options
	Restore bool // add the restore step
	// Only restricts the module-scoped parts (packages, AUR, binaries, module
	// steps) to these modules and drops the one-time skeleton (modules mode:
	// "add what was selected since the last run"). nil = everything.
	Only map[string]bool
	// WriteInstalled is run by the finish step (installed.toml).
	WriteInstalled func(*steps.Env) error
}

func (in Input) text(key string, kv ...string) manifest.Text {
	return manifest.Text{RU: in.Cat.T("ru", key, kv...), EN: in.Cat.T("en", key, kv...)}
}

func (in Input) base(id, mod, key string, root bool, est int, kv ...string) steps.Base {
	return steps.Base{StepID: id, Mod: mod, Text: in.text(key, kv...), NeedsRoot: root, Est: seconds(est)}
}

// Build returns the steps in execution order.
func Build(in Input) ([]steps.Step, error) {
	full := in.Only == nil
	inScope := func(id string) bool { return full || in.Only[id] }
	var (
		pkgs, aurPkgs []string
		aurOwner      = map[string]string{}
		bins          []struct {
			mod string
			b   manifest.Binary
		}
		seen = map[string]bool{}
	)
	addPkg := func(p string) {
		if !seen[p] {
			seen[p] = true
			pkgs = append(pkgs, p)
		}
	}
	for _, id := range in.Sel.Modules {
		m, _ := in.Set.Get(id)
		if !inScope(id) {
			continue
		}
		for _, p := range m.Packages {
			addPkg(p)
		}
		for _, p := range m.AUR {
			aurPkgs = append(aurPkgs, p)
			aurOwner[p] = id
		}
		for _, b := range m.Binary {
			bins = append(bins, struct {
				mod string
				b   manifest.Binary
			}{id, b})
		}
	}
	if full {
		for _, c := range in.Opts.Compositors {
			addPkg(c)
		}
	}

	var out []steps.Step
	add := func(s steps.Step) { out = append(out, s) }

	core := in.Set.Core()
	var pre, late []manifest.Step
	moduleSteps := map[string][]manifest.Step{}
	for _, id := range in.Sel.Modules {
		m, _ := in.Set.Get(id)
		if !inScope(id) && !(id == core.ID && !full) {
			continue
		}
		for _, st := range orderSteps(m.Steps) {
			switch {
			case id == core.ID && strings.HasPrefix(st.ID, "core.pre."):
				pre = append(pre, st)
			case st.ID == "core.state":
				late = append(late, st)
			case st.ID == "core.wallpapers" && !(in.Opts.WallpaperSample && !in.Sel.Has("wallpapers")):
			case id == core.ID && !full && st.ID != "core.state":
			default:
				moduleSteps[id] = append(moduleSteps[id], st)
			}
		}
	}
	fromManifest := func(modID string, st manifest.Step) error {
		m, _ := in.Set.Get(modID)
		s, err := steps.FromManifest(m, st)
		if err != nil {
			return err
		}
		add(s)
		return nil
	}

	add(steps.NewPreflight(in.base("preflight", "", "step.preflight", false, 5)))
	add(steps.NewSudo(in.base("sudo", "", "step.sudo", true, 1)))
	if full {
		for _, st := range pre {
			if err := fromManifest(core.ID, st); err != nil {
				return nil, err
			}
		}
		add(steps.NewKeyring(in.base("keyring", "", "step.keyring", true, 20)))
		if len(aurPkgs) > 0 {
			add(steps.NewAURHelper(in.base("aur-helper", "", "step.aur_helper", false, 120)))
		}
		if !in.Opts.Reinstall && (in.Opts.InstallState == steps.StateFresh || in.Opts.InstallState == steps.StateLegacy) {
			add(steps.NewSync(in.base("pkg.sync", "", "step.pkg_sync", true, 240)))
		}
	} else if len(aurPkgs) > 0 {
		add(steps.NewAURHelper(in.base("aur-helper", "", "step.aur_helper", false, 120)))
	}
	if len(pkgs) > 0 {
		add(steps.NewRepo(in.base("pkg.repo", "", "step.pkg_repo", true, 540, "n", fmt.Sprint(len(pkgs))), pkgs))
	}
	for _, p := range aurPkgs {
		b := in.base("aur."+p, aurOwner[p], "step.aur", false, 240, "pkg", p)
		add(steps.NewAUR(b, p))
	}
	for _, x := range bins {
		add(steps.NewBinary(in.base("binary."+x.b.Name, x.mod, "step.binary", true, 20, "name", x.b.Name), x.b))
	}
	if full {
		add(steps.NewDeployCode(in.base("deploy.code", core.ID, "step.deploy_code", false, 30)))
		add(steps.NewDeployConfigs(in.base("deploy.configs", core.ID, "step.deploy_configs", false, 5)))
	}
	for _, id := range in.Sel.Modules {
		for _, st := range moduleSteps[id] {
			if err := fromManifest(id, st); err != nil {
				return nil, err
			}
		}
	}
	if keys := uncoveredSecrets(in); len(keys) > 0 {
		add(steps.NewSecrets(in.base("secrets", "", "step.secrets", false, 1), keys))
	}
	if in.Restore {
		add(steps.NewRestore(in.base("restore", "", "step.restore", false, 20)))
	}
	if full || hasServices(in) {
		add(steps.NewServices(in.base("services", core.ID, "step.services", true, 10)))
	}
	for _, st := range late {
		if err := fromManifest(core.ID, st); err != nil {
			return nil, err
		}
	}
	add(steps.NewVerify(in.base("verify", "", "step.verify", false, 2)))
	add(steps.NewFinish(in.base("finish", "", "step.finish", false, 1), in.WriteInstalled))
	return out, nil
}

func hasServices(in Input) bool {
	for _, id := range in.Sel.Modules {
		if m, _ := in.Set.Get(id); m != nil && in.Only[id] && len(m.SystemdSys)+len(m.SystemdUser) > 0 {
			return true
		}
	}
	return false
}

// uncoveredSecrets are the secret answers no module step stores itself.
func uncoveredSecrets(in Input) []string {
	covered := map[string]bool{}
	var all []string
	for _, id := range in.Sel.Modules {
		if in.Only != nil && !in.Only[id] {
			continue
		}
		m, _ := in.Set.Get(id)
		for _, st := range m.Steps {
			if st.Kind != "secret" {
				continue
			}
			if k, _ := st.Args["key"].(string); k != "" {
				covered[k] = true
			}
			if ks, ok := st.Args["keys"].([]any); ok {
				for _, k := range ks {
					if s, ok := k.(string); ok {
						covered[s] = true
					}
				}
			}
		}
		for _, c := range m.Config {
			if c.Kind == "secret" && strings.HasPrefix(c.Store, "secrets/") {
				all = append(all, c.Key)
			}
		}
	}
	var out []string
	for _, k := range all {
		if !covered[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// orderSteps sorts a module's steps so `after` dependencies come first
// (stable otherwise). Cycles are rejected by manifest validation.
func orderSteps(in []manifest.Step) []manifest.Step {
	done := map[string]bool{}
	var out []manifest.Step
	for len(out) < len(in) {
		progressed := false
		for _, st := range in {
			if done[st.ID] {
				continue
			}
			ready := true
			for _, a := range st.After {
				if !done[a] {
					ready = false
				}
			}
			if ready {
				done[st.ID] = true
				out = append(out, st)
				progressed = true
				break
			}
		}
		if !progressed { // `after` pointing outside the module: keep file order
			for _, st := range in {
				if !done[st.ID] {
					done[st.ID] = true
					out = append(out, st)
				}
			}
		}
	}
	return out
}
