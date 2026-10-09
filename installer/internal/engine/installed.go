package engine

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/BurntSushi/toml"

	"serpx/installer/internal/journal"
)

// FileInstalled is the record of what is installed (plan 4.4, modes).
const FileInstalled = "installed.toml"

// Installed is installed.toml.
type Installed struct {
	Schema      int      `toml:"schema"`
	Build       string   `toml:"build"`
	Commit      string   `toml:"commit"`
	InstalledAt string   `toml:"installed_at"`
	Compositors []string `toml:"compositors"`
	Modules     []string `toml:"modules"`
}

// ErrNotInstalled: there is no installed.toml.
var ErrNotInstalled = errors.New("engine: nothing is installed (no installed.toml)")

// ReadInstalled loads installed.toml from the installer state dir.
func ReadInstalled(stateDir string) (*Installed, error) {
	b, err := os.ReadFile(filepath.Join(stateDir, FileInstalled))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotInstalled
	}
	if err != nil {
		return nil, err
	}
	var in Installed
	if err := toml.Unmarshal(b, &in); err != nil {
		return nil, err
	}
	return &in, nil
}

// WriteInstalled writes installed.toml atomically.
func WriteInstalled(stateDir string, in Installed, now time.Time) error {
	in.Schema = 1
	in.InstalledAt = now.Format(time.RFC3339)
	sort.Strings(in.Compositors)
	var buf bytes.Buffer
	if err := toml.NewEncoder(&buf).Encode(in); err != nil {
		return err
	}
	return journal.WriteAtomic(filepath.Join(stateDir, FileInstalled), buf.Bytes(), 0o600)
}

// RemoveInstalled deletes installed.toml.
func RemoveInstalled(stateDir string) error {
	err := os.Remove(filepath.Join(stateDir, FileInstalled))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
