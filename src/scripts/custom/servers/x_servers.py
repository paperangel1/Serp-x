#!/usr/bin/env python3
"""serpantinum-x servers: Remnawave nodes + restricted-SSH commands for the Servers widget.

Every sub-command prints JSON (or streams lines, for `run`). Secrets are read from files, never from argv:
  ~/.config/serpantinum/secrets/remnawave_url, remnawave_token   (mode 600)
  ~/.config/serpantinum/servers/{servers.toml,commands.toml,id_serp,known_hosts}
  ~/.local/state/serpantinum/servers/{state.json,history.jsonl}; events -> ~/.local/state/serpantinum/events.jsonl
"""
import argparse
import base64
import io
import ipaddress
import json
import os
import re
import secrets as pysecrets
import shlex
import ssl
import subprocess
import sys
import tarfile
import threading
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

try:    # shared logging (module "servers"); never allowed to break the backend
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "xlog"))
    import xlog as _xlog
    xlog = _xlog.get("servers")
except Exception:
    class _Null:
        def __getattr__(self, _n):
            return lambda *a, **k: None
    xlog = _Null()
_LAST_OUT = {}

HERE = Path(__file__).resolve().parent
SERVER_DIR = HERE / "server"
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_LABEL_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>]")
CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
FLAG_RE = re.compile(r"^\s*([\U0001F1E6-\U0001F1FF]{2})\s*")
MAX_LINES = 400
MAX_LINE_LEN = 2000
API_MAX_BYTES = 5 * 1024 * 1024


def _home():
    return Path(os.environ.get("HOME") or os.path.expanduser("~"))


def cfg_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or str(_home() / ".config")
    return Path(base) / "serpantinum"


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or str(_home() / ".local" / "state")
    return Path(base) / "serpantinum"


def servers_dir():
    return cfg_dir() / "servers"


def secrets_dir():
    return cfg_dir() / "secrets"


def srv_state_dir():
    return state_dir() / "servers"


KEY_PATH = lambda: servers_dir() / "id_serp"
KNOWN_HOSTS = lambda: servers_dir() / "known_hosts"

# id, label, group, danger, timeout (seconds)
PREDEFINED = [
    {"id": "diag-net", "label": "Сеть", "group": "diag", "danger": "none", "timeout": 60},
    {"id": "diag-load", "label": "Нагрузка", "group": "diag", "danger": "none", "timeout": 60},
    {"id": "diag-disk", "label": "Диск", "group": "diag", "danger": "none", "timeout": 90},
    {"id": "diag-logs", "label": "Логи", "group": "diag", "danger": "none", "timeout": 60},
    {"id": "diag-ports", "label": "Порты", "group": "diag", "danger": "none", "timeout": 60},
    {"id": "diag-security", "label": "Безопасность", "group": "diag", "danger": "none", "timeout": 90},
    {"id": "act-restart-node", "label": "Перезапустить ноду", "group": "action", "danger": "confirm", "timeout": 90},
    {"id": "act-update-container", "label": "Обновить контейнер", "group": "action", "danger": "confirm", "timeout": 600},
    {"id": "act-docker-prune", "label": "Очистить Docker", "group": "action", "danger": "confirm", "timeout": 180},
    {"id": "act-reboot", "label": "Перезагрузить сервер", "group": "action", "danger": "typed", "timeout": 30},
]


# ------------------------------------------------------------------ small helpers
def out(obj):
    _LAST_OUT["obj"] = obj
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def now():
    return int(time.time())


def slug(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "server"


def clean_text(s):
    s = ANSI_RE.sub("", s)
    s = s.replace("\r", "")
    s = CTRL_RE.sub("", s)
    return s[:MAX_LINE_LEN]


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp." + str(os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(data)
    try:
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def read_secret(name):
    try:
        return (secrets_dir() / name).read_text().strip()
    except Exception:
        return ""


def emit_event(etype, data):
    """Append one JSON line to the shared events bus (future Commands triggers)."""
    try:
        p = state_dir() / "events.jsonl"
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "a") as f:
            f.write(json.dumps({"ts": now(), "type": etype, "data": data}, ensure_ascii=False) + "\n")
    except Exception:
        pass


def load_state():
    return read_json(srv_state_dir() / "state.json", {"servers": {}, "ssh": {}, "online": {}})


def save_state(st):
    atomic_write(srv_state_dir() / "state.json", json.dumps(st, ensure_ascii=False))


# ------------------------------------------------------------------ config (servers.toml / commands.toml)
def load_toml(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}
    except tomllib.TOMLDecodeError as e:
        raise ValueError(f"{Path(path).name}: {e}")


def custom_commands():
    """User commands from commands.toml. Returns (commands, problems)."""
    cmds, problems = [], []
    try:
        data = load_toml(servers_dir() / "commands.toml")
    except ValueError as e:
        return [], [str(e)]
    seen = {c["id"] for c in PREDEFINED}
    for i, c in enumerate(data.get("command", []) if isinstance(data.get("command", []), list) else []):
        cid = str(c.get("id", ""))
        if not TOKEN_RE.match(cid):
            problems.append(f"command #{i + 1}: bad id {cid!r} (a-z, 0-9, '-', up to 32)")
            continue
        if cid in seen:
            problems.append(f"command {cid}: id already used")
            continue
        seen.add(cid)
        danger = c.get("danger", "none")
        if danger not in ("none", "confirm", "typed"):
            danger = "confirm"
        script = str(c.get("script", "")) if c.get("script") else ""
        cmds.append({"id": cid, "label": str(c.get("label", cid))[:40], "group": "custom", "danger": danger,
                     "timeout": max(5, min(1800, int(c.get("timeout", 60)))), "script": script})
    return cmds, problems


def all_commands():
    cmds, problems = custom_commands()
    return [dict(c) for c in PREDEFINED] + cmds, problems


def manual_servers():
    try:
        data = load_toml(servers_dir() / "servers.toml")
    except ValueError:
        return []
    rows = data.get("server", [])
    return rows if isinstance(rows, list) else []


# ------------------------------------------------------------------ manual servers: add / remove / list (servers.toml)
SERVER_HDR_RE = re.compile(r"^\s*\[\[server\]\]\s*(?:#.*)?$")
ANY_HDR_RE = re.compile(r"^\s*\[")


def valid_host(h):
    if not isinstance(h, str) or not h or len(h) > 253 or h != h.strip():
        return False
    if re.fullmatch(r"[0-9.]+", h):
        try:
            ipaddress.IPv4Address(h)
            return True
        except ValueError:
            return False
    if ":" in h:
        if not re.fullmatch(r"[0-9A-Fa-f:.]+", h):
            return False
        try:
            ipaddress.IPv6Address(h)
            return True
        except ValueError:
            return False
    return all(HOST_LABEL_RE.match(x) for x in h.rstrip(".").split("."))


def validate_server_fields(name, host, port, user):
    """Returns (error_code, field) or (None, None)."""
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > 60 or CTRL_RE.search(name) or re.search(r"[\n\r\t\x1b]", name):
        return "bad_name", "name"
    if not valid_host(host):
        return "bad_host", "host"
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        return "bad_port", "port"
    if not isinstance(user, str) or not USER_RE.match(user):
        return "bad_user", "user"
    return None, None


def _toml_str(v):
    return json.dumps(v, ensure_ascii=False)


def _servers_path():
    return servers_dir() / "servers.toml"


def _read_servers_text():
    p = _servers_path()
    try:
        text = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    tomllib.loads(text)             # raises on a broken file: we never rewrite what we cannot parse
    return text


def _write_servers_text(old, new):
    d = servers_dir()
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    tomllib.loads(new)              # never write something that does not parse
    if old:
        atomic_write(d / "servers.toml.bak", old, 0o600)
    atomic_write(_servers_path(), new, 0o600)


def _entry_id(m):
    return str(m.get("id") or slug(str(m.get("name") or m.get("host") or "server")))


def _public(m):
    name = str(m.get("name") or m.get("host") or "server")
    return {"id": "m:" + _entry_id(m), "name": strip_flag(name), "port": int(m.get("port", 22) or 22),
            "user": str(m.get("user", "serp")), "manual": True}


def _manual_only():
    return [m for m in manual_servers() if isinstance(m, dict) and not m.get("match")]


def cmd_list(_args):
    out({"ok": True, "servers": [dict(_public(m), address=str(m.get("host", ""))) for m in _manual_only()]})
    return 0


def _norm_id(raw):
    raw = str(raw or "")
    return raw[2:] if raw.startswith("m:") else raw


def cmd_add(args):
    name, host, port, user = (args.name or "").strip(), (args.host or "").strip().lower(), args.port, args.user
    code, field = validate_server_fields(name, host, port, user)
    if not code and args.id and not TOKEN_RE.match(_norm_id(args.id)):
        code, field = "bad_id", "id"
    if code:
        out({"ok": False, "error": code, "field": field})
        return 2
    try:
        old = _read_servers_text()
    except (ValueError, tomllib.TOMLDecodeError, OSError):
        out({"ok": False, "error": "config_broken"})
        return 1
    rows = _manual_only()
    for m in rows:
        if str(m.get("host", "")).lower() == host and int(m.get("port", 22) or 22) == port:
            same = strip_flag(str(m.get("name", ""))) == strip_flag(name) and str(m.get("user", "serp")) == user
            out({"ok": same, "error": None if same else "duplicate", "existed": True, "server": _public(m)})
            return 0 if same else 1
    taken = {_entry_id(m) for m in manual_servers() if isinstance(m, dict)}
    taken |= {str(k).split(":", 1)[-1] for k in load_state().get("servers", {})}      # ids/uuids the panel gave us
    if args.id:
        sid = _norm_id(args.id)
        if sid in taken:
            out({"ok": False, "error": "id_taken", "field": "id"})
            return 1
    else:
        base = slug(strip_flag(name))[:40].strip("-") or "server"
        sid, n = base, 1
        while sid in taken or not TOKEN_RE.match(sid):
            n += 1
            sid = f"{base}-{n}"
    block = "[[server]]\nid = %s\nname = %s\nhost = %s\nport = %d\nuser = %s\n" % (
        _toml_str(sid), _toml_str(name), _toml_str(host), port, _toml_str(user))
    new = (old if old.endswith("\n") or not old else old + "\n") + ("\n" if old.strip() else "") + block
    try:
        _write_servers_text(old, new)
    except Exception as e:
        xlog.warn("add: write failed", exc=type(e).__name__)
        out({"ok": False, "error": "write_failed"})
        return 1
    xlog.info("manual server added", id="m:" + sid, name=name)
    emit_event("server.added", {"id": "m:" + sid, "name": name})
    out({"ok": True, "existed": False, "server": _public({"id": sid, "name": name, "host": host, "port": port, "user": user})})
    return 0


def _forget_host(host, port):
    kh = KNOWN_HOSTS()
    if not kh.exists() or not host:
        return False
    target = host if port == 22 else f"[{host}]:{port}"
    try:
        subprocess.run(["ssh-keygen", "-R", target, "-f", str(kh)], capture_output=True, timeout=10)
        (kh.parent / (kh.name + ".old")).unlink(missing_ok=True)
        return True
    except Exception:
        return False


def cmd_remove(args):
    sid = _norm_id(args.id)
    try:
        old = _read_servers_text()
    except (ValueError, tomllib.TOMLDecodeError, OSError):
        out({"ok": False, "error": "config_broken"})
        return 1
    rows = manual_servers()
    entry = next((m for m in rows if isinstance(m, dict) and not m.get("match") and _entry_id(m) == sid), None)
    if entry is None:
        out({"ok": True, "removed": False, "reason": "not_manual_or_missing"})   # panel servers are never touched
        return 0
    lines = old.splitlines(keepends=True)
    keep, i, dropped = [], 0, 0
    while i < len(lines):
        if SERVER_HDR_RE.match(lines[i]):
            j = i + 1
            while j < len(lines) and not ANY_HDR_RE.match(lines[j]):
                j += 1
            try:
                blk = tomllib.loads("".join(lines[i:j])).get("server", [{}])[0]
            except Exception:
                blk = {}
            if isinstance(blk, dict) and not blk.get("match") and _entry_id(blk) == sid and not dropped:
                dropped += 1
                while keep and keep[-1].strip() == "" and j < len(lines):     # keep one blank line of separation
                    keep.pop()
                    break
                i = j
                continue
            keep.extend(lines[i:j])
            i = j
            continue
        keep.append(lines[i])
        i += 1
    new = "".join(keep)
    if not dropped or len(tomllib.loads(new).get("server", [])) != len(tomllib.loads(old).get("server", [])) - 1:
        out({"ok": False, "error": "write_failed"})
        return 1
    try:
        _write_servers_text(old, new)
    except Exception as e:
        xlog.warn("remove: write failed", exc=type(e).__name__)
        out({"ok": False, "error": "write_failed"})
        return 1
    forgot = _forget_host(str(entry.get("host", "")), int(entry.get("port", 22) or 22)) if args.forget_host else False
    st = load_state()
    for k in ("ssh", "online", "servers"):
        st.get(k, {}).pop("m:" + sid, None)
    save_state(st)
    xlog.info("manual server removed", id="m:" + sid, name=str(entry.get("name", "")))
    out({"ok": True, "removed": True, "id": "m:" + sid, "forgotHost": forgot})
    return 0


# ------------------------------------------------------------------ Remnawave API
def flag_from(name, country):
    m = FLAG_RE.match(name or "")
    if m:
        return m.group(1)
    if country and re.fullmatch(r"[A-Za-z]{2}", country):
        return "".join(chr(0x1F1E6 + ord(c) - 65) for c in country.upper())
    return ""


def strip_flag(name):
    return FLAG_RE.sub("", name or "", count=1).strip() or (name or "")


def _pick(d, *keys, default=None):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return default


def _nodes_from(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("response", "data", "nodes", "items", "result"):
            v = payload.get(key)
            if isinstance(v, list):
                return v
            if isinstance(v, dict):
                inner = _nodes_from(v)
                if inner:
                    return inner
    return []


def normalize_node(n):
    name = str(_pick(n, "name", "nodeName", "title", default="node"))
    uuid = str(_pick(n, "uuid", "id", default=slug(name)))
    status = str(_pick(n, "status", default="")).lower()
    connected = _pick(n, "isConnected", "connected", "isOnline", default=None)
    if connected is None:
        connected = status in ("online", "connected", "up", "ok")
    disabled = bool(_pick(n, "isDisabled", "disabled", default=False))
    return {
        "id": "api:" + uuid,
        "uuid": uuid,
        "source": "api",
        "name": strip_flag(name),
        "flag": flag_from(name, _pick(n, "countryCode", "country", default="")),
        "address": str(_pick(n, "address", "host", "ip", default="")),
        "port": int(_pick(n, "sshPort", default=22) or 22),
        "online": bool(connected) and not disabled,
        "disabled": disabled,
        "xrayRunning": _pick(n, "isXrayRunning", "xrayRunning", default=None),
        "xrayVersion": str(_pick(n, "xrayVersion", default="") or ""),
        "usersOnline": _pick(n, "usersOnline", "onlineUsers", default=None),
        "trafficUsed": _pick(n, "trafficUsedBytes", "trafficUsed", default=None),
        "trafficLimit": _pick(n, "trafficLimitBytes", "trafficLimit", default=None),
        "lastChange": _pick(n, "lastStatusChange", "lastStatusMessage", default=None),
    }


def api_creds():
    url = read_secret("remnawave_url")
    token = read_secret("remnawave_token")
    return url, token


def api_fetch_nodes(timeout=10):
    """Returns (nodes, error). The error text never contains the URL or the token."""
    url, token = api_creds()
    if not url or not token:
        return [], "not_configured"
    p = urllib.parse.urlparse(url)
    if p.scheme not in ("http", "https") or not p.hostname:
        return [], "bad_url"
    if p.scheme == "http" and p.hostname not in ("localhost", "127.0.0.1", "::1"):
        return [], "insecure_url"
    target = url.rstrip("/") + "/api/nodes"
    req = urllib.request.Request(target, headers={"Authorization": "Bearer " + token, "Accept": "application/json",
                                                  "User-Agent": "serpantinum-x/1"})
    try:
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            raw = r.read(API_MAX_BYTES + 1)
        if len(raw) > API_MAX_BYTES:
            return [], "response_too_large"
        payload = json.loads(raw.decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        return [], f"http_{e.code}"
    except urllib.error.URLError as e:
        return [], "network:" + re.sub(r"https?://\S+", "", str(e.reason))[:80]
    except (ValueError, json.JSONDecodeError):
        return [], "bad_response"
    except Exception as e:
        return [], "error:" + type(e).__name__
    nodes = [normalize_node(n) for n in _nodes_from(payload) if isinstance(n, dict)]
    return nodes, None


def merge_servers(nodes):
    """API nodes + manual entries (servers.toml). A manual entry with `match` overrides host/port/user of a node."""
    servers = [dict(n) for n in nodes]
    by_key = {}
    for s in servers:
        by_key[s["uuid"]] = s
        by_key[s["name"].lower()] = s
    for m in manual_servers():
        if not isinstance(m, dict):
            continue
        match = str(m.get("match", "")).lower()
        target = by_key.get(match) if match else None
        if target:
            if m.get("host"):
                target["address"] = str(m["host"])
            if m.get("port"):
                target["port"] = int(m["port"])
            if m.get("user"):
                target["user"] = str(m["user"])
            continue
        name = str(m.get("name") or m.get("host") or "server")
        servers.append({"id": "m:" + str(m.get("id") or slug(name)), "uuid": "", "source": "manual", "manual": True, "name": strip_flag(name),
                        "flag": flag_from(name, ""), "address": str(m.get("host", "")), "port": int(m.get("port", 22) or 22),
                        "user": str(m.get("user", "serp")), "online": None, "disabled": False, "xrayRunning": None,
                        "xrayVersion": "", "usersOnline": None, "trafficUsed": None, "trafficLimit": None, "lastChange": None})
    for s in servers:
        s.setdefault("user", "serp")
    return servers


# ------------------------------------------------------------------ SSH (restricted key, forced command)
def ssh_base(host, port, user, extra=None, strict="yes"):
    cmd = ["ssh", "-T", "-i", str(KEY_PATH()), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", f"UserKnownHostsFile={KNOWN_HOSTS()}", "-o", f"StrictHostKeyChecking={strict}",
           "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
           "-o", "LogLevel=ERROR", "-p", str(port)]
    if extra:
        cmd += extra
    return cmd + [f"{user}@{host}"]


def classify_ssh_error(text):
    t = text.lower()
    if "host key verification failed" in t or "no matching host key" in t:
        return "unenrolled"
    if "permission denied" in t:
        return "denied"
    if "timed out" in t or "no route" in t or "connection refused" in t or "could not resolve" in t:
        return "unreachable"
    return "error"


def ssh_status(server, timeout=15):
    if not KEY_PATH().exists():
        return {"state": "nokey", "status": None, "error": "no key"}
    if not server.get("address"):
        return {"state": "error", "status": None, "error": "no address"}
    t0 = time.time()
    try:
        cp = subprocess.run(ssh_base(server["address"], server["port"], server["user"]) + ["status"],
                            capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"state": "unreachable", "status": None, "error": "timeout"}
    except FileNotFoundError:
        return {"state": "error", "status": None, "error": "ssh not installed"}
    ms = int((time.time() - t0) * 1000)
    if cp.returncode == 0:
        try:
            return {"state": "ok", "status": json.loads(cp.stdout.strip().splitlines()[-1]), "error": None, "ms": ms}
        except Exception:
            return {"state": "error", "status": None, "error": "bad status output"}
    return {"state": classify_ssh_error(cp.stderr + cp.stdout), "status": None, "error": clean_text(cp.stderr).strip()[:160]}


# ------------------------------------------------------------------ poll
def cmd_poll(args):
    st = load_state()
    nodes, err = api_fetch_nodes()
    servers = merge_servers(nodes)
    api_error = err
    if st.get("_xlog_api") != (err or "ok"):                 # log only when the panel status changes
        (xlog.warn if err else xlog.info)("panel api status changed", status=err or "ok", nodes=len(nodes),
                                          previous=st.get("_xlog_api"))
        st["_xlog_api"] = err or "ok"
    want = set(filter(None, (args.ids or "").split(",")))
    targets = [s for s in servers if not want or s["id"] in want]
    t = now()

    def work(s):
        sid = s["id"]
        info = st.get("ssh", {}).get(sid, {})
        if not args.ssh:
            return sid, None
        if info.get("next", 0) > t:
            return sid, {"state": info.get("state", "error"), "status": info.get("status"), "error": "backoff", "backoff": True}
        return sid, ssh_status(s)

    results = {}
    with ThreadPoolExecutor(max_workers=4) as pool:
        for sid, res in pool.map(work, targets):
            if res is not None:
                results[sid] = res

    st.setdefault("ssh", {})
    st.setdefault("online", {})
    for s in servers:
        sid = s["id"]
        res = results.get(sid)
        if res is not None and not res.get("backoff"):
            prev = st["ssh"].get(sid, {})
            if prev.get("state") != res["state"]:
                (xlog.info if res["state"] == "ok" else xlog.warn)("ssh state changed", server=s["name"], state=res["state"],
                                                                    previous=prev.get("state"), error=(res.get("error") or None) and str(res.get("error"))[:100])
            if res["state"] in ("ok", "unenrolled", "nokey"):
                fails = 0
            else:
                fails = prev.get("fails", 0) + 1
            nxt = t + min(600, 30 * (2 ** (fails - 1))) if fails else 0
            st["ssh"][sid] = {"state": res["state"], "status": res.get("status"), "fails": fails, "next": nxt, "ts": t}
        s["ssh"] = results.get(sid) or ({"state": st["ssh"].get(sid, {}).get("state", "unknown"),
                                         "status": st["ssh"].get(sid, {}).get("status"), "error": None}
                                        if sid in st["ssh"] else {"state": "unknown", "status": None, "error": None})
        s["enrolled"] = s["ssh"]["state"] == "ok"
        # up/down transitions -> events bus
        cur = s.get("online")
        if cur is not None:
            prev_online = st["online"].get(sid)
            if prev_online is not None and prev_online != cur:
                xlog.info("server went " + ("up" if cur else "down"), server=s["name"])
                emit_event("server.up" if cur else "server.down", {"id": sid, "name": s["name"]})
            st["online"][sid] = cur
        st.setdefault("servers", {})[sid] = {"name": s["name"], "address": s["address"], "port": s["port"], "user": s["user"]}
    save_state(st)
    out({"ok": err is None, "ts": t, "apiError": api_error,
         "servers": servers, "configured": bool(read_secret("remnawave_url") and read_secret("remnawave_token"))})
    return 0


# ------------------------------------------------------------------ run (streams lines)
def cmd_run(args):
    cmds, _ = all_commands()
    cmd = next((c for c in cmds if c["id"] == args.command), None)
    nonce = pysecrets.token_hex(6)
    print(f"::serp-start::{nonce}", flush=True)
    if not cmd or not TOKEN_RE.match(args.command):
        xlog.warn("run rejected: unknown command", command=str(args.command)[:40])
        print(f"::serp-exit::{nonce}::" + json.dumps({"code": 64, "error": "unknown command"}), flush=True)
        return 64
    st = load_state()
    srv = st.get("servers", {}).get(args.server)
    if not srv:
        nodes, _ = api_fetch_nodes()
        srv = next((s for s in merge_servers(nodes) if s["id"] == args.server), None)
    if not srv or not srv.get("address"):
        xlog.warn("run rejected: unknown server")
        print(f"::serp-exit::{nonce}::" + json.dumps({"code": 65, "error": "unknown server"}), flush=True)
        return 65
    t0 = time.time()
    xlog.info("run command", command=args.command, server=srv.get("name") or args.server, danger=cmd.get("danger"))
    timeout = int(cmd.get("timeout", 60)) + 15
    code, lines, dropped = 0, 0, 0
    expired = threading.Event()
    try:
        p = subprocess.Popen(ssh_base(srv["address"], srv["port"], srv["user"]) + [args.command],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    except FileNotFoundError:
        print(f"::serp-exit::{nonce}::" + json.dumps({"code": 127, "error": "ssh not installed"}), flush=True)
        return 127
    timer = threading.Timer(timeout, lambda: (expired.set(), p.kill()))
    timer.start()
    try:
        for raw in p.stdout:
            line = clean_text(raw.rstrip("\n"))
            if lines < MAX_LINES:
                print(line, flush=True)
                lines += 1
            else:
                dropped += 1
        code = p.wait()
        timed_out = expired.is_set()
    finally:
        timer.cancel()
    ms = int((time.time() - t0) * 1000)
    rec = {"ts": now(), "server": args.server, "name": srv.get("name", ""), "command": args.command, "code": code, "ms": ms}
    try:
        h = srv_state_dir() / "history.jsonl"
        h.parent.mkdir(parents=True, exist_ok=True)
        with open(h, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        _trim_history(h)
    except Exception:
        pass
    (xlog.info if code == 0 and not timed_out else xlog.warn)("run finished", command=args.command, server=srv.get("name") or args.server,
                                                              code=code, ms=ms, lines=lines, dropped=dropped, timed_out=timed_out or None)
    emit_event("server.command", {"id": args.server, "command": args.command, "code": code})
    print(f"::serp-exit::{nonce}::" + json.dumps({"code": code, "ms": ms, "dropped": dropped, "timedOut": timed_out}), flush=True)
    return 0


def _trim_history(path, keep=200):
    try:
        rows = path.read_text().splitlines()
        if len(rows) > keep * 2:
            atomic_write(path, "\n".join(rows[-keep:]) + "\n", 0o600)
    except Exception:
        pass


def cmd_history(args):
    rows = []
    try:
        for ln in (srv_state_dir() / "history.jsonl").read_text().splitlines()[-args.n:]:
            try:
                rows.append(json.loads(ln))
            except ValueError:
                pass
    except FileNotFoundError:
        pass
    out({"history": rows[::-1]})
    return 0


# ------------------------------------------------------------------ secrets / key
def cmd_secret_set(args):
    if args.name not in ("remnawave_url", "remnawave_token"):
        out({"ok": False, "error": "unknown secret"})
        return 2
    value = sys.stdin.readline().strip()
    if args.name == "remnawave_url":
        p = urllib.parse.urlparse(value)
        if p.scheme not in ("http", "https") or not p.hostname:
            out({"ok": False, "error": "bad_url"})
            return 2
        if p.scheme == "http" and p.hostname not in ("localhost", "127.0.0.1", "::1"):
            out({"ok": False, "error": "insecure_url"})
            return 2
        value = value.rstrip("/")
    else:
        if not (8 <= len(value) <= 4096) or re.search(r"\s", value):
            out({"ok": False, "error": "bad_token"})
            return 2
    atomic_write(secrets_dir() / args.name, value + "\n", 0o600)
    try:
        os.chmod(secrets_dir(), 0o700)
    except OSError:
        pass
    xlog.info("secret stored", name=args.name, length=len(value))
    out({"ok": True})
    return 0


def cmd_secret_status(_args):
    url, token = api_creds()
    host = urllib.parse.urlparse(url).hostname if url else ""
    out({"urlSet": bool(url), "tokenSet": bool(token), "host": host or ""})
    return 0


def key_fingerprint():
    pub = servers_dir() / "id_serp.pub"
    if not pub.exists():
        return ""
    cp = subprocess.run(["ssh-keygen", "-lf", str(pub)], capture_output=True, text=True)
    m = re.search(r"(SHA256:\S+)", cp.stdout)
    return m.group(1) if m else ""


def cmd_key_info(_args):
    out({"exists": KEY_PATH().exists(), "fingerprint": key_fingerprint(), "path": str(KEY_PATH())})
    return 0


def cmd_key_new(args):
    if KEY_PATH().exists() and not args.force:
        out({"ok": False, "error": "exists"})
        return 2
    servers_dir().mkdir(parents=True, exist_ok=True)
    os.chmod(servers_dir(), 0o700)
    for p in (KEY_PATH(), servers_dir() / "id_serp.pub"):
        try:
            p.unlink()
        except FileNotFoundError:
            pass
    cp = subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "serpantinum", "-f", str(KEY_PATH())],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        out({"ok": False, "error": "keygen_failed"})
        return 1
    st = load_state()
    st["ssh"] = {}  # every server needs the new public key
    save_state(st)
    out({"ok": True, "fingerprint": key_fingerprint()})
    return 0


def pubkey_line():
    pub = servers_dir() / "id_serp.pub"
    if not pub.exists():
        return ""
    parts = pub.read_text().split()
    return " ".join(parts[:2] + ["serpantinum"]) if len(parts) >= 2 else ""


# ------------------------------------------------------------------ enrollment (password used once)
def build_payload(extra_scripts=True):
    """tar.gz (base64) with serp-run, serp-root, install.sh, serp.conf.example and commands.d (+ user scripts)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name in ("serp-run", "serp-root", "install.sh", "serp.conf.example"):
            tar.add(SERVER_DIR / name, arcname=name, filter=_tar_filter)
        for f in sorted((SERVER_DIR / "commands.d").iterdir()):
            if f.is_file():
                tar.add(f, arcname="commands.d/" + f.name, filter=_tar_filter)
        if extra_scripts:
            cmds, _ = custom_commands()
            for c in cmds:
                src = c.get("script")
                if not src:
                    continue
                p = Path(os.path.expanduser(src))
                if p.is_file() and p.stat().st_size < 256 * 1024:
                    info = tar.gettarinfo(str(p), arcname="commands.d/" + c["id"])
                    info.mode, info.uid, info.gid, info.uname, info.gname = 0o755, 0, 0, "root", "root"
                    with open(p, "rb") as fh:
                        tar.addfile(info, fh)
    return base64.b64encode(buf.getvalue()).decode()


def _tar_filter(ti):
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mode = 0o755 if ti.mode & 0o111 or ti.isdir() else 0o644
    return ti


def remote_installer(pubkey, test_env=None, remove=False):
    env = f"SERP_PUBKEY={shlex.quote(pubkey)}"
    for k, v in (test_env or {}).items():
        env += f" {k}={shlex.quote(v)}"
    return ('D=$(mktemp -d) && base64 -d | tar xzf - -C "$D" && ' + env +
            ' sh "$D/install.sh"' + (' remove' if remove else '') + '; rc=$?; rm -rf "$D"; exit $rc')


def cmd_oneliner(_args):
    pk = pubkey_line()
    if not pk:
        out({"ok": False, "error": "no_key"})
        return 2
    script = ('D=$(mktemp -d) && echo ' + shlex.quote(build_payload()) + ' | base64 -d | tar xzf - -C "$D" && SERP_PUBKEY=' +
              shlex.quote(pk) + ' sh "$D/install.sh"; rc=$?; rm -rf "$D"; exit $rc')
    out({"ok": True, "command": "sudo sh -c " + shlex.quote(script)})
    return 0


def askpass_helper():
    return str(HERE / "askpass.sh")


def cmd_enroll(args):
    """Install the restricted key + serp-run on a server using the admin password ONCE.
    The password is read from stdin (first line), passed to ssh through the environment of the ssh process only
    (SSH_ASKPASS helper) and never appears in argv, logs or on disk."""
    host, port, user = args.host, args.port, args.user
    sid = args.server
    if sid:
        st = load_state()
        srv = st.get("servers", {}).get(sid)
        if not srv:
            nodes, _ = api_fetch_nodes()
            srv = next((s for s in merge_servers(nodes) if s["id"] == sid), None)
        if not srv:
            out({"ok": False, "step": "lookup", "error": "unknown server"})
            return 2
        host = host or srv["address"]
        port = port or srv["port"]
    if not host or not re.fullmatch(r"[A-Za-z0-9._:-]{1,253}", host):
        out({"ok": False, "step": "lookup", "error": "bad host"})
        return 2
    port = int(port or 22)
    pw = sys.stdin.readline().rstrip("\n")
    pk = pubkey_line()
    if not pk:
        out({"ok": False, "step": "key", "error": "no_key"})
        return 2
    if not KEY_PATH().exists():
        out({"ok": False, "step": "key", "error": "no_key"})
        return 2
    servers_dir().mkdir(parents=True, exist_ok=True)
    test_mode = os.environ.get("SERP_TEST_MODE") == "1"

    ssh = ["ssh", "-T", "-o", f"UserKnownHostsFile={KNOWN_HOSTS()}", "-o", "StrictHostKeyChecking=accept-new",
           "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR", "-p", str(port)]
    env = dict(os.environ)
    test_env = None
    if test_mode:
        # automated tests only: key login instead of a password, install into a prefix as an unprivileged user
        ssh += ["-i", os.environ["SERP_TEST_ADMIN_KEY"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
        test_env = {k: os.environ[k] for k in ("SERP_TEST", "SERP_PREFIX", "SERP_AUTH_KEYS") if k in os.environ}
        feed = ""
        remote = remote_installer(pk, test_env, args.uninstall)
    else:
        if not pw:
            out({"ok": False, "step": "login", "error": "empty password"})
            return 2
        ssh += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1"]
        env.update({"SSH_ASKPASS": askpass_helper(), "SSH_ASKPASS_REQUIRE": "force", "SERP_ASKPASS_PW": pw,
                    "DISPLAY": env.get("DISPLAY") or ":0"})
        remote = remote_installer(pk, None, args.uninstall)
        feed = ""
        if user != "root":
            remote = "sudo -S -p '' sh -c " + shlex.quote(remote)
            feed = pw + "\n"
    ssh += [f"{user}@{host}", remote]
    payload = build_payload()
    try:
        cp = subprocess.run(ssh, input=(feed + payload + "\n"), capture_output=True, text=True, env=env, timeout=120)
    except subprocess.TimeoutExpired:
        out({"ok": False, "step": "install", "error": "timeout"})
        return 1
    finally:
        pw = ""
        env.pop("SERP_ASKPASS_PW", None)
    outp = clean_text(cp.stdout)
    err = clean_text(cp.stderr).replace("\n", " ")[:240]
    if args.uninstall and cp.returncode == 0 and "SERP_REMOVE_OK" in outp:
        st = load_state()
        if sid:
            st.get("ssh", {}).pop(sid, None)
            save_state(st)
        xlog.info("restricted access removed from server", id=sid or None)
        out({"ok": True, "step": "remove", "state": "removed"})
        return 0
    if cp.returncode != 0 or ("SERP_INSTALL_OK" not in outp and not args.uninstall):
        step = "login" if re.search(r"permission denied|authentication", err, re.I) else "install"
        out({"ok": False, "step": step, "error": err or outp[-200:] or f"exit {cp.returncode}"})
        return 1
    # verify with the restricted key (strict host key check against what we just recorded)
    srv = {"address": host, "port": port, "user": args.serp_user}
    if test_mode:
        srv["user"] = os.environ.get("SERP_TEST_SERP_USER", args.serp_user)
    res = ssh_status(srv)
    st = load_state()
    if sid:
        st.setdefault("ssh", {})[sid] = {"state": res["state"], "status": res.get("status"), "fails": 0, "next": 0, "ts": now()}
        save_state(st)
    emit_event("server.enrolled", {"id": sid or host, "ok": res["state"] == "ok"})
    out({"ok": res["state"] == "ok", "step": "verify", "state": res["state"], "error": res.get("error")})
    return 0 if res["state"] == "ok" else 1


# ------------------------------------------------------------------ misc commands
def cmd_check(_args):
    nodes, err = api_fetch_nodes()
    out({"ok": err is None, "error": err, "nodes": len(nodes)})
    return 0 if err is None else 1


def cmd_commands(_args):
    cmds, problems = all_commands()
    out({"commands": cmds, "problems": problems})
    return 0


def cmd_config(_args):
    url, token = api_creds()
    cmds, problems = all_commands()
    out({"urlSet": bool(url), "tokenSet": bool(token), "host": urllib.parse.urlparse(url).hostname if url else "",
         "key": {"exists": KEY_PATH().exists(), "fingerprint": key_fingerprint()},
         "commands": cmds, "problems": problems, "dir": str(servers_dir())})
    return 0


def perms_ok(p):
    try:
        return (Path(p).stat().st_mode & 0o077) == 0
    except FileNotFoundError:
        return None


def cmd_doctor(args):
    rows = []

    def add(level, text):
        rows.append({"level": level, "text": text})

    for name in ("ssh", "ssh-keygen"):
        if not any((Path(d) / name).exists() for d in os.environ.get("PATH", "").split(":")):
            add("fail", f"не найден {name}")
    url, token = api_creds()
    add("ok" if url and token else "warn", "Remnawave: адрес и токен заданы" if url and token else "Remnawave: адрес или токен не заданы")
    for n in ("remnawave_url", "remnawave_token"):
        r = perms_ok(secrets_dir() / n)
        if r is False:
            add("fail", f"права файла {n} шире 600")
    if url and urllib.parse.urlparse(url).scheme == "http" and urllib.parse.urlparse(url).hostname not in ("localhost", "127.0.0.1", "::1"):
        add("fail", "адрес панели без https")
    if KEY_PATH().exists():
        add("ok" if perms_ok(KEY_PATH()) else "fail", "SSH-ключ виджета на месте" if perms_ok(KEY_PATH()) else "права SSH-ключа шире 600")
    else:
        add("warn", "SSH-ключ виджета не создан")
    _, problems = all_commands()
    for p in problems:
        add("warn", "commands.toml: " + p)
    st = load_state()
    for sid, info in st.get("ssh", {}).items():
        name = st.get("servers", {}).get(sid, {}).get("name", sid)
        s = info.get("state")
        add("ok" if s == "ok" else "warn", f"сервер {name}: SSH {'подключён' if s == 'ok' else 'не подключён (' + str(s) + ')'}")
    if args.lines:
        for r in rows:
            sys.stdout.write(f"  {r['level']:<5} {r['text']}\n")
    else:
        out({"checks": rows})
    return 1 if any(r["level"] == "fail" for r in rows) else 0


def main():
    ap = argparse.ArgumentParser(prog="x_servers.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("poll")
    p.add_argument("--ids", default="")
    p.add_argument("--ssh", action="store_true")
    p.set_defaults(fn=cmd_poll)
    p = sub.add_parser("run")
    p.add_argument("server")
    p.add_argument("command")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("history")
    p.add_argument("-n", type=int, default=20)
    p.set_defaults(fn=cmd_history)
    p = sub.add_parser("secret-set")
    p.add_argument("name")
    p.set_defaults(fn=cmd_secret_set)
    sub.add_parser("secret-status").set_defaults(fn=cmd_secret_status)
    sub.add_parser("key-info").set_defaults(fn=cmd_key_info)
    p = sub.add_parser("key-new")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_key_new)
    sub.add_parser("oneliner").set_defaults(fn=cmd_oneliner)
    p = sub.add_parser("enroll")
    p.add_argument("--server", default="")
    p.add_argument("--host", default="")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--user", default="root")
    p.add_argument("--serp-user", default="serp")
    p.add_argument("--uninstall", action="store_true")
    p.set_defaults(fn=cmd_enroll)
    p = sub.add_parser("add")
    p.add_argument("--name", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=22)
    p.add_argument("--user", default="serp")
    p.add_argument("--id", default="")
    p.set_defaults(fn=cmd_add)
    p = sub.add_parser("remove")
    p.add_argument("id")
    p.add_argument("--forget-host", action="store_true")
    p.set_defaults(fn=cmd_remove)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    sub.add_parser("commands").set_defaults(fn=cmd_commands)
    sub.add_parser("config").set_defaults(fn=cmd_config)
    p = sub.add_parser("doctor")
    p.add_argument("--lines", action="store_true")
    p.set_defaults(fn=cmd_doctor)
    args = ap.parse_args()
    quiet = args.cmd in ("list", "poll", "history", "secret-status", "key-info", "check", "commands", "config", "doctor")
    (xlog.debug if quiet else xlog.info)("cli " + args.cmd, server=getattr(args, "server", None) or None)
    t0, rc = time.time(), 1
    try:
        rc = args.fn(args) or 0
    except Exception as e:
        xlog.exception("cli %s crashed" % args.cmd, exc=e)
        raise
    finally:
        res = _LAST_OUT.get("obj")
        problem = isinstance(res, dict) and (res.get("ok") is False or res.get("error"))
        if problem:
            xlog.warn("cli %s reported a problem" % args.cmd, error=str(res.get("error") or res.get("apiError") or "")[:120] or None,
                      step=res.get("step"), stage=res.get("stage"))
        (xlog.debug if quiet and rc == 0 else (xlog.info if rc == 0 else xlog.warn))(
            "cli %s done" % args.cmd, rc=rc, ms=int((time.time() - t0) * 1000))
    sys.exit(rc)


if __name__ == "__main__":
    main()
