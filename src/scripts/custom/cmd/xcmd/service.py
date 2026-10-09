"""systemd --user unit of the daemon: render, install, uninstall, status. Nothing here needs root."""
import os
import subprocess

from . import paths
from .util import read_text

UNIT = "serpantinum-cmdd.service"


def unit_path():
    return os.path.join(paths.unit_dir(), UNIT)


def render_unit():
    return read_text(paths.unit_template()).replace("@BIN_X@", paths.bin_x())


def _same(path, text):
    try:
        return read_text(path) == text
    except OSError:
        return False


def desktop_entries():
    """{file name: rendered text} of the launcher entries (templates carry @HOME@)."""
    d = paths.desktop_templates_dir()
    out = {}
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".desktop"))
    except OSError:
        return out
    for n in names:
        out[n] = read_text(os.path.join(d, n)).replace("@HOME@", paths._home())
    return out


def install_desktop():
    os.makedirs(paths.desktop_dir(), exist_ok=True)
    done = []
    for n, text in desktop_entries().items():
        with open(os.path.join(paths.desktop_dir(), n), "w", encoding="utf-8") as f:
            f.write(text)
        done.append(n)
    return done


def uninstall_desktop():
    done = []
    for n in desktop_entries():
        try:
            os.remove(os.path.join(paths.desktop_dir(), n))
            done.append(n)
        except FileNotFoundError:
            pass
    return done


def check():
    """Is the installed unit identical to what `install` would write? (idempotency check, no side effects)"""
    want = render_unit()
    try:
        have = read_text(unit_path())
    except OSError:
        return {"installed": False, "current": False, "unit_path": unit_path()}
    desk = all(_same(os.path.join(paths.desktop_dir(), n), t) for n, t in desktop_entries().items())
    return {"installed": True, "current": have == want and desk, "unit_current": have == want, "desktop_current": desk,
            "unit_path": unit_path()}


def migrate_unit():
    """Re-render an existing unit whose ExecStart points somewhere else (typically a working checkout).
    Only a unit that already exists is touched; the running daemon is not restarted. Returns the action taken."""
    c = check()
    if not c["installed"]:
        return "absent"
    if c["current"]:
        return "ok"
    if not c["unit_current"]:
        with open(unit_path(), "w", encoding="utf-8") as f:
            f.write(render_unit())
        _ctl("daemon-reload")
    install_desktop()
    return "rewritten"


def _ctl(*args):
    try:
        r = subprocess.run([paths.systemctl_bin(), "--user", *args], capture_output=True, text=True, timeout=20)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)


def plan(action):
    if action == "install":
        return ["write %s" % unit_path(), "write launcher entries to %s" % paths.desktop_dir(), "systemctl --user daemon-reload", "systemctl --user enable --now %s" % UNIT]
    return ["systemctl --user disable --now %s" % UNIT, "remove %s" % unit_path(), "remove launcher entries from %s" % paths.desktop_dir(), "systemctl --user daemon-reload"]


def install(print_only=False):
    if print_only:
        return {"applied": False, "plan": plan("install"), "unit": render_unit()}
    os.makedirs(paths.unit_dir(), exist_ok=True)
    with open(unit_path(), "w", encoding="utf-8") as f:
        f.write(render_unit())
    install_desktop()
    steps = [("daemon-reload",), ("enable", "--now", UNIT)]
    results = [{"cmd": " ".join(s), "rc": _ctl(*s)[0]} for s in steps]
    return {"applied": True, "plan": plan("install"), "results": results, "ok": all(r["rc"] == 0 for r in results)}


def uninstall(print_only=False):
    if print_only:
        return {"applied": False, "plan": plan("uninstall")}
    results = [{"cmd": "disable --now", "rc": _ctl("disable", "--now", UNIT)[0]}]
    try:
        os.remove(unit_path())
    except FileNotFoundError:
        pass
    uninstall_desktop()
    results.append({"cmd": "daemon-reload", "rc": _ctl("daemon-reload")[0]})
    return {"applied": True, "plan": plan("uninstall"), "results": results}


def status():
    rc_en, out_en = _ctl("is-enabled", UNIT)
    rc_ac, out_ac = _ctl("is-active", UNIT)
    return {"unit_installed": os.path.exists(unit_path()), "unit_path": unit_path(),
            "enabled": rc_en == 0 and out_en == "enabled", "active": out_ac == "active"}
