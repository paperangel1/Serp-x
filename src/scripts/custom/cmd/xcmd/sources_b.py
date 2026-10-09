"""Event sources of trigger batch B (design §6): audio (headphones), clipboard links, new files in a folder, servers
(events bus), Wi-Fi, USB and notifications. Everything is read-only; external tools are only watched (`pactl subscribe`,
`wl-paste --watch`, `nmcli monitor`, `udevadm monitor`, `busctl --user monitor`) or asked for a status snapshot.

Privacy: clipboard and notification text never reaches a log or the stored run log; sources log the domain and the length
(clipboard) or the application name (notifications) only. The `event` topic carries a redacted copy (see triggers.public_event)."""
import asyncio
import ctypes
import fnmatch
import json
import os
import re
import signal
import struct
import time
from urllib.parse import urlparse

from . import pure
from .procs import session_env
from .sources import Source
from .xlogshim import log as xlog

SENSITIVE = {"clipboard.link": ("url",), "clipboard.color": ("hex", "rgb"), "clipboard.phone": ("digits", "e164"),
             "notification.received": ("title", "body")}     # fields that never leave the run
OWN_COPY = {"until": 0.0}
OWN_COPY_WINDOW_S = 2.0


def mark_own_copy(now=None):
    """Called by our own clipboard writers: the next clipboard change is ours and must not start automations."""
    OWN_COPY["until"] = (time.monotonic() if now is None else now) + OWN_COPY_WINDOW_S


def public_event(event):
    """Copy of an event that is safe for `cmd events`, `cmd status` and logs: sensitive fields become their length."""
    fields = SENSITIVE.get(event.get("type"))
    if not fields:
        return event
    data = dict(event.get("data") or {})
    for f in fields:
        if f in data:
            data[f] = "‹%d›" % len(str(data[f]))
    return dict(event, data=data)


async def run_text(argv, env=None, timeout=5.0):
    """One short read-only tool call -> text ('' on any failure)."""
    try:
        p = await asyncio.create_subprocess_exec(*argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                                                 stdin=asyncio.subprocess.DEVNULL, env=env or session_env())
        out, _ = await asyncio.wait_for(p.communicate(), timeout)
        return out.decode("utf-8", "replace") if p.returncode == 0 else ""
    except (OSError, asyncio.TimeoutError):
        return ""


class StreamSource(Source):
    """A source fed by a long-running tool: records are split by `sep`, the tool is restarted with a growing delay."""
    tool = "?"
    argv = ()
    sep = b"\n"
    retry = (1, 2, 4, 8, 15, 30)
    missing_hint = ""

    def command(self):
        return list(self.argv)

    def env(self):
        env = session_env()
        env["LC_ALL"] = "C"
        return env

    async def on_start(self):
        return None

    async def on_record(self, rec):
        raise NotImplementedError

    async def run(self):
        attempt = 0
        while True:
            try:
                proc = await asyncio.create_subprocess_exec(*self.command(), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
                                                            stdin=asyncio.subprocess.DEVNULL, env=self.env(), limit=1 << 20, start_new_session=True)
            except FileNotFoundError:
                self.set_state("failed", "Не найдена программа «%s»%s" % (self.tool, self.missing_hint))
                return
            except OSError as e:
                self.set_state("waiting", "%s: %s" % (self.tool, e))
                await asyncio.sleep(self.retry[min(attempt, len(self.retry) - 1)])
                attempt += 1
                continue
            t0 = time.monotonic()
            self.set_state("running")
            try:
                await self.on_start()
                while True:
                    try:
                        raw = await proc.stdout.readuntil(self.sep)
                    except asyncio.IncompleteReadError:
                        break
                    except asyncio.LimitOverrunError:
                        await proc.stdout.read(1 << 20)                  # a record that big is garbage: drop it
                        continue
                    await self.on_record(raw[:-len(self.sep)].decode("utf-8", "replace"))
            finally:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)               # the tool and anything it started
                except (ProcessLookupError, PermissionError):
                    pass
                await proc.wait()
                proc._transport.close()
            if time.monotonic() - t0 > 30:
                attempt = 0
            self.set_state("waiting", "«%s» завершился, запускаю заново" % self.tool)
            await asyncio.sleep(self.retry[min(attempt, len(self.retry) - 1)])
            attempt += 1


def _csv(value):
    return [x.strip().lower() for x in str(value or "").replace(";", ",").split(",") if x.strip()]


# --------------------------------------------------------------------------------------------------- headphones
PORT_HEADPHONES = ("headphones", "headset")


def parse_sinks(text):
    """`pactl list sinks` (LC_ALL=C) -> [{name, desc, port, ports: {name: (type, available)}, form}]."""
    sinks, cur, in_ports = [], None, False
    for line in text.splitlines():
        if line.startswith("Sink #"):
            cur = {"name": "", "desc": "", "port": "", "ports": {}, "form": ""}
            sinks.append(cur)
            in_ports = False
        elif cur is None:
            continue
        elif line.startswith("\tName: "):
            cur["name"] = line[7:].strip()
        elif line.startswith("\tDescription: "):
            cur["desc"] = line[14:].strip()
        elif line.startswith("\tActive Port: "):
            cur["port"] = line[14:].strip()
        elif line.startswith("\tPorts:"):
            in_ports = True
        elif in_ports and line.startswith("\t\t"):
            m = re.match(r"\t\t(\S+): .*\(type: ([^,)]+)", line)
            if m:
                cur["ports"][m.group(1)] = (m.group(2).strip(), "not available" not in line)
        elif line.startswith("\t") and not line.startswith("\t\t"):
            in_ports = False
        m = re.search(r'device\.form_factor = "([^"]*)"', line)
        if cur is not None and m:
            cur["form"] = m.group(1)
    return sinks


def headphones_of(sinks):
    """{sink name: {name, kind}} for the sinks that are headphones: BlueZ audio sinks and wired headphone/headset ports."""
    out = {}
    for s in sinks:
        if s["name"].startswith(("bluez_output", "bluez_sink")):
            if s["form"] not in ("speaker", "hifi", "portable", "car"):
                out[s["name"]] = {"name": s["desc"] or s["name"], "kind": "bluetooth"}
            continue
        ptype, avail = s["ports"].get(s["port"], ("", False))
        if ptype.lower() in PORT_HEADPHONES and avail:
            out[s["name"]] = {"name": s["desc"] or s["name"], "kind": "wired"}
    return out


class AudioSource(StreamSource):
    name = "audio"
    types = ("audio.headphones_connected", "audio.headphones_disconnected")
    tool = "pactl"
    argv = ("pactl", "subscribe")
    missing_hint = " (пакет libpulse или pipewire-pulse)"
    debounce = 1.0

    def __init__(self):
        super().__init__()
        self.known = None
        self._timer = None

    async def snapshot(self):
        text = await run_text(["pactl", "list", "sinks"], env=self.env())
        return headphones_of(parse_sinks(text)) if text else None

    async def on_start(self):
        snap = await self.snapshot()
        self.known = snap if snap is not None else {}

    async def on_record(self, rec):
        if not re.search(r"on (sink|card|server)\b", rec):
            return
        if self._timer is None or self._timer.done():
            self._timer = asyncio.ensure_future(self._settle())

    async def _settle(self):
        await asyncio.sleep(self.debounce)                              # a burst of sink/port events is one change
        snap = await self.snapshot()
        if snap is None:
            return
        old, self.known = self.known or {}, snap
        for key in sorted(set(snap) - set(old)):
            xlog.info("audio headphones connected", kind=snap[key]["kind"])
            await self.fire("audio.headphones_connected", dict(snap[key]))
        for key in sorted(set(old) - set(snap)):
            xlog.info("audio headphones disconnected", kind=old[key]["kind"])
            await self.fire("audio.headphones_disconnected", dict(old[key]))

    async def stop(self):
        if self._timer:
            self._timer.cancel()
        await super().stop()


# ---------------------------------------------------------------------------------------------------- clipboard
URL_RE = re.compile(r"^https?://[^\s<>\"']{3,2000}$", re.I)
CLIP_CMD = "head -c 2100; printf '\\0'"


def parse_clip_record(rec):
    """Clipboard text -> {url, domain} when the whole text is one http(s) link, else None."""
    text = rec.strip()
    if not URL_RE.match(text):
        return None
    host = (urlparse(text).hostname or "").lower().rstrip(".")
    return {"url": text, "domain": host} if host else None


HEX_RE = re.compile(r"^#([0-9a-f]{3}|[0-9a-f]{6})$", re.I)
RGB_RE = re.compile(r"^rgb\(\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*\)$", re.I)
HSL_RE = re.compile(r"^hsl\(\s*(-?\d{1,3}(?:\.\d+)?)(?:deg)?\s*[,\s]\s*(\d{1,3}(?:\.\d+)?)%\s*[,\s]\s*(\d{1,3}(?:\.\d+)?)%\s*\)$", re.I)


def parse_color(text):
    """The WHOLE text is one colour (#rgb, #rrggbb, rgb(), hsl()) -> {hex: '#RRGGBB', rgb: 'rgb(r, g, b)'} or None."""
    s = text.strip()
    if len(s) > 40:
        return None
    m = HEX_RE.match(s)
    if m:
        h = m.group(1)
        h = "".join(c * 2 for c in h) if len(h) == 3 else h
        r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    elif RGB_RE.match(s):
        r, g, b = (int(x) for x in RGB_RE.match(s).groups())
        if max(r, g, b) > 255:
            return None
    elif HSL_RE.match(s):
        hh, ss, ll = (float(x) for x in HSL_RE.match(s).groups())
        if ss > 100 or ll > 100:
            return None
        import colorsys
        r, g, b = (int(round(c * 255)) for c in colorsys.hls_to_rgb((hh % 360) / 360.0, ll / 100.0, ss / 100.0))
    else:
        return None
    return {"hex": "#%02X%02X%02X" % (r, g, b), "rgb": "rgb(%d, %d, %d)" % (r, g, b)}


PHONE_RE = re.compile(r"^\+?[\d\s().\-]{6,26}$")
NOT_PHONE = (re.compile(r"^\d{4}-\d{1,2}-\d{1,2}$"), re.compile(r"^\d{1,2}[./]\d{1,2}[./]\d{2,4}$"), re.compile(r"^\d{1,3}(\.\d{1,3}){3}$"))


def parse_phone(text):
    """The WHOLE text looks like a phone number (7-15 digits; a plain run of digits needs 10-15) -> {digits, e164} or None.
    e164 is «E.164-ish»: 8… (11 digits) and bare 10-digit numbers become +7…, anything else is «+» and the digits."""
    s = text.strip()
    if not PHONE_RE.match(s) or any(rx.match(s) for rx in NOT_PHONE):
        return None
    digits = re.sub(r"\D", "", s)
    plain = re.fullmatch(r"\d+", s) is not None
    if not 7 <= len(digits) <= 15 or (plain and len(digits) < 10):
        return None
    if s.startswith("+"):
        e164 = "+" + digits
    elif len(digits) == 11 and digits[0] in "78":
        e164 = "+7" + digits[1:]
    elif len(digits) == 10 and digits[0] == "9":
        e164 = "+7" + digits
    else:
        e164 = "+" + digits
    return {"digits": digits, "e164": e164}


def domain_ok(domain, wanted):
    return not wanted or any(domain == w or domain.endswith("." + w) for w in wanted)


def clip_matches(params, data):
    if not domain_ok(data.get("domain", ""), _csv(params.get("domains"))):
        return False
    rx = str(params.get("regex") or "")
    if rx:
        try:
            return re.search(rx, data.get("url", ""), re.I) is not None
        except re.error:
            return False
    return True


class ClipboardSource(StreamSource):
    name = "clipboard"
    types = ("clipboard.link", "clipboard.color", "clipboard.phone")
    tool = "wl-paste"
    sep = b"\0"
    missing_hint = " (пакет wl-clipboard)"
    debounce = 2.0

    def __init__(self):
        super().__init__()
        self._last = ("", -1e9)
        self.ignored_own = 0

    def command(self):
        return ["wl-paste", "--type", "text", "--watch", "bash", "-c", CLIP_CMD]

    async def on_record(self, rec):
        if time.monotonic() < OWN_COPY["until"]:
            self.ignored_own += 1
            return
        data = parse_clip_record(rec)
        kind, body = "link", (data or {}).get("url", "")
        if data is None:
            data = parse_color(rec)
            kind, body = "color", rec.strip()
        if data is None:
            data = parse_phone(rec)
            kind, body = "phone", rec.strip()
        if data is None:
            return
        now = time.monotonic()
        if body == self._last[0] and now - self._last[1] < self.debounce:
            return
        self._last = (body, now)
        # never the content itself: only the kind and the length (and the domain of a link)
        xlog.info("clipboard " + kind, length=len(body), **({"domain": data["domain"]} if kind == "link" else {}))
        await self.fire("clipboard." + kind, data)


# ----------------------------------------------------------------------------------------------------- folder
IN_CLOSE_WRITE, IN_MOVED_TO, IN_CREATE, IN_ISDIR = 0x8, 0x80, 0x100, 0x40000000
IGNORED_EXT = (".part", ".crdownload", ".tmp", ".download", ".opdownload", ".partial", ".temp", ".swp")


class Inotify:
    """Minimal inotify through ctypes (no external dependency)."""

    def __init__(self):
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.wd = {}

    def add(self, path):
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(path), IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE)
        if wd < 0:
            raise OSError(ctypes.get_errno(), "inotify_add_watch", path)
        self.wd[wd] = path
        return wd

    def remove(self, wd):
        self.libc.inotify_rm_watch(self.fd, wd)
        self.wd.pop(wd, None)

    def read(self):
        try:
            buf = os.read(self.fd, 65536)
        except BlockingIOError:
            return []
        out, i = [], 0
        while i + 16 <= len(buf):
            wd, mask, _cookie, ln = struct.unpack_from("iIII", buf, i)
            name = buf[i + 16:i + 16 + ln].split(b"\0", 1)[0]
            out.append((self.wd.get(wd), mask, os.fsdecode(name)))
            i += 16 + ln
        return out

    def close(self):
        os.close(self.fd)


def file_ignored(name):
    low = name.lower()
    return name.startswith(".") or low.endswith(IGNORED_EXT) or low.endswith("~")


def file_wanted(params, name):
    """Glob/extension filter: «*.pdf, *.png», «pdf png» or empty = everything."""
    pats = [p for p in re.split(r"[,;\s]+", str(params.get("pattern") or "").strip()) if p]
    if not pats:
        return True
    low = name.lower()
    return any(fnmatch.fnmatch(low, (p if any(c in p for c in "*?[") else "*." + p.lstrip(".")).lower()) for p in pats)


class FolderSource(Source):
    name = "folder"
    types = ("folder.new_file",)
    stable_s = 3.0
    poll_s = 0.5
    max_watches = 256

    def __init__(self):
        super().__init__()
        self.ino = None
        self.watched = {}               # dir -> wd
        self.pending = {}               # (sub key, path) -> [last size, stable since]
        self.fired = {}                 # (sub key, path) -> time, so a rewritten file does not fire twice
        self._wake = None
        self.errors = {}

    def configure(self, subs):
        super().configure(subs)
        if self.ino is not None:
            self.sync_watches()

    @staticmethod
    def folder_of(sub):
        return os.path.abspath(os.path.expanduser(str(sub.params.get("folder") or "~/Downloads")))

    def dirs_for(self, sub):
        root = self.folder_of(sub)
        if not os.path.isdir(root):
            return []
        out = [root]
        if sub.params.get("recursive"):
            for d, subdirs, _ in os.walk(root):
                subdirs[:] = [s for s in subdirs if not s.startswith(".")]
                out += [os.path.join(d, s) for s in subdirs]
        return out

    def sync_watches(self):
        want, self.errors = set(), {}
        for sub in self.subs.values():
            if not os.path.isdir(self.folder_of(sub)):
                self.errors[sub.key] = "Папки «%s» нет" % self.folder_of(sub)
            want.update(self.dirs_for(sub))
        for d in list(self.watched):
            if d not in want:
                self.ino.remove(self.watched.pop(d))
        for d in sorted(want - set(self.watched)):
            if len(self.watched) >= self.max_watches:
                raise OSError("Слишком много наблюдаемых папок (больше %d): отключите «Вложенные папки»" % self.max_watches)
            try:
                self.watched[d] = self.ino.add(d)
            except OSError as e:
                if e.errno == 28:
                    raise OSError("Исчерпан лимит наблюдателей inotify (fs.inotify.max_user_watches)")
                self.errors[d] = "%s: %s" % (d, e.strerror)

    def subs_for(self, path):
        d = os.path.dirname(path)
        for sub in self.subs.values():
            root = self.folder_of(sub)
            inside = d == root or (sub.params.get("recursive") and (d + os.sep).startswith(root + os.sep))
            if inside and file_wanted(sub.params, os.path.basename(path)):
                yield sub

    def note(self, path):
        for sub in self.subs_for(path):
            self.pending.setdefault((sub.key, path), [-1, None])

    async def check_pending(self, now):
        for k, st in list(self.pending.items()):
            key, path = k
            try:
                size = os.stat(path).st_size
            except OSError:
                del self.pending[k]
                continue
            if size != st[0]:
                st[0], st[1] = size, now
                continue
            if now - st[1] >= self.stable_s:
                del self.pending[k]
                if self.fired.get(k, -1e9) > now - 60 or key not in self.subs:
                    continue
                self.fired[k] = now
                if len(self.fired) > 500:
                    self.fired = {a: b for a, b in self.fired.items() if now - b < 60}
                kind = pure.file_kind({"path": path})["kind"]
                xlog.info("folder new file", kind=kind)                     # file names stay out of the log
                await self.fire("folder.new_file", {"path": path, "name": os.path.basename(path), "kind": kind}, key=key)

    async def run(self):
        loop = asyncio.get_event_loop()
        try:
            self.ino = Inotify()
        except OSError as e:
            raise OSError("inotify недоступен: %s" % (e.strerror or e))
        self._wake = asyncio.Event()
        loop.add_reader(self.ino.fd, self._wake.set)
        try:
            self.sync_watches()
            self.set_state("running", "; ".join(self.errors.values()))
            while True:
                try:
                    await asyncio.wait_for(self._wake.wait(), self.poll_s)
                except asyncio.TimeoutError:
                    pass
                self._wake.clear()
                for d, mask, name in self.ino.read():
                    if d is None or not name or file_ignored(name):
                        continue
                    path = os.path.join(d, name)
                    if mask & IN_ISDIR:
                        if mask & (IN_CREATE | IN_MOVED_TO) and any(s.params.get("recursive") for s in self.subs.values()):
                            self.sync_watches()
                        continue
                    if mask & (IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE) and os.path.isfile(path):
                        self.note(path)
                await self.check_pending(time.monotonic())
        finally:
            loop.remove_reader(self.ino.fd)
            self.ino.close()
            self.ino = None
            self.watched = {}

    def info(self):
        d = super().info()
        d["errors"] = dict(self.errors)
        return d


# ----------------------------------------------------------------------------------------------------- servers
EVENT_MAP = {"server.down": "server.unreachable", "server.up": "server.recovered"}


def servers_events_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.environ.get("XCMD_SERVERS_EVENTS") or os.path.join(base, "serpantinum", "events.jsonl")


def parse_server_event(line):
    """One events.jsonl line of the servers module -> (type, data) or None."""
    try:
        ev = json.loads(line)
    except ValueError:
        return None
    t = EVENT_MAP.get(ev.get("type")) if isinstance(ev, dict) else None
    d = ev.get("data") if t else None
    if not isinstance(d, dict):
        return None
    name = str(d.get("name") or d.get("id") or "")
    reason = "перестал отвечать по данным панели" if t == "server.unreachable" else "снова отвечает"
    return t, {"server": str(d.get("id") or ""), "server_name": name, "reason": reason}


class ServersSource(Source):
    """Tails the shared events bus written by the servers module (read-only); starts at the end of the file."""
    name = "servers"
    types = ("server.unreachable", "server.recovered")
    poll_s = 1.0

    def __init__(self, path=None):
        super().__init__()
        self.path = path

    def events_path(self):
        return self.path or servers_events_file()

    def parse(self, line):
        return parse_server_event(line)

    def log_event(self, parsed):
        xlog.info("servers event", type=parsed[0], server=parsed[1]["server_name"])

    async def run(self):
        path = self.events_path()
        try:
            pos = os.path.getsize(path)
        except OSError:
            pos = 0
        buf = b""
        while True:
            await asyncio.sleep(self.poll_s)
            try:
                size = os.path.getsize(path)
            except OSError:
                pos, buf = 0, b""
                continue
            if size < pos:                                              # the bus was trimmed or recreated
                pos, buf = 0, b""
            if size == pos:
                continue
            with open(path, "rb") as f:
                f.seek(pos)
                chunk = f.read(1 << 20)
            pos += len(chunk)
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for raw in lines:
                parsed = self.parse(raw.decode("utf-8", "replace"))
                if parsed:
                    self.log_event(parsed)
                    await self.fire(parsed[0], parsed[1])


# ------------------------------------------------------------------------------------------------------ Wi-Fi
def split_nmcli(line):
    """Terse nmcli line -> fields (':' separates, '\\:' is a literal colon)."""
    return [f.replace("\\:", ":").replace("\\\\", "\\") for f in re.split(r"(?<!\\):", line)]


def parse_wifi_status(text):
    """`nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device` -> connection name of the connected Wi-Fi device or ''."""
    for line in text.splitlines():
        f = split_nmcli(line)
        if len(f) >= 4 and f[1] == "wifi" and f[2].startswith("connected") and f[3] not in ("", "--"):
            return f[3]
    return ""


class WifiSource(StreamSource):
    name = "wifi"
    types = ("wifi.connected", "wifi.disconnected")
    tool = "nmcli"
    argv = ("nmcli", "monitor")
    missing_hint = " (NetworkManager)"
    debounce = 1.0

    def __init__(self):
        super().__init__()
        self.current = None
        self._timer = None

    async def ssid(self):
        text = await run_text(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"], env=self.env())
        conn = parse_wifi_status(text)
        if not conn:
            return ""
        real = await run_text(["nmcli", "-g", "802-11-wireless.ssid", "connection", "show", "id", conn], env=self.env())
        return real.strip() or conn

    async def on_start(self):
        self.current = await self.ssid()

    async def on_record(self, rec):
        if "NetworkManager is not running" in rec:
            self.set_state("waiting", "NetworkManager не запущен")
            return
        if "connect" not in rec.lower() and "primary" not in rec.lower():
            return
        if self._timer is None or self._timer.done():
            self._timer = asyncio.ensure_future(self._settle())

    async def _settle(self):
        await asyncio.sleep(self.debounce)
        ssid = await self.ssid()
        old, self.current = self.current, ssid
        if old and not ssid:
            xlog.info("wifi disconnected")
            await self.fire("wifi.disconnected", {"ssid": old})
        if ssid and ssid != old:
            xlog.info("wifi connected")                               # the network name is not written to the log
            await self.fire("wifi.connected", {"ssid": ssid})

    async def stop(self):
        if self._timer:
            self._timer.cancel()
        await super().stop()


# ------------------------------------------------------------------------------------------------------- USB
def parse_udev_block(block):
    """One `udevadm monitor --udev --property` block -> (action, subsystem, props) or None."""
    lines = [ln for ln in block.splitlines() if ln.strip()]
    if not lines or not lines[0].startswith("UDEV"):
        return None
    props = dict(ln.split("=", 1) for ln in lines[1:] if "=" in ln)
    return props.get("ACTION", ""), props.get("SUBSYSTEM", ""), props


def usb_event(props):
    """(label, device, kind) of a plugged USB storage partition / other device, or None when it is not interesting."""
    if props.get("ID_BUS", "") != "usb" and props.get("SUBSYSTEM") != "usb":
        return None
    if props.get("SUBSYSTEM") == "block":
        if props.get("DEVTYPE") not in ("partition", "disk") or not props.get("ID_FS_TYPE"):
            return None
        label = props.get("ID_FS_LABEL") or props.get("ID_MODEL", "").replace("_", " ") or "USB"
        return label, props.get("DEVNAME", ""), "storage"
    if props.get("SUBSYSTEM") == "usb" and props.get("DEVTYPE") == "usb_device":
        if props.get("ID_USB_CLASS_FROM_DATABASE") == "Hub" or props.get("ID_USB_INTERFACES", "").startswith(":090000"):
            return None
        label = (props.get("ID_MODEL_FROM_DATABASE") or props.get("ID_MODEL") or "USB").replace("_", " ")
        return label, props.get("DEVNAME", ""), "other"
    return None


class UsbSource(StreamSource):
    name = "usb"
    types = ("usb.connected",)
    tool = "udevadm"
    argv = ("udevadm", "monitor", "--udev", "--property", "--subsystem-match=block", "--subsystem-match=usb")
    sep = b"\n\n"
    missing_hint = " (пакет systemd)"

    async def on_record(self, rec):
        parsed = parse_udev_block(rec.strip("\n"))
        if not parsed or parsed[0] != "add":
            return
        ev = usb_event(parsed[2])
        if ev:
            xlog.info("usb connected", kind=ev[2])
            await self.fire("usb.connected", {"label": ev[0], "device": ev[1], "kind": ev[2]})


# ------------------------------------------------------------------------------------------- notifications
NOTIFY_MATCH = "type='method_call',interface='org.freedesktop.Notifications',member='Notify'"


def parse_notify_line(line):
    """`busctl --user monitor --json=short` line -> {app, title, body, replaces} for a Notify call, else None."""
    try:
        msg = json.loads(line)
    except ValueError:
        return None
    if not isinstance(msg, dict) or msg.get("member") != "Notify" or msg.get("type") != "method_call":
        return None
    data = (msg.get("payload") or {}).get("data") or []
    if len(data) < 5:
        return None
    return {"app": str(data[0]), "replaces": int(data[1] or 0), "title": str(data[3]), "body": str(data[4])}


class NotificationsSource(StreamSource):
    """Observes Notify calls on the session bus (BecomeMonitor: a read-only copy of the messages)."""
    name = "notifications"
    types = ("notification.received",)
    tool = "busctl"
    argv = ("busctl", "--user", "monitor", "--json=short", "--match=" + NOTIFY_MATCH)
    missing_hint = " (пакет systemd)"
    debounce = 1.0
    OWN_APPS = ("serpantinum",)                     # our own notify-send: otherwise a notification command could loop

    def __init__(self):
        super().__init__()
        self._last = ("", -1e9)

    async def on_record(self, rec):
        n = parse_notify_line(rec)
        if not n or n["replaces"] or n["app"].lower() in self.OWN_APPS:
            return
        sig, now = (n["app"], n["title"]), time.monotonic()
        if sig == self._last[0] and now - self._last[1] < self.debounce:
            return
        self._last = (sig, now)
        xlog.info("notification observed", app=n["app"][:40])        # app name only, never title or body
        await self.fire("notification.received", {"app": n["app"], "title": n["title"], "body": n["body"]})


# ----------------------------------------------------------------------------------------------- matching
def matches_b(sub, event):
    """Per-subscription filters of batch B events; None = not a batch B type."""
    from .triggers import text_filter
    t, p, d = sub.emits, sub.params, event.get("data") or {}
    if t in ("audio.headphones_connected", "audio.headphones_disconnected"):
        return str(p.get("kind_filter") or "any") in ("any", d.get("kind"))
    if t == "clipboard.link":
        return clip_matches(p, d)
    if t in ("server.unreachable", "server.recovered"):
        return text_filter(p.get("server_filter"), "%s %s" % (d.get("server"), d.get("server_name")))
    if t in ("wifi.connected", "wifi.disconnected"):
        return text_filter(p.get("ssid_filter"), d.get("ssid"))
    if t == "bluetooth.device":
        return (str(p.get("change") or "any") in ("any", "connected" if d.get("connected") else "disconnected")
                and text_filter(p.get("name_filter"), "%s %s" % (d.get("name"), d.get("mac"))))
    if t == "vpn.changed":
        return str(p.get("state_filter") or "any") in ("any", d.get("state"))
    if t in ("clipboard.color", "clipboard.phone"):
        return True
    if t == "usb.connected":
        return str(p.get("kind_filter") or "storage") in ("any", d.get("kind")) and text_filter(p.get("label_filter"), d.get("label"))
    if t == "notification.received":
        return text_filter(p.get("app_filter"), d.get("app"))
    return None


def batch_b_sources():
    from .sources_c import BluetoothSource, VpnSource
    return {"audio": AudioSource(), "clipboard": ClipboardSource(), "folder": FolderSource(), "servers": ServersSource(),
            "wifi": WifiSource(), "usb": UsbSource(), "notifications": NotificationsSource(),
            "bluetooth": BluetoothSource(), "vpn": VpnSource()}
