package steps

import (
	"context"
	"os"
	"strings"
)

// Init systems (upstream detect_init_system).
const (
	InitSystemd = "systemd"
	InitOpenRC  = "openrc"
	InitDinit   = "dinit"
	InitRunit   = "runit"
	InitS6      = "s6"
	InitGeneric = "generic"
)

func (e *Env) dirExists(p string) bool {
	fi, err := os.Stat(e.Sys(p))
	return err == nil && fi.IsDir()
}

// DetectInit is upstream detect_init_system.
func (e *Env) DetectInit() string {
	switch {
	case e.dirExists("/run/systemd/system") || e.lookPath("systemctl"):
		return InitSystemd
	case e.lookPath("openrc-init") || e.dirExists("/run/openrc"):
		return InitOpenRC
	case e.lookPath("dinit") || e.dirExists("/etc/dinit.d"):
		return InitDinit
	case e.lookPath("runit") || e.dirExists("/run/runit"):
		return InitRunit
	case e.lookPath("s6-svscan"):
		return InitS6
	}
	return InitGeneric
}

// firstOf runs alternatives until one succeeds (a || b || c || true).
func (e *Env) firstOf(ctx context.Context, root bool, alts ...[]string) error {
	for _, a := range alts {
		if _, err := e.exec(ctx, root, a[0], a[1:]...); err == nil {
			return nil
		} else if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	e.rep().Warn("all alternatives failed: " + strings.Join(alts[len(alts)-1], " "))
	return nil
}

// EnableSystemService is upstream enable_system_service.
func (e *Env) EnableSystemService(ctx context.Context, svc, initSys string) error {
	switch initSys {
	case InitSystemd:
		u := svc + ".service"
		return e.firstOf(ctx, true, []string{"systemctl", "enable", "--now", u}, []string{"systemctl", "enable", "-f", u}, []string{"systemctl", "enable", u})
	case InitOpenRC:
		if err := e.best(ctx, true, "rc-update", "add", svc, "default"); err != nil {
			return err
		}
		return e.best(ctx, true, "rc-service", svc, "start")
	case InitDinit:
		return e.firstOf(ctx, true, []string{"dinitctl", "enable", svc}, []string{"dinitctl", "start", svc})
	case InitRunit:
		if e.dirExists("/etc/sv/" + svc) {
			return e.best(ctx, true, "ln", "-sf", "/etc/sv/"+svc, "/var/service/"+svc)
		}
	case InitS6:
		return e.best(ctx, true, "s6-rc-bundle-update", "-b", "add", "default", svc)
	}
	return nil
}

// DisableSystemService is upstream disable_system_service.
func (e *Env) DisableSystemService(ctx context.Context, svc, initSys string) error {
	switch initSys {
	case InitSystemd:
		u := svc + ".service"
		return e.firstOf(ctx, true, []string{"systemctl", "disable", "--now", u}, []string{"systemctl", "disable", u}, []string{"systemctl", "disable", svc})
	case InitOpenRC:
		if err := e.best(ctx, true, "rc-service", svc, "stop"); err != nil {
			return err
		}
		return e.best(ctx, true, "rc-update", "del", svc, "default")
	case InitDinit:
		if err := e.best(ctx, true, "dinitctl", "stop", svc); err != nil {
			return err
		}
		return e.best(ctx, true, "dinitctl", "disable", svc)
	case InitRunit:
		p := e.Sys("/var/service/" + svc)
		if _, err := os.Lstat(p); err == nil {
			return e.best(ctx, true, "rm", "-f", "/var/service/"+svc)
		}
	case InitS6:
		return e.best(ctx, true, "s6-rc-bundle-update", "-b", "del", "default", svc)
	}
	return nil
}

// EnableUserService is upstream enable_user_service.
func (e *Env) EnableUserService(ctx context.Context, svc, initSys string) error {
	switch initSys {
	case InitSystemd:
		if err := e.best(ctx, false, "systemctl", "--user", "daemon-reload"); err != nil {
			return err
		}
		u := svc + ".service"
		return e.firstOf(ctx, false, []string{"systemctl", "--user", "enable", "--now", u}, []string{"systemctl", "--user", "enable", u})
	case InitDinit:
		return e.firstOf(ctx, false, []string{"dinitctl", "--user", "enable", svc}, []string{"dinitctl", "--user", "start", svc})
	}
	return nil
}

type servicesStep struct{ Base }

// Check: the system services of upstream setup_services are enabled (systemd
// only; other init systems are always re-applied, which is idempotent).
func (servicesStep) Check(ctx context.Context, e *Env) (bool, error) {
	if e.DetectInit() != InitSystemd {
		return false, nil
	}
	for _, s := range []string{"NetworkManager", "power-profiles-daemon"} {
		if !e.ok(ctx, "systemctl", "is-enabled", "--quiet", s+".service") {
			return false, nil
		}
	}
	return true, nil
}

// Apply is upstream setup_services.
func (servicesStep) Apply(ctx context.Context, e *Env, _ Reporter) error {
	initSys := e.DetectInit()
	if initSys == InitSystemd {
		if err := e.best(ctx, true, "systemctl", "--global", "enable", "pipewire", "wireplumber", "pipewire-pulse"); err != nil {
			return err
		}
		if err := e.best(ctx, false, "systemctl", "--user", "start", "pipewire", "wireplumber", "pipewire-pulse"); err != nil {
			return err
		}
	}
	if err := e.EnableUserService(ctx, "easyeffects", initSys); err != nil {
		return err
	}
	if err := e.EnableSystemService(ctx, "NetworkManager", initSys); err != nil {
		return err
	}
	return e.EnableSystemService(ctx, "power-profiles-daemon", initSys)
}
