package plan

import (
	"time"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/steps"
)

func seconds(s int) time.Duration { return time.Duration(s) * time.Second }

// DocStep is one step in plan.json.
type DocStep struct {
	ID     string        `json:"id"`
	Module string        `json:"module,omitempty"`
	Title  manifest.Text `json:"title"`
	Root   bool          `json:"root,omitempty"`
}

// Doc is plan.json: enough to resume a run. Secrets appear only as "set".
type Doc struct {
	Schema       int               `json:"schema"`
	Run          string            `json:"run"`
	Mode         steps.Mode        `json:"mode"`
	Version      string            `json:"version"`
	Commit       string            `json:"commit,omitempty"`
	Modules      []string          `json:"modules"`
	Compositors  []string          `json:"compositors"`
	InstallState string            `json:"install_state"`
	Reinstall    bool              `json:"reinstall,omitempty"`
	OldCommit    string            `json:"old_commit,omitempty"`
	Steps        []DocStep         `json:"steps"`
	Secrets      map[string]string `json:"secrets,omitempty"`
}

// NewDoc describes a built plan.
func NewDoc(run string, mode steps.Mode, version, commit string, modules []string, opts steps.Options, list []steps.Step) Doc {
	d := Doc{Schema: 1, Run: run, Mode: mode, Version: version, Commit: commit, Modules: modules,
		Compositors: opts.Compositors, InstallState: opts.InstallState, Reinstall: opts.Reinstall, OldCommit: opts.OldCommit}
	for _, s := range list {
		d.Steps = append(d.Steps, DocStep{ID: s.ID(), Module: s.Module(), Title: manifest.Text{RU: s.Title("ru"), EN: s.Title("en")}, Root: s.Root()})
	}
	for k, v := range opts.Secrets {
		if v != "" {
			if d.Secrets == nil {
				d.Secrets = map[string]string{}
			}
			d.Secrets[k] = "set"
		}
	}
	return d
}
