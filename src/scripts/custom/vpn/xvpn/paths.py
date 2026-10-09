"""Paths, atomic writes and settings for the VPN module.

Every location can be overridden through XVPN_* environment variables so tests never touch real data.
Secrets (subscription URL) live only in the secrets dir with mode 600 and are never logged.
"""
import json
import os
import tempfile
from pathlib import Path

HOME = os.path.expanduser("~")

DEFAULT_SETTINGS = {
    "mode": "ru-direct",          # ru-direct | all | direct
    "killSwitch": False,
    "blockIPv6": True,
    "autoDisable": True,
    "autoDisableSeconds": 20,
    "updateHours": 6,
    "format": "auto",             # auto | json | links
    "userAgent": "",
    "bypassDomains": [],          # always direct
    "proxyDomains": [],           # always through the VPN
    "socksPort": 10808,
    "dnsDirect": ["77.88.8.8", "77.88.8.1"],   # resolvers for RU names (queried directly, never through the tunnel)
    "geoUrl": "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download",
    "pingMethod": "httpGet",      # httpGet | httpHead | tcp | icmp
    "pingUrl": "https://www.gstatic.com/generate_204",
    "pingTimeout": 3,             # seconds, 1..10
    "pingDisplay": "digits",      # digits | bars | barsDigits | dots (UI only)
}

PING_METHODS = ("httpGet", "httpHead", "tcp", "icmp")
PING_DISPLAYS = ("digits", "bars", "barsDigits", "dots")
PING_URL_MAX = 512

MARK = 9011        # 0x2333: sockopt.mark of xray's own outbound sockets (routed through the main table)
TABLE = 22333      # routing table that holds the default route through the tunnel
TUN_NAME = "serp-xray"
TUN_ADDR4 = "172.30.255.1/30"
TUN_ADDR6 = "fd00:5e72:7878::1/126"
UNIT = "serp-xray.service"
UNBLOCK_UNIT = "serp-xray-unblock.service"


def _p(env, default):
    return Path(os.environ.get(env) or default)


def state_dir():
    return _p("XVPN_STATE_DIR", f"{HOME}/.local/state/serpantinum/vpn")


def secrets_dir():
    return _p("XVPN_SECRETS_DIR", f"{HOME}/.config/serpantinum/secrets")


def data_dir():
    # NOT under ~/.local/share/serpantinum: the upstream installer wipes that directory on a full deploy.
    return _p("XVPN_DATA_DIR", f"{HOME}/.local/share/serpantinum-x/vpn")


def legacy_data_dir():
    """Where the data lived before; x_migrate.py moves it to data_dir()."""
    return Path(f"{HOME}/.local/share/serpantinum/vpn")


def settings_file():
    return _p("XVPN_SETTINGS", f"{HOME}/.config/serpantinum/settings.json")


def events_file():
    return _p("XVPN_EVENTS", f"{HOME}/.local/state/serpantinum/events.jsonl")


def sys_class_net():
    return _p("XVPN_SYS_NET", "/sys/class/net")


def secret_file(name="vpn_subscription"):
    return secrets_dir() / name


def ensure_dir(p, mode=0o700):
    p = Path(p)
    p.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(p, mode)
    except OSError:
        pass
    return p


def atomic_write(path, data, mode=0o600):
    """Write bytes/str atomically with the given mode (the file never exists with wider permissions)."""
    path = Path(path)
    ensure_dir(path.parent)
    if isinstance(data, str):
        data = data.encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj, mode=0o600):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=False), mode)


def valid_ping_url(u):
    """-> normalized http(s) URL or None. No credentials, no whitespace/control chars, length cap."""
    if not isinstance(u, str):
        return None
    u = u.strip()
    if not u or len(u) > PING_URL_MAX or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in u):
        return None
    from urllib.parse import urlsplit
    try:
        sp = urlsplit(u)
        host, _port = sp.hostname, sp.port
    except ValueError:
        return None
    if sp.scheme not in ("http", "https") or not host or sp.username is not None or sp.password is not None:
        return None
    return u


def load_settings():
    """settings.json -> "vpn" section merged over defaults (read-only; the shell writes the file)."""
    raw = read_json(settings_file(), {}) or {}
    sec = raw.get("vpn") if isinstance(raw, dict) else None
    out = dict(DEFAULT_SETTINGS)
    if isinstance(sec, dict):
        for k, v in sec.items():
            if k in DEFAULT_SETTINGS and type(v) is type(DEFAULT_SETTINGS[k]):
                out[k] = v
    if out["mode"] not in ("ru-direct", "all", "direct"):
        out["mode"] = "ru-direct"
    if isinstance(sec, dict):                                  # the timeout may arrive as 3.0 from the UI
        t = sec.get("pingTimeout")
        if isinstance(t, float) and t == t and abs(t) < 1e6:
            out["pingTimeout"] = int(round(t))
    if out["pingMethod"] not in PING_METHODS:
        out["pingMethod"] = DEFAULT_SETTINGS["pingMethod"]
    if out["pingDisplay"] not in PING_DISPLAYS:
        out["pingDisplay"] = DEFAULT_SETTINGS["pingDisplay"]
    out["pingUrl"] = valid_ping_url(out["pingUrl"]) or DEFAULT_SETTINGS["pingUrl"]
    out["pingTimeout"] = min(10, max(1, out["pingTimeout"])) if type(out["pingTimeout"]) is int else 3
    return out


def append_event(name, **data):
    """Shared event bus (JSON lines) used later by the Commands app. Never contains secrets."""
    import time
    try:
        p = events_file()
        ensure_dir(p.parent)
        line = json.dumps({"ts": int(time.time()), "event": name, **data}, ensure_ascii=False)
        with open(p, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
