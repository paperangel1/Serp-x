"""Thin, stub-friendly wrappers around systemctl and /sys. Read-only except start/stop/restart of OUR units."""
import os
import subprocess
from pathlib import Path

from . import paths

HAPP_UNIT = "happd.service"
HAPP_IFACE = "happ-xray"


def _bin(env, default):
    return os.environ.get(env) or default


def systemctl(*args, timeout=40):
    """-> (returncode, stdout). The binary is replaceable (XVPN_SYSTEMCTL) for tests."""
    cmd = [_bin("XVPN_SYSTEMCTL", "systemctl"), *args]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return r.returncode, (r.stdout or "").strip()


def unit_state(unit=paths.UNIT):
    rc, out = systemctl("is-active", unit, timeout=10)
    return out or ("unknown" if rc else "inactive")


def unit_active(unit=paths.UNIT):
    return unit_state(unit) == "active"


def etc_root():
    return Path(os.environ.get("XVPN_ETC_ROOT") or "/")


def unit_file(unit=paths.UNIT):
    return etc_root() / "etc/systemd/system" / unit


def polkit_file():
    return etc_root() / "etc/polkit-1/rules.d/49-serpantinum-xray.rules"


def helper_file():
    return etc_root() / "usr/local/lib/serpantinum-xray/serp-xray-helper"


def unit_installed(unit=paths.UNIT):
    return unit_file(unit).is_file()


def polkit_state():
    """True / False / None. None = cannot tell: /etc/polkit-1/rules.d is root:polkitd 0750 on stock Arch,
    so the user cannot even stat the file (EACCES). That is "unknown", never "missing"."""
    try:
        os.stat(polkit_file())
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return None


def polkit_installed():
    return polkit_state() is True


def iface_exists(name):
    return (paths.sys_class_net() / name).exists()


def tun_present():
    return iface_exists(paths.TUN_NAME)


HAPP_CORE = "/opt/happ/bin/core/xray"


def _run_out(envname, default, *args, timeout=5):
    try:
        r = subprocess.run([_bin(envname, default), *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return r.returncode, (r.stdout or "").strip()


def happ_core_running():
    """Happ's own xray process is alive (pgrep exits 0 when something matches)."""
    return _run_out("XVPN_PGREP", "pgrep", "-f", HAPP_CORE)[0] == 0


def iface_default_route(name):
    """Does `name` hold a default route (any table, v4 or v6)? Read-only `ip route show`."""
    for fam in ("-4", "-6"):
        rc, out = _run_out("XVPN_IP", "ip", fam, "route", "show", "table", "all", "default", "dev", name)
        if rc == 0 and out:
            return True
    return False


def happ_state():
    """happd.service runs permanently (it only controls the app's processes), so the daemon alone is NOT a
    conflict. Happ's VPN is on only while its core xray runs and/or happ-xray is up and holds the default route."""
    iface = iface_exists(HAPP_IFACE)
    return {
        "daemon": unit_active(HAPP_UNIT),
        "core": happ_core_running(),
        "iface": iface,
        "defaultRoute": iface_default_route(HAPP_IFACE) if iface else False,
    }


def happ_conflict(st=None):
    st = st or happ_state()
    return bool(st["core"] or (st["iface"] and st["defaultRoute"]))


def happ_active():
    return happ_conflict()


def counters(name=paths.TUN_NAME):
    """-> (rx_bytes, tx_bytes) of the tunnel, or (0, 0). Used for the speed readout (no xray API needed)."""
    base = paths.sys_class_net() / name / "statistics"
    try:
        return int((base / "rx_bytes").read_text()), int((base / "tx_bytes").read_text())
    except (OSError, ValueError):
        return 0, 0


def start(unit=paths.UNIT):
    return systemctl("start", unit)[0]


def stop(unit=paths.UNIT):
    return systemctl("stop", unit)[0]


def restart(unit=paths.UNIT):
    return systemctl("restart", unit)[0]


def journal_tail(since_ts, lines=80):
    """Recent journal lines of OUR unit (read-only; empty when the user may not read the journal)."""
    cmd = [_bin("XVPN_JOURNALCTL", "journalctl"), "-u", paths.UNIT, "--no-pager", "-o", "cat", "-n", str(lines),
           "--since", "@%d" % int(since_ts)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout or ""
