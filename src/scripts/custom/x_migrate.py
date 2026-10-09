#!/usr/bin/env python3
"""serpantinum-x migrate [--dry-run]: one-off, idempotent moves of data left by older builds.

  vpn_data      ~/.local/share/serpantinum/vpn -> ~/.local/share/serpantinum-x/vpn (move if the new dir is empty or
                missing; a symlink is left behind so a root unit that still has the old path keeps working until it
                is re-rendered by `x_vpn.sh install --apply`)
  gemini_proxy  settings.json ai.proxy: an install that relied on the old built-in socks5h://127.0.0.1:1080 default
                (tunnel answering or gemini-proxy-tunnel.service present) gets it written explicitly; new
                installs have no proxy
  telemetry_state  TELEMETRY_ID / ENABLE_TELEMETRY lines are removed from ~/.local/state/serpantinum/version
  cmdd_unit     an existing ~/.config/systemd/user/serpantinum-cmdd.service that points at a checkout is re-rendered
                to point at the installed copy (daemon-reload only, the running daemon is not restarted)

Each step is recorded in <state>/serpantinum-x/migrations.json and never runs twice. Prints one JSON object.
Test overrides: XVPN_* (see xvpn/paths.py), XCMD_* (see xcmd/paths.py), XMIGRATE_STATE, XMIGRATE_SETTINGS, XMIGRATE_VERSION_FILE.
"""
import json
import os
import socket
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "vpn"))
sys.path.insert(0, os.path.join(HERE, "cmd"))
sys.dont_write_bytecode = True

OLD_PROXY = "socks5h://127.0.0.1:1080"


def _home():
    return os.path.expanduser("~")


def state_file():
    if os.environ.get("XMIGRATE_STATE"):
        return os.environ["XMIGRATE_STATE"]
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(_home(), ".local", "state")
    return os.path.join(base, "serpantinum-x", "migrations.json")


def settings_file():
    if os.environ.get("XMIGRATE_SETTINGS"):
        return os.environ["XMIGRATE_SETTINGS"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")
    return os.path.join(base, "serpantinum", "settings.json")


def _atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def migrate_vpn_data(dry):
    from xvpn import paths
    old, new = str(paths.legacy_data_dir()), str(paths.data_dir())
    if os.path.islink(old) or not os.path.isdir(old) or os.path.abspath(old) == os.path.abspath(new):
        return "nothing"
    if os.path.isdir(new) and os.listdir(new):
        return "skipped: new dir not empty"
    if dry:
        return "would move"
    os.makedirs(os.path.dirname(new), exist_ok=True)
    if os.path.isdir(new):
        os.rmdir(new)
    os.rename(old, new)                      # same filesystem (both under ~/.local/share)
    os.symlink(new, old)
    return "moved"


def _tunnel_up(host="127.0.0.1", port=1080):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def migrate_gemini_proxy(dry):
    p = settings_file()
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return "nothing"                     # no settings yet: a fresh install, no proxy
    if not isinstance(data, dict):
        return "nothing"
    ai = data.get("ai")
    if isinstance(ai, dict) and "proxy" in ai:
        return "skipped: already set"
    unit = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config"),
                        "systemd", "user", "gemini-proxy-tunnel.service")
    if not (os.path.exists(unit) or _tunnel_up()):
        return "nothing"
    if dry:
        return "would keep " + OLD_PROXY
    if not isinstance(ai, dict):
        ai = data["ai"] = {}
    ai["proxy"] = OLD_PROXY
    _atomic_write(p, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return "kept " + OLD_PROXY


def migrate_cmdd_unit(dry):
    from xcmd import service
    c = service.check()
    if not c["installed"]:
        return "nothing"
    if c["current"]:
        return "ok"
    if dry:
        return "would rewrite"
    return service.migrate_unit()


def migrate_telemetry_state(dry):
    """Telemetry no longer exists in this build: drop the leftover id/flag from the version state file."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(_home(), ".local", "state")
    p = os.environ.get("XMIGRATE_VERSION_FILE") or os.path.join(base, "serpantinum", "version")
    try:
        with open(p, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return "nothing"
    keep = [ln for ln in lines if not ln.startswith(("TELEMETRY_ID=", "ENABLE_TELEMETRY="))]
    if len(keep) == len(lines):
        return "nothing"
    if dry:
        return "would remove"
    _atomic_write(p, "\n".join(keep) + "\n")
    return "removed"


STEPS = (("telemetry_state", migrate_telemetry_state), ("vpn_data", migrate_vpn_data), ("gemini_proxy", migrate_gemini_proxy), ("cmdd_unit", migrate_cmdd_unit))


def run(dry=False):
    try:
        with open(state_file(), "r", encoding="utf-8") as f:
            done = json.load(f)
    except (OSError, ValueError):
        done = {}
    out = {}
    for name, fn in STEPS:
        if done.get(name) and name != "cmdd_unit":        # the unit check is cheap and must follow the install path
            out[name] = "already done"
            continue
        try:
            out[name] = fn(dry)
        except Exception as e:                            # a failed step must never break the caller
            out[name] = "error: %s" % e
            continue
        if not dry and not out[name].startswith(("error", "would")):
            done[name] = True
    if not dry:
        try:
            _atomic_write(state_file(), json.dumps(done, indent=2) + "\n")
        except OSError as e:
            out["state"] = "error: %s" % e
    return out


if __name__ == "__main__":
    print(json.dumps(run("--dry-run" in sys.argv[1:])))
