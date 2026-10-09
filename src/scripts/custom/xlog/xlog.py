#!/usr/bin/env python3
"""serpantinum-x shared logging (one convention for every custom module).

Files:   $SERPANTINUM_LOG_DIR or ~/.local/state/serpantinum/logs/<module>.log  (dir 0700, files 0600)
Line:    2026-10-06T12:34:56+03:00 LEVEL module message key=value ...
Rotate:  512 KB x 3 files (<module>.log, .log.1, .log.2).
Levels:  debug < info < warn < error. Default info; XLOG_LEVEL env or the <logdir>/.level file switches it.
Secrets: every line passes through redact() before it touches the disk.

Library:  import xlog; log = xlog.get("cmd"); log.info("started", pid=1); log.exception("boom")
CLI:      python3 xlog.py append <module> <level> <message...>   (used by bash `xlog`)
          python3 xlog.py append-stdin                           (QML appender: "module<TAB>level<TAB>message" lines)
          python3 xlog.py logs|level|report|doctor|redact ...    (see `serpantinum-x logs --help`)
Logging never raises: a broken log must not break a feature.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime

LEVELS = {"debug": 10, "info": 20, "warn": 30, "error": 40}
KNOWN_MODULES = ("update", "hotkeys", "tools", "servers", "vpn", "cmd", "ui", "doctor", "installer")
MAX_BYTES = int(os.environ.get("XLOG_MAX_BYTES", str(512 * 1024)))
KEEP = 3
_MOD_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,23}$")


# --------------------------------------------------------------------------- paths / level

def log_dir():
    d = os.environ.get("SERPANTINUM_LOG_DIR")
    if d:
        return d
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "serpantinum", "logs")


def level_threshold():
    name = os.environ.get("XLOG_LEVEL", "").strip().lower()
    if name not in LEVELS:
        try:
            with open(os.path.join(log_dir(), ".level"), encoding="utf-8") as f:
                name = f.read().strip().lower()
        except OSError:
            name = ""
    return LEVELS.get(name, LEVELS["info"])


# --------------------------------------------------------------------------- redaction

_ALLOWED_HOSTS = {
    "localhost", "127.0.0.1", "::1", "[::1]", "github.com", "api.github.com", "raw.githubusercontent.com",
    "objects.githubusercontent.com", "repo.steampowered.com", "aur.archlinux.org",
    "generativelanguage.googleapis.com", "ai.google.dev",
}
_SECRET_KEYS = (r"token|secret|password|passwd|pwd|passphrase|api[_-]?key|apikey|access[_-]?key|private[_-]?key|"
                r"authorization|cookie|session[_-]?id|credential|subscription|sub[_-]?url|panel[_-]?url|"
                r"remnawave[_-]?(?:url|token)|askpass")
_RE_PRIVKEY = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.S)
_RE_LINK = re.compile(r"\b(?:vless|vmess|ss|ssr|trojan|hysteria2|hysteria|hy2|tuic|wireguard)://\S+", re.I)
_RE_URL = re.compile(r"\b(https?)://([^\s/?#\"'<>)\]]*)([^\s\"'<>)\]]*)", re.I)
_RE_AUTH = re.compile(r"(?i)\b(authorization|proxy-authorization)\b(\s*[:=]\s*)(?:bearer\s+|basic\s+|token\s+)?[^\s,;\"']+")
_RE_BEARER = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}")
_RE_KV = re.compile(r"(?i)\b(" + _SECRET_KEYS + r")\b([\"']?\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s,;&}\]]+)")
_RE_UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
_RE_IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
_RE_IPV6 = re.compile(r"(?<![\w:])(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{0,4}(?![\w:])")
_RE_EMAILISH = re.compile(r"\b[\w.-]+@[\w-]+(?:\.[\w-]+)+\b")
_RE_BLOB = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])")
_RE_B64 = re.compile(r"(?<![A-Za-z0-9+/=])[A-Za-z0-9+]{32,}={0,2}(?![A-Za-z0-9+/=])")
_RE_ID_SEG = re.compile(r"^[A-Za-z0-9_-]{16,}$")


def _url_sub(m):
    scheme, authority, rest = m.group(1).lower(), m.group(2), m.group(3)
    if authority == "":          # already redacted ("https://<host>/…") or empty: leave as is
        return m.group(0)
    host = authority.rsplit("@", 1)[-1]
    hostname = host.split(":")[0].lower()
    if hostname not in _ALLOWED_HOSTS:
        return f"{scheme}://<host>" + ("/…" if rest.strip("/?") else "")
    path = rest.split("?", 1)[0].split("#", 1)[0]
    segs = ["<id>" if _RE_ID_SEG.match(s) else s for s in path.split("/")]
    out = f"{scheme}://{host}" + "/".join(segs)
    if "?" in rest:
        out += "?<q>"
    return out


def _ipv4_sub(m):
    s = m.group(0)
    try:
        o = [int(x) for x in s.split(".")]
    except ValueError:
        return s
    if any(x > 255 for x in o):
        return s
    if o[0] in (0, 10, 127) or (o[0] == 192 and o[1] == 168) or (o[0] == 172 and 16 <= o[1] <= 31) or (o[0] == 169 and o[1] == 254):
        return s
    return "<ip>"


def _blob_sub(m):
    s = m.group(0)
    if re.fullmatch(r"[0-9a-fA-F]+", s) or (re.search(r"\d", s) and re.search(r"[A-Za-z]", s)):
        return "<blob>"
    return s


def redact(text):
    """Remove secrets from any text. Idempotent; never raises."""
    try:
        s = str(text)
        s = _RE_PRIVKEY.sub("<private-key>", s)
        s = _RE_LINK.sub("<link>", s)
        s = _RE_URL.sub(_url_sub, s)
        s = _RE_AUTH.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", s)
        s = _RE_BEARER.sub(lambda m: f"{m.group(1)} <redacted>", s)
        s = _RE_KV.sub(lambda m: f"{m.group(1)}{m.group(2)}<redacted>", s)
        s = _RE_UUID.sub("<uuid>", s)
        s = _RE_EMAILISH.sub("<user@host>", s)
        s = _RE_IPV6.sub("<ip6>", s)
        s = _RE_IPV4.sub(_ipv4_sub, s)
        s = _RE_BLOB.sub(_blob_sub, s)
        s = _RE_B64.sub(_blob_sub, s)
        return s
    except Exception:
        return "<unredactable>"


# --------------------------------------------------------------------------- writing

def _valid_module(module):
    module = str(module).lower().strip()
    return module if _MOD_RE.match(module) else "misc"


def _ensure_dir(d):
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        return True
    except OSError:
        return False


def _rotate(path):
    lock = os.path.join(os.path.dirname(path), ".lock")
    try:
        with open(lock, "a") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            if os.path.getsize(path) < MAX_BYTES:  # someone else rotated meanwhile
                return
            for i in range(KEEP - 1, 0, -1):
                src = path if i == 1 else f"{path}.{i - 1}"
                dst = f"{path}.{i}"
                if os.path.exists(src):
                    os.replace(src, dst)
    except OSError:
        pass


def _fmt_kv(kv):
    parts = []
    for k, v in kv.items():
        if v is None:
            continue
        v = str(v)
        if re.search(r"[\s\"=]", v) or v == "":
            v = json.dumps(v, ensure_ascii=False)
        parts.append(f"{k}={v}")
    return (" " + " ".join(parts)) if parts else ""


def write_line(module, level, message, /, **kv):
    """Append one redacted line. Returns True if written."""
    try:
        level = str(level).lower()
        if level not in LEVELS:
            level = "info"
        if LEVELS[level] < level_threshold():
            return False
        module = _valid_module(module)
        d = log_dir()
        if not _ensure_dir(d):
            return False
        head, *cont = str(message).rstrip("\n").split("\n")
        ts = datetime.now().astimezone().isoformat(timespec="seconds")
        text = f"{ts} {level.upper()} {module} {head}{_fmt_kv(kv)}"
        if cont:
            text += "\n" + "\n".join("    " + c for c in cont)
        text = redact(text) + "\n"
        path = os.path.join(d, module + ".log")
        try:
            if os.path.getsize(path) >= MAX_BYTES:
                _rotate(path)
        except OSError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, text.encode("utf-8", "replace"))
        finally:
            os.close(fd)
        return True
    except Exception:
        return False


class Logger:
    def __init__(self, module):
        self.module = _valid_module(module)

    def _w(self, level, msg, kv):
        write_line(self.module, level, msg, **kv)

    def debug(self, msg, /, **kv): self._w("debug", msg, kv)
    def info(self, msg, /, **kv): self._w("info", msg, kv)
    def warn(self, msg, /, **kv): self._w("warn", msg, kv)
    warning = warn
    def error(self, msg, /, **kv): self._w("error", msg, kv)

    def exception(self, msg, /, exc=None, **kv):
        tb = "".join(traceback.format_exception(*(sys.exc_info() if exc is None else (type(exc), exc, exc.__traceback__))))
        self._w("error", f"{msg}\n{tb.rstrip()}", kv)

    def timer(self, what, /, **kv):
        return _Timer(self, what, kv)


class _Timer:
    def __init__(self, log, what, kv):
        self.log, self.what, self.kv = log, what, kv

    def __enter__(self):
        self.t = time.monotonic()
        return self

    def __exit__(self, et, ev, tb):
        ms = int((time.monotonic() - self.t) * 1000)
        if et is None:
            self.log.info(self.what, ms=ms, **self.kv)
        else:
            self.log.error(f"{self.what} failed", ms=ms, error=repr(ev), **self.kv)
        return False


_loggers = {}


def get(module):
    if module not in _loggers:
        _loggers[module] = Logger(module)
    return _loggers[module]


def run_logged(log, argv, **kw):
    """subprocess.run + a log line with exit code and duration (argv[0] only; arguments may be secret)."""
    t = time.monotonic()
    try:
        r = subprocess.run(argv, **kw)
        log.info("exec", cmd=os.path.basename(argv[0]), rc=r.returncode, ms=int((time.monotonic() - t) * 1000))
        return r
    except Exception as e:
        log.error("exec failed", cmd=os.path.basename(argv[0]), error=repr(e), ms=int((time.monotonic() - t) * 1000))
        raise


# --------------------------------------------------------------------------- reading helpers

def module_files():
    d = log_dir()
    try:
        names = sorted(f[:-4] for f in os.listdir(d) if f.endswith(".log"))
    except OSError:
        names = []
    return names


def read_tail(module, n=50, level=None, max_bytes=256 * 1024):
    path = os.path.join(log_dir(), _valid_module(module) + ".log")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    lines = data.split("\n")
    if size > max_bytes and lines:
        lines = lines[1:]
    # group continuation lines (indented) with their head line
    entries, cur = [], None
    for ln in lines:
        if not ln:
            continue
        if ln.startswith("    ") and cur is not None:
            cur += "\n" + ln
            continue
        if cur is not None:
            entries.append(cur)
        cur = ln
    if cur is not None:
        entries.append(cur)
    if level:
        thr = LEVELS.get(level, 0)
        entries = [e for e in entries if LEVELS.get(_entry_level(e), 20) >= thr]
    return entries[-n:]


def _entry_level(entry):
    parts = entry.split(" ", 2)
    return parts[1].lower() if len(parts) > 1 else "info"


def last_problem(module):
    for e in reversed(read_tail(module, 400, level="warn")):
        return e.split("\n")[0]
    return ""


# --------------------------------------------------------------------------- CLI

def _cmd_append(args):
    if len(args) < 3:
        print("usage: xlog.py append <module> <level> <message...>", file=sys.stderr)
        return 2
    write_line(args[0], args[1], " ".join(args[2:]))
    return 0


def _cmd_append_stdin(_args):
    for raw in sys.stdin:
        raw = raw.rstrip("\n")
        parts = raw.split("\t", 2)
        if len(parts) == 3:
            write_line(parts[0], parts[1], parts[2].replace("\\n", "\n"))
    return 0


def _cmd_logs(args):
    module, n, level, follow = None, 50, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-n", "--lines") and i + 1 < len(args):
            n = int(args[i + 1]); i += 2; continue
        if a == "--level" and i + 1 < len(args):
            level = args[i + 1].lower(); i += 2; continue
        if a in ("-f", "--follow"):
            follow = True; i += 1; continue
        if a in ("-h", "--help"):
            print("serpantinum-x logs [module] [-n N] [--level debug|info|warn|error] [--follow]\n"
                  "serpantinum-x logs level [debug|info|warn|error]\nserpantinum-x report [--out FILE] [-n N]")
            return 0
        module = a; i += 1
    if module == "level":
        return _cmd_level([a for a in args if a != "level"])
    d = log_dir()
    if module is None:
        names = sorted(set(module_files()) | set(KNOWN_MODULES))
        print(f"каталог логов: {d}   уровень: {_level_name()}")
        for m in names:
            p = os.path.join(d, m + ".log")
            try:
                st = os.stat(p)
                when = datetime.fromtimestamp(st.st_mtime).astimezone().strftime("%m-%d %H:%M")
                lp = last_problem(m)
                print(f"  {m:<9} {st.st_size // 1024:>4} KB  {when}  " + (f"последняя проблема: {lp}" if lp else "проблем нет"))
            except OSError:
                print(f"  {m:<9}    — нет записей")
        return 0
    for e in read_tail(module, n, level):
        print(e)
    if follow:
        path = os.path.join(d, _valid_module(module) + ".log")
        pos = os.path.getsize(path) if os.path.exists(path) else 0
        try:
            while True:
                time.sleep(0.7)
                if not os.path.exists(path):
                    continue
                size = os.path.getsize(path)
                if size < pos:
                    pos = 0
                if size > pos:
                    with open(path, "rb") as f:
                        f.seek(pos)
                        chunk = f.read().decode("utf-8", "replace")
                        pos = f.tell()
                    for ln in chunk.splitlines():
                        if not level or LEVELS.get(_entry_level(ln), 20) >= LEVELS.get(level, 0) or ln.startswith("    "):
                            print(ln, flush=True)
        except KeyboardInterrupt:
            pass
    return 0


def _level_name():
    thr = level_threshold()
    for k, v in LEVELS.items():
        if v == thr:
            return k
    return "info"


def _cmd_level(args):
    args = [a for a in args if a]
    if not args:
        print(_level_name())
        return 0
    lv = args[0].lower()
    if lv not in LEVELS:
        print("level: debug|info|warn|error", file=sys.stderr)
        return 2
    d = log_dir()
    _ensure_dir(d)
    with open(os.path.join(d, ".level"), "w", encoding="utf-8") as f:
        f.write(lv + "\n")
    print(f"уровень логов: {lv}")
    return 0


def _sh(argv, timeout=20):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        return (r.stdout + (("\n" + r.stderr) if r.stderr.strip() else "")).strip()
    except FileNotFoundError:
        return f"(нет команды {argv[0]})"
    except Exception as e:
        return f"(не удалось: {e!r})"


def _quickshell_log_filtered():
    try:
        out = subprocess.run(["pgrep", "-f", "quickshell -p"], capture_output=True, text=True, timeout=5).stdout.split()
    except Exception:
        return "(pgrep недоступен)"
    for pid in out:
        fd_dir = f"/proc/{pid}/fd"
        try:
            for fd in os.listdir(fd_dir):
                try:
                    tgt = os.readlink(os.path.join(fd_dir, fd))
                except OSError:
                    continue
                if tgt.endswith("/log.log") and "/quickshell/" in tgt:
                    with open(tgt, "rb") as f:
                        f.seek(0, os.SEEK_END)
                        f.seek(max(0, f.tell() - 400 * 1024))
                        txt = f.read().decode("utf-8", "replace")
                    ansi = re.compile(r"\x1b\[[0-9;]*m")
                    keep = [ansi.sub("", l) for l in txt.split("\n")
                            if "serpantinum-x" in l or " ERROR" in l or "ERROR:" in l or " WARN" in l]
                    return "\n".join(keep[-120:]) or "(в логе оболочки нет записей serpantinum-x/WARN/ERROR)"
        except OSError:
            continue
    return "(живой процесс quickshell не найден)"


def build_report(n=60):
    here = os.path.dirname(os.path.abspath(__file__))
    custom = os.path.normpath(os.path.join(here, ".."))
    repo = os.environ.get("XLOG_REPO") or os.path.normpath(os.path.join(custom, "..", "..", ".."))
    x = os.environ.get("SERPANTINUM_X") or os.path.join(repo, "bin", "serpantinum-x")
    sections = []

    def add(title, body):
        sections.append(f"===== {title} =====\n{body.rstrip()}\n")

    add("отчёт", f"создан {datetime.now().astimezone().isoformat(timespec='seconds')}\nлоги: {log_dir()}  уровень: {_level_name()}")
    ver = ""
    try:
        with open(os.path.join(os.path.expanduser("~"), ".local", "state", "serpantinum", "version"), encoding="utf-8") as f:
            ver = "".join(l for l in f if l.startswith("SERPANTINUM_"))
    except OSError:
        ver = "(нет файла версии)"
    add("версии", ver + "\nrepo: " + _sh(["git", "-C", repo, "log", "--oneline", "-1"]) + "\nветка: " + _sh(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"]))
    if os.path.exists(x):
        add("doctor", _sh(["bash", x, "doctor"], 60))
        add("cmd status", _sh(["bash", x, "cmd", "status"], 30))
    add("hyprctl configerrors", _sh(["hyprctl", "configerrors"], 10) or "(ошибок нет)")
    add("systemctl --user serpantinum-cmdd", _sh(["systemctl", "--user", "status", "serpantinum-cmdd", "--no-pager", "-n", "15"], 10))
    for m in sorted(set(module_files()) | set(KNOWN_MODULES)):
        body = "\n".join(read_tail(m, n)) or "(нет записей)"
        add(f"лог {m} (последние {n})", body)
    add("лог оболочки quickshell (serpantinum-x / WARN / ERROR)", _quickshell_log_filtered())
    return redact("\n".join(sections))


def _cmd_report(args):
    out, n, i = None, 60, 0
    while i < len(args):
        if args[i] == "--out" and i + 1 < len(args):
            out = args[i + 1]; i += 2; continue
        if args[i] in ("-n", "--lines") and i + 1 < len(args):
            n = int(args[i + 1]); i += 2; continue
        i += 1
    text = build_report(n)
    if out is None:
        base = os.path.join(os.path.dirname(log_dir()), "reports")
        _ensure_dir(base)
        out = os.path.join(base, "report-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".txt")
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    print(out)
    write_line("doctor", "info", "report written", path=os.path.basename(out), bytes=len(text))
    return 0


def _cmd_doctor(_args):
    checks = []
    d = log_dir()
    ok_dir = _ensure_dir(d) and os.access(d, os.W_OK)
    checks.append({"level": "ok" if ok_dir else "warn",
                   "text": f"каталог логов {d} " + ("доступен для записи" if ok_dir else "недоступен для записи: логи не пишутся")})
    for m in KNOWN_MODULES:
        lp = last_problem(m)
        if lp:
            checks.append({"level": "warn", "text": f"лог {m}: последняя проблема — {lp[:220]}"})
    print(json.dumps({"checks": checks}, ensure_ascii=False))
    return 0


def _cmd_redact(_args):
    sys.stdout.write(redact(sys.stdin.read()))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    table = {"append": _cmd_append, "append-stdin": _cmd_append_stdin, "logs": _cmd_logs, "level": _cmd_level,
             "report": _cmd_report, "doctor": _cmd_doctor, "redact": _cmd_redact}
    if cmd not in table:
        print(f"xlog: unknown command {cmd}", file=sys.stderr)
        return 2
    return table[cmd](rest)


if __name__ == "__main__":
    sys.exit(main())
