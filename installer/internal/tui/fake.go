package tui

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/preflight"
)

// FakeBackend is a scripted Backend for tests and for trying the UI without
// the engine. It never touches the system.
type FakeBackend struct {
	SetV       *manifest.Set
	Report     preflight.Report
	InstalledV *Installed
	Key        SSHKey
	LogFile    string
	// Fail maps a step id to the number of times it fails before it works.
	Fail map[string]int
	// Optional marks failing steps as skippable (default true).
	NotOptional bool
	RunErr      error

	mu      sync.Mutex
	Calls   []string
	Last    Request
	Saved   map[string]string
	Decided []plain.Decision
}

func (f *FakeBackend) rec(s string) {
	f.mu.Lock()
	f.Calls = append(f.Calls, s)
	f.mu.Unlock()
}

// Set implements Backend.
func (f *FakeBackend) Set() *manifest.Set { return f.SetV }

// Preflight implements Backend.
func (f *FakeBackend) Preflight(context.Context) preflight.Report {
	f.rec("preflight")
	return f.Report
}

// Installed implements Backend.
func (f *FakeBackend) Installed() *Installed { return f.InstalledV }

// LogPath implements Backend.
func (f *FakeBackend) LogPath() string {
	if f.LogFile == "" {
		return "~/.local/state/serpantinum-installer/logs/0712-1904.log"
	}
	return f.LogFile
}

// Plan implements Backend: a short deterministic plan.
func (f *FakeBackend) Plan(_ context.Context, r Request) (PlanInfo, error) {
	f.rec("plan:" + r.Mode)
	var p PlanInfo
	add := func(id, mod, ru, en string, root bool, est int) {
		p.Steps = append(p.Steps, StepInfo{ID: id, Module: mod, Title: manifest.Text{RU: ru, EN: en}, Root: root, EstSec: est})
		p.Seconds += est
	}
	switch r.Mode {
	case ModeRepair:
		add("repair.files", "", "Проверка файлов", "File check", false, 10)
		add("repair.pkgs", "", "Недостающие пакеты", "Missing packages", true, 5)
		return p, nil
	case ModeUninstall:
		add("un.links", "", "Ссылки и код", "Links and code", false, 3)
		add("un.state", "", "Записи установки", "Install records", false, 1)
		return p, nil
	}
	add("pre.backup", "", "Бэкап твоих данных", "Backup of your data", false, 3)
	add("core.keys", "core", "Ключи pacman", "pacman keys", true, 9)
	add("core.packages", "core", "Программы оболочки (63 пакета)", "Shell programs (63 packages)", true, 120)
	sel := r.Modules
	for _, id := range sel {
		if id == "core" {
			continue
		}
		x, ok := f.SetV.Get(id)
		if !ok {
			continue
		}
		add(id+".install", id, x.Name.RU+": установка", x.Name.EN+": install", x.Core, 10)
	}
	add("core.verify", "core", "Проверка: всё ли на месте", "Check: is everything in place", false, 10)
	p.DownloadMiB, p.DiskMiB = 1360, 4100
	return p, nil
}

// Run implements Backend by replaying the plan.
func (f *FakeBackend) Run(ctx context.Context, r Request, h Handler) (RunResult, error) {
	f.mu.Lock()
	f.Last = r
	f.mu.Unlock()
	f.rec("run:" + r.Mode)
	plan, _ := f.Plan(ctx, r)
	res := RunResult{BackupPath: "~/serpantinum-backups/serpantinum-backup-2026-10-07.tar.zst", ConfigPath: "~/serpantinum-backups/my-setup.toml"}
	h.PlanStart(len(plan.Steps))
	skipped := map[string]bool{}
	for i, s := range plan.Steps {
		for {
			if err := ctx.Err(); err != nil {
				return res, err
			}
			if s.Module != "" && skipped[s.Module] {
				break
			}
			h.StepStart(s.ID, s.Title.EN, i+1, len(plan.Steps))
			h.StepLog(s.ID, "engine start "+s.ID)
			h.StepProgress(s.ID, 50)
			h.Detail(s.ID, Detail{DoneMiB: 412, TotalMiB: 961, SpeedMBs: 11.2, File: "qt6-declarative"})
			f.mu.Lock()
			fail := f.Fail[s.ID] > 0
			if fail {
				f.Fail[s.ID]--
			}
			f.mu.Unlock()
			if fail {
				err := fmt.Errorf("dial tcp: lookup proxy.golang.org: i/o timeout (%s)", s.ID)
				h.StepFail(s.ID, err)
				optional := !f.NotOptional && s.Module != "" && s.Module != "core"
				d := h.Decide(s.ID, err, optional, []string{"==> Starting build()...", "dial tcp: lookup proxy.golang.org: i/o timeout", "==> ERROR: A failure occurred in build(). Aborting..."})
				f.mu.Lock()
				f.Decided = append(f.Decided, d)
				f.mu.Unlock()
				switch d {
				case plain.Retry:
					continue
				case plain.Skip:
					skipped[s.Module] = true
					res.Skipped = append(res.Skipped, s.Module)
				default:
					return res, errors.New("aborted")
				}
				break
			}
			h.StepDone(s.ID, false)
			break
		}
	}
	if f.RunErr != nil {
		return res, f.RunErr
	}
	h.Finish(true)
	return res, nil
}

// GenSSHKey implements Backend.
func (f *FakeBackend) GenSSHKey(context.Context) (SSHKey, error) {
	f.rec("sshkey")
	if f.Key.Line == "" {
		return SSHKey{
			Path:        "~/.config/serpantinum/servers/id_serp",
			Fingerprint: "SHA256:Q3c.example",
			Line:        `restrict,command="/usr/local/sbin/serp-run" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyFakeFakeFakeFake0000 serpantinum`,
		}, nil
	}
	return f.Key, nil
}

// SaveAuthorizedKeys implements Backend.
func (f *FakeBackend) SaveAuthorizedKeys(line string) (string, error) {
	f.rec("save-authkeys")
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Saved == nil {
		f.Saved = map[string]string{}
	}
	f.Saved["authkeys"] = line
	return "~/serp-authorized_keys.txt", nil
}

// ExportSetup implements Backend.
func (f *FakeBackend) ExportSetup(r Request) (string, error) {
	f.rec("export")
	return "~/serpantinum-backups/my-setup.toml", nil
}
