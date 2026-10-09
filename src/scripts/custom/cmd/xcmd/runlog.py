"""Run log (jsonl, design §5): one line per run, values truncated, secrets masked, clipboard content never stored."""
import json
import os
import re

from .util import read_text
from .xlogshim import log

LIMIT = 200
RETENTION_DAYS = 30


_SECRET_RES = (
    (re.compile(r"(?i)(authorization:\s*(?:bearer|basic)\s+)\S+"), r"\1***"),
    (re.compile(r"(?i)\b(api[_-]?key|access[_-]?token|token|passw(?:or)?d|secret|pwd)(\s*[=:]\s*)[^\s&,;\"']+"), r"\1\2***"),
    (re.compile(r"\b(?:sk|pk)-[A-Za-z0-9_-]{16,}"), "***"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{20,}"), "***"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "***"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"), "***"),
)


def redact_text(s):
    """Masks things that look like credentials inside free text (log, trace, rehearsal plans)."""
    if not isinstance(s, str) or len(s) < 6:
        return s
    for rx, rep in _SECRET_RES:
        s = rx.sub(rep, s)
    return s


def shorten(value, limit=LIMIT):
    if value is None or isinstance(value, (bool, int, float)):
        return value
    try:
        s = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        s = repr(value)
    s = redact_text(s)
    return s if len(s) <= limit else s[:limit - 1] + "…"


def log_value(pin, value, private=None):
    """What may be written to the log for a pin value, honouring the pin's log mode. `private` (a per-run set) collects the
    text of «length»/«mask» pins: the same text travelling on to other nodes (clipboard link -> notification body) stays hidden too."""
    if pin is not None and (pin.secret or pin.log in ("mask", "length")) and private is not None and isinstance(value, str) and len(value) >= 4:
        private.add(value)
    if pin is not None:
        if pin.secret or pin.log == "mask":
            return "***"
        if pin.log == "length":
            n = len(value) if hasattr(value, "__len__") else 1
            return "‹%d символов›" % n if isinstance(value, str) else "‹длина %d›" % n
    if private and isinstance(value, str) and any(x in value for x in private):
        return "‹%d символов›" % len(value)
    return shorten(value)


def _summarize(entry):
    """One compact line per finished run in the shared module log (no pin values, no free text)."""
    try:
        status = entry.get("status", "?")
        fn = log.info if status == "ok" else (log.error if status == "error" else log.warn)
        fn("run %s" % status, cmd=entry.get("name") or entry.get("cmd"), run=entry.get("run"), trigger=entry.get("trigger"),
           reason=entry.get("reason") or None, dur=entry.get("dur"), steps=len(entry.get("steps") or []),
           failed_node=entry.get("failed_node"), undone=entry.get("undone") or None, dry=entry.get("dry_run") or None)
    except Exception:
        pass


class RunLog:
    def __init__(self, directory, clock):
        self.path = os.path.join(directory, "runs.jsonl")
        self.clock = clock
        self._since_prune = 0
        os.makedirs(directory, exist_ok=True)

    def append(self, entry):
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        _summarize(entry)
        self._since_prune += 1
        if self._since_prune >= 100:
            self.prune()

    def read(self):
        if not os.path.exists(self.path):
            return []
        out = []
        for line in read_text(self.path).splitlines():
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
        return out

    def tail(self, n=20):
        return self.read()[-n:]

    def prune(self, days=RETENTION_DAYS):
        self._since_prune = 0
        cutoff = self.clock.now() - days * 86400
        keep = [e for e in self.read() if e.get("ts", cutoff + 1) >= cutoff]
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for e in keep:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")
        os.replace(tmp, self.path)
