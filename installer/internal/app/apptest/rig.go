// Package apptest builds a fully simulated environment for tests of the
// service and the command line: a temp HOME, a fake root filesystem, the
// pacman/systemd simulator behind the runner, a fake downloader and a small
// payload. Nothing here ever runs a real command.
package apptest

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"

	"serpx/installer/internal/app"
	"serpx/installer/internal/backup"
	"serpx/installer/internal/preflight"
	"serpx/installer/internal/run"
	"serpx/installer/internal/steps"
	"serpx/installer/internal/steps/stepstest"
)

// Rig is the simulated machine.
type Rig struct {
	T    testing.TB
	Home string
	Sim  *stepstest.Sim
	DL   *stepstest.FakeDL
	Env  map[string]string
	Cfg  app.Config
}

// Getenv reads the rig's environment.
func (r *Rig) Getenv(k string) string { return r.Env[k] }

// New builds the rig. The manifests' xray hash is re-pinned to the fake zip
// (the real hash is checked by the manifest tests).
func New(t testing.TB) *Rig {
	t.Helper()
	fx := stepstest.New(t)
	home := fx.Env.Home
	for _, m := range fx.Env.Set.List {
		for _, p := range m.Packages {
			fx.Sim.Repo[p] = true
		}
	}
	fx.Sim.Repo["hyprland"] = true
	for _, m := range fx.Env.Set.List {
		for i := range m.Binary {
			var b bytes.Buffer
			zw := zip.NewWriter(&b)
			w, _ := zw.Create(m.Binary[i].ArchiveMember)
			w.Write([]byte("FAKE"))
			zw.Close()
			sum := sha256.Sum256(b.Bytes())
			m.Binary[i].SHA256 = hex.EncodeToString(sum[:])
			fx.DL.Files[m.Binary[i].URL] = b.Bytes()
		}
	}
	var fb bytes.Buffer
	fz := zip.NewWriter(&fb)
	fw, _ := fz.Create("IosevkaNerdFont-Regular.ttf")
	fw.Write([]byte("ttf"))
	fz.Close()
	fx.DL.Files[steps.FontsURL] = fb.Bytes()
	stepstest.Write(t, fx.Env.Rootfs, "etc/pacman.conf", "#[multilib]\n#Include = x\n", 0o644)

	env := map[string]string{"HOME": home, "SERPANTINUM_LOG_DIR": filepath.Join(home, "logs"), "LANG": "en_US.UTF-8", "TERM": "xterm-256color"}
	r := &Rig{T: t, Home: home, Sim: fx.Sim, DL: fx.DL, Env: env}
	// preflight inputs: an Arch machine with 8 GB, a lot of disk, no GPU
	etc := t.TempDir()
	stepstest.Write(t, etc, "os-release", "ID=arch\nNAME=\"Arch Linux\"\n", 0o644)
	stepstest.Write(t, etc, "meminfo", "MemTotal:        8000000 kB\n", 0o644)
	deps := &preflight.Deps{
		OSRelease: filepath.Join(etc, "os-release"), SysRoot: filepath.Join(etc, "sys"), ProcMeminfo: filepath.Join(etc, "meminfo"),
		Home: home, StateDir: filepath.Join(home, ".local/state/serpantinum-installer"), Getenv: r.Getenv,
		Geteuid:  func() int { return 1000 },
		LookPath: func(n string) (string, error) { return "/usr/bin/" + n, nil },
		Statfs:   func(string) (uint64, error) { return 500 << 30, nil },
		Runner:   fx.Sim, Now: fx.Env.Now,
	}
	r.Cfg = app.Config{Deps: deps,
		Home: home, Getenv: r.Getenv, Version: "2.2.4-s3", Commit: "abc1234", Lang: "en",
		Payload: fx.Env.Payload, Rootfs: fx.Env.Rootfs, Runner: fx.Sim, Arm: func(w run.Whitelist) { fx.Sim.White = &w },
		DL: fx.DL, LookPath: fx.Env.LookPath, Now: fx.Env.Now, NProc: 4, Compressor: backup.Identity{}, SkipNet: true, SkipSudo: true,
	}
	return r
}
