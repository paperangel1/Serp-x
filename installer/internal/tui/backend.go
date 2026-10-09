// Package tui is the full-screen installer (screens I1-I11 of the mockups).
// All decisions live in the models (Update and the small pure helpers); View
// only draws. The engine is reached through the Backend interface, so the
// tests drive the whole UI with FakeBackend and never run a real command.
package tui

import (
	"context"
	"time"

	"serpx/installer/internal/eta"
	"serpx/installer/internal/manifest"
	"serpx/installer/internal/plain"
	"serpx/installer/internal/preflight"
)

// Modes of a Request.
const (
	ModeInstall   = "install"
	ModeRepair    = "repair"
	ModeModules   = "modules"
	ModeUninstall = "uninstall"
)

// Request is everything the wizard collected. It contains secret values:
// never print or log it.
type Request struct {
	Mode       string
	Modules    []string // explicit module choice (install, modules)
	Config     map[string]string
	Secrets    map[string]string
	Lang       string
	Restore    string
	Resume     bool
	Reinstall  bool
	RemoveData bool
}

// StepInfo is one planned step.
type StepInfo struct {
	ID     string
	Module string
	Title  manifest.Text
	Root   bool
	EstSec int
}

// PlanInfo is the plan of a Request (before it runs).
type PlanInfo struct {
	Steps       []StepInfo
	Items       []eta.Item
	ETA         *eta.Model // optional, with the history loaded
	DownloadMiB float64
	DiskMiB     float64
	Seconds     int
}

// Installed describes the existing installation (installed.toml).
type Installed struct {
	Build       string
	InstalledAt time.Time
	Modules     []string
}

// SSHKey is the key generated for the servers widget.
type SSHKey struct {
	Path        string
	Fingerprint string
	Line        string // the exact authorized_keys line
}

// Detail is the live data of a download step.
type Detail struct {
	DoneMiB, TotalMiB, SpeedMBs float64
	File                        string
}

// RunResult is what a finished run reports.
type RunResult struct {
	Skipped    []string // modules the user skipped after an error
	BackupPath string
	ConfigPath string
	Restored   string   // human summary of restored data ("" = none)
	Retype     []string // secrets that are not part of a backup and must be entered again
}

// Handler receives the progress of Run (the TUI implements it).
type Handler interface {
	plain.Sink
	Detail(id string, d Detail)
	// Decide blocks until the user chose what to do with a failed step.
	Decide(id string, err error, optional bool, tail []string) plain.Decision
}

// Backend is the engine as the TUI sees it.
type Backend interface {
	Set() *manifest.Set
	Preflight(ctx context.Context) preflight.Report
	Installed() *Installed
	Plan(ctx context.Context, r Request) (PlanInfo, error)
	Run(ctx context.Context, r Request, h Handler) (RunResult, error)
	GenSSHKey(ctx context.Context) (SSHKey, error)
	SaveAuthorizedKeys(line string) (path string, err error)
	ExportSetup(r Request) (path string, err error)
	LogPath() string
}

// Final actions of the finish screen.
const (
	ActionExit     = "exit"
	ActionReboot   = "reboot"
	ActionHyprland = "hyprland"
)

// Result is what Run returns to main.
type Result struct {
	Action string // exit | reboot | hyprland
	OK     bool   // the run finished successfully
	Err    error
}
