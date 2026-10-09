package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"serpx/installer/internal/run"
	"serpx/installer/internal/tui"
)

// AuthorizedPrefix is the exact option set of the key line: only the
// allowlist wrapper may run, no shell, no forwarding.
const AuthorizedPrefix = `restrict,command="/usr/local/sbin/serp-run" `

// KeyDir is ~/.config/serpantinum/servers.
func (s *Service) KeyDir() string { return filepath.Join(s.home, ".config", "serpantinum", "servers") }

// GenSSHKey implements tui.Backend: creates id_serp (ed25519, no passphrase,
// comment "serpantinum") unless it exists, and returns the exact line for
// authorized_keys. The private key is never read or returned.
func (s *Service) GenSSHKey(ctx context.Context) (tui.SSHKey, error) {
	dir := s.KeyDir()
	priv := filepath.Join(dir, "id_serp")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tui.SSHKey{}, err
	}
	if _, err := os.Stat(priv); errors.Is(err, os.ErrNotExist) {
		if _, err := s.runner().Run(ctx, run.Cmd{Name: "ssh-keygen", Args: []string{"-q", "-t", "ed25519", "-N", "", "-C", "serpantinum", "-f", priv}}); err != nil {
			return tui.SSHKey{}, fmt.Errorf("ssh-keygen: %w", err)
		}
		_ = os.Chmod(priv, 0o600)
	}
	pub, err := os.ReadFile(priv + ".pub")
	if err != nil {
		return tui.SSHKey{}, err
	}
	line := strings.TrimSpace(string(pub))
	k := tui.SSHKey{Path: s.display(priv), Line: AuthorizedPrefix + line}
	if res, err := s.runner().Run(ctx, run.Cmd{Name: "ssh-keygen", Args: []string{"-l", "-f", priv + ".pub"}}); err == nil {
		if f := strings.Fields(res.Stdout); len(f) >= 2 {
			k.Fingerprint = f[1]
		}
	}
	return k, nil
}

// display shortens the home directory to ~.
func (s *Service) display(p string) string {
	if s.home != "" && strings.HasPrefix(p, s.home+"/") {
		return "~" + p[len(s.home):]
	}
	return p
}

// SaveAuthorizedKeys implements tui.Backend.
func (s *Service) SaveAuthorizedKeys(line string) (string, error) {
	p := filepath.Join(s.home, "serp-authorized_keys.txt")
	if err := os.WriteFile(p, []byte(line+"\n"), 0o644); err != nil {
		return "", err
	}
	return s.display(p), nil
}
