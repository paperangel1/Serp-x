package steps

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Paths of the SDDM setup (upstream setup_sddm).
const (
	sddmThemeDest = "/usr/share/sddm/themes/material-you"
	sddmConf      = "/etc/sddm.conf.d/10-material-you.conf"
	sddmFontsDir  = "/usr/share/fonts/TTF"
)

// SDDMConf renders the drop-in file for the wayland or default greeter.
func SDDMConf(wayland bool) []byte {
	s := "[Theme]\nCurrent=material-you\nThemeDir=/usr/share/sddm/themes\n\n[General]\n"
	if wayland {
		s += "DisplayServer=wayland\nGreeterEnvironment=QT_WAYLAND_DISABLE_WINDOWDECORATION=1\n"
	}
	s += "InputMethod=\n"
	return []byte(s)
}

type sddmThemeStep struct{ Base }

func (sddmThemeStep) Check(_ context.Context, e *Env) (bool, error) {
	b, err := readIfExists(e.Sys(sddmConf))
	if err != nil || b == nil {
		return false, err
	}
	if string(b) != string(SDDMConf(e.Opts.SDDMWayland)) {
		return false, nil
	}
	_, err = os.Stat(e.Sys(sddmThemeDest))
	return err == nil, nil
}

func (sddmThemeStep) Apply(ctx context.Context, e *Env, rep Reporter) error {
	initSys := e.DetectInit()
	update := e.isUpdate()
	rep.Log("configuring SDDM")
	if !update && e.Opts.ReplaceDM {
		for _, dm := range []string{"gdm", "gdm3", "lightdm", "lxdm", "lxdm-gtk3", "ly", "greetd", "emptty"} {
			if err := e.DisableSystemService(ctx, dm, initSys); err != nil {
				return err
			}
			if e.ok(ctx, "pacman", "-Qq", dm) {
				rep.Log("disabling display manager " + dm)
				if err := e.best(ctx, true, "pacman", "-Rns", "--noconfirm", dm); err != nil {
					return err
				}
			}
		}
	}
	for _, d := range []string{"/usr/share/sddm/themes/matugen-minimal", sddmThemeDest} {
		if err := e.best(ctx, true, "rm", "-rf", d); err != nil {
			return err
		}
	}
	for _, pat := range []string{"*matugen*.conf", "*material-you*.conf"} {
		m, _ := filepath.Glob(e.Sys("/etc/sddm.conf.d/" + pat))
		for _, f := range m {
			real := "/" + strings.TrimPrefix(strings.TrimPrefix(f, e.rootfs()), "/")
			if err := e.best(ctx, true, "rm", "-f", real); err != nil {
				return err
			}
		}
	}
	if !update {
		if _, err := os.Stat(e.Sys("/etc/sddm.conf")); err == nil {
			bak := "/etc/sddm.conf.backup." + e.now().Format("20060102_150405")
			if err := e.best(ctx, true, "install", "-m", "644", "/etc/sddm.conf", bak); err != nil {
				return err
			}
			if err := e.best(ctx, true, "rm", "-f", "/etc/sddm.conf"); err != nil {
				return err
			}
		}
	}
	src := filepath.Join(e.Payload, "config/sddm/themes/material-you")
	if fi, err := os.Stat(src); err == nil && fi.IsDir() {
		if _, err := e.exec(ctx, true, "install", "-d", "-m", "755", sddmThemeDest); err != nil {
			return err
		}
		var ttf []string
		err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
			if err != nil || p == src {
				return err
			}
			rel, _ := filepath.Rel(src, p)
			dst := filepath.Join(sddmThemeDest, rel)
			if d.IsDir() {
				_, err := e.exec(ctx, true, "install", "-d", "-m", "755", dst)
				return err
			}
			if d.Type().IsRegular() {
				if _, err := e.exec(ctx, true, "install", "-m", "755", p, dst); err != nil { // chmod -R 755
					return err
				}
				if filepath.Dir(p) == filepath.Join(src, "font") && strings.HasSuffix(p, ".ttf") {
					ttf = append(ttf, p)
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		if len(ttf) > 0 {
			if err := e.best(ctx, true, "install", "-d", "-m", "755", sddmFontsDir); err != nil {
				return err
			}
			if err := e.best(ctx, true, "install", append([]string{"-m", "644", "-t", sddmFontsDir}, ttf...)...); err != nil {
				return err
			}
			e.best(ctx, false, "fc-cache", "-f", "/usr/share/fonts")
		}
	}
	if _, err := e.exec(ctx, true, "install", "-d", "-m", "755", "/etc/sddm.conf.d"); err != nil {
		return err
	}
	if err := e.rootInstallFile(ctx, sddmConf, SDDMConf(e.Opts.SDDMWayland), "644"); err != nil {
		return err
	}
	rep.Log("SDDM theme installed")
	return nil
}

func (sddmThemeStep) Rollback(ctx context.Context, e *Env) error {
	if err := e.best(ctx, true, "rm", "-rf", sddmThemeDest); err != nil {
		return err
	}
	return e.best(ctx, true, "rm", "-f", sddmConf)
}

type sddmEnableStep struct{ Base }

func (sddmEnableStep) Check(ctx context.Context, e *Env) (bool, error) {
	if e.DetectInit() != InitSystemd {
		return false, nil
	}
	return e.ok(ctx, "systemctl", "is-enabled", "--quiet", "sddm.service"), nil
}

func (sddmEnableStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	return e.EnableSystemService(ctx, "sddm", e.DetectInit())
}

func (sddmEnableStep) Rollback(ctx context.Context, e *Env) error {
	return e.DisableSystemService(ctx, "sddm", e.DetectInit())
}
