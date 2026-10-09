"""Event sources of the trigger framework (design §6). Every source turns something that happens on this machine into
normalized events `{type, ts, data[, key]}` and calls `emit(event)`. Sources start lazily (only when an enabled,
approved command listens to one of their types) and a source that dies is marked failed without touching the rest.

Batch A, local only: time (schedule/interval/sunrise/sunset), hyprland (windows, workspaces, monitors), logind
(lock/unlock/sleep), login (once per session) and the passive `idle` source fed by the shell bridge."""
import asyncio
import glob
import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone

from . import paths
from .procs import session_env
from .solar import next_sun_event

log = logging.getLogger("xcmd.sources")

WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_SETS = {"daily": set(range(7)), "weekdays": set(range(5)), "weekends": {5, 6}}
GRACE_S = 90.0                 # a schedule fired later than this after its time counts as «missed» (suspend)
MAX_NAP_S = 30.0               # never sleep longer: wake-ups after suspend are noticed within this time


def days_of(token):
    if token in DAY_SETS:
        return DAY_SETS[token]
    if token in WEEKDAYS:
        return {WEEKDAYS.index(token)}
    return set(range(7))


def next_time_at(now_ts, hhmm, days_token, tz=None):
    """Unix time of the next HH:MM (local time of `tz`) on the given days, strictly after now_ts."""
    hh, mm = int(hhmm[0:2]), int(hhmm[3:5])
    ss = int(hhmm[6:8]) if len(hhmm) >= 8 else 0
    days = days_of(days_token)
    now = datetime.fromtimestamp(now_ts, tz)
    for delta in range(0, 9):
        day = (now + timedelta(days=delta)).date()
        if day.weekday() not in days:
            continue
        cand = datetime(day.year, day.month, day.day, hh, mm, ss, tzinfo=tz) if tz else datetime(day.year, day.month, day.day, hh, mm, ss)
        ts = cand.timestamp()                       # a time that does not exist (DST gap) lands one hour later
        if ts > now_ts:
            return ts
    return None


class Sub:
    """One event node of one command that listens to a source."""

    def __init__(self, key, cmd_id, nid, emits, src, params):
        self.key, self.cmd_id, self.nid, self.emits, self.src, self.params = key, cmd_id, nid, emits, src, params

    def sig(self):
        return json.dumps([self.emits, self.params], sort_keys=True, default=str)


class Source:
    name = "?"
    types = ()

    def __init__(self):
        self.state = "idle"             # idle | running | failed
        self.error = ""
        self.subs = {}
        self.emit = None
        self.task = None
        self.count = 0

    def configure(self, subs):
        self.subs = {s.key: s for s in subs}

    async def start(self, emit):
        self.emit = emit
        self.state, self.error = "running", ""
        self.task = asyncio.ensure_future(self._guard())

    async def _guard(self):
        try:
            await self.run()
        except asyncio.CancelledError:
            raise
        except Exception as e:                          # a dead source disables only its own triggers
            self.state, self.error = "failed", "%s: %s" % (type(e).__name__, e)
            log.error("source %s failed: %s", self.name, self.error)

    async def run(self):
        return None

    async def stop(self):
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            self.task = None
        self.state = "idle"

    async def fire(self, etype, data, key=None, ts=None):
        self.count += 1
        ev = {"type": etype, "data": data, "src": self.name}
        if key:
            ev["key"] = key
        await self.emit(ev)

    def set_state(self, state, error=""):
        if (state, error) != (self.state, self.error):
            (log.warning if state in ("waiting", "failed") else log.info)("source %s: %s%s", self.name, state,
                                                                          (" — " + error) if error else "")
        self.state, self.error = state, error

    def info(self):
        return {"name": self.name, "state": self.state, "error": self.error, "subs": len(self.subs), "events": self.count}


# ------------------------------------------------------------------------------------------------------- time
def settings_location():
    """(lat, lon) from the shell's settings.json (general.location) or None."""
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    p = os.environ.get("XCMD_SETTINGS") or os.path.join(base, "serpantinum", "settings.json")
    try:
        loc = ((json.load(open(p, encoding="utf-8")) or {}).get("general") or {}).get("location") or {}
        lat, lon = float(loc["latitude"]), float(loc["longitude"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return None if (lat == 0.0 and lon == 0.0) else (lat, lon)


class TimeSource(Source):
    name = "time"
    types = ("time.at", "time.every", "sun")

    def __init__(self, clock, tz=None, location=settings_location):
        super().__init__()
        self.clock, self.tz, self.location = clock, tz, location
        self.next = {}                  # key -> next fire time (unix) or None
        self.sigs = {}
        self.errors = {}                # key -> text (sun without coordinates)
        self._last = None

    def configure(self, subs):
        keep = {}
        for s in subs:
            if self.sigs.get(s.key) == s.sig() and s.key in self.next:
                keep[s.key] = self.next[s.key]
        self.subs = {s.key: s for s in subs}
        self.sigs = {s.key: s.sig() for s in subs}
        self.next = {}
        for s in subs:
            self.next[s.key] = keep[s.key] if s.key in keep else self._compute(s, self.clock.now())

    def _compute(self, s, now):
        p = s.params
        self.errors.pop(s.key, None)
        if s.emits == "time.at":
            return next_time_at(now, str(p.get("at") or "00:00"), str(p.get("days") or "daily"), self.tz)
        if s.emits == "time.every":
            return now + max(1, int(p.get("minutes") or 1)) * 60.0
        if s.emits == "sun":
            loc = self.location()
            if not loc:
                self.errors[s.key] = "Не заданы координаты места: укажите город в настройках оболочки"
                return None
            nxt = next_sun_event(now, str(p.get("kind") or "sunset"), int(p.get("offset") or 0), loc[0], loc[1])
            if nxt is None:
                self.errors[s.key] = "В вашей широте сейчас нет такого события"
            return nxt
        return None

    async def tick(self):
        """One scheduling step: fire everything that is due. Returns the number of events fired."""
        now = self.clock.now()
        gap = 0.0 if self._last is None else now - self._last
        self._last = now
        fired = 0
        for key, s in list(self.subs.items()):
            due = self.next.get(key)
            if due is None and s.emits == "sun" and key in self.errors:
                self.next[key] = due = self._compute(s, now)         # coordinates may have appeared
            if due is None or due > now:
                continue
            late = now - due
            missed = late > GRACE_S or gap > GRACE_S * 2
            policy = str(s.params.get("missed") or "skip")
            if not missed or (policy == "run_once" and s.emits == "time.at"):
                data = self._data(s, now)
                if missed:
                    data["missed"] = True
                await self.fire(s.emits, data, key=key)
                fired += 1
            self.next[key] = self._compute(s, max(now, due))
        return fired

    def _data(self, s, now):
        dt = datetime.fromtimestamp(now, self.tz)
        d = {"time": dt.strftime("%H:%M")}
        if s.emits == "time.at":
            d["weekday"] = WEEKDAYS[dt.weekday()]
        return d

    def sleep_for(self):
        now = self.clock.now()
        nxt = [t - now for t in self.next.values() if t is not None]
        return max(0.05, min([MAX_NAP_S] + [max(0.05, x) for x in nxt]))

    async def run(self):
        self._last = self.clock.now()
        while True:
            await self.tick()
            await self.clock.sleep(self.sleep_for())

    def info(self):
        d = super().info()
        d["errors"] = dict(self.errors)
        return d


# ----------------------------------------------------------------------------------------------------- hyprland
def hypr_socket_path(env=None):
    env = session_env(env)
    sig = env.get("HYPRLAND_INSTANCE_SIGNATURE")
    rt = env.get("XDG_RUNTIME_DIR") or paths.runtime_dir()
    if not sig:
        return None
    p = os.path.join(rt, "hypr", sig, ".socket2.sock")
    return p if os.path.exists(p) else None


def parse_hypr_line(line, windows):
    """Hyprland socket2 line -> list of normalized (type, data); `windows` (address -> info) is updated in place."""
    if ">>" not in line:
        return []
    name, _, payload = line.rstrip("\n").partition(">>")
    out = []
    if name == "openwindow":
        parts = payload.split(",", 3)
        if len(parts) == 4:
            addr, ws, cls, title = parts
            windows[addr] = {"class": cls, "title": title, "workspace": ws}
            out.append(("window.open", {"address": addr, "class": cls, "title": title, "workspace": ws}))
    elif name == "closewindow":
        info = windows.pop(payload.strip(), None)
        if info is not None:
            out.append(("window.close", {"address": payload.strip(), "class": info["class"], "title": info["title"]}))
        else:
            out.append(("window.close", {"address": payload.strip(), "class": "", "title": ""}))
    elif name == "windowtitlev2":
        parts = payload.split(",", 1)
        if len(parts) == 2 and parts[0] in windows:
            windows[parts[0]]["title"] = parts[1]
    elif name == "workspacev2":
        parts = payload.split(",", 1)
        if len(parts) == 2:
            out.append(("workspace", {"id": parts[0], "workspace": parts[1]}))
    elif name == "monitoraddedv2":
        parts = payload.split(",", 2)
        if len(parts) >= 2:
            out.append(("monitor.added", {"id": parts[0], "monitor": parts[1], "description": parts[2] if len(parts) > 2 else ""}))
    elif name == "monitorremoved":
        out.append(("monitor.removed", {"monitor": payload.strip()}))
    return out


class HyprlandSource(Source):
    name = "hyprland"
    types = ("window.open", "window.close", "workspace", "monitor.added", "monitor.removed")

    def __init__(self, opener=None, env_fn=session_env, snapshot=None, retry=(1, 2, 4, 8, 15, 30)):
        super().__init__()
        self.opener = opener or self._open_real
        self.env_fn = env_fn
        self.snapshot = snapshot or self._clients_real
        self.retry = retry
        self.windows = {}

    async def _open_real(self):
        path = hypr_socket_path(self.env_fn())
        if not path:
            raise ConnectionError("сокет Hyprland не найден (сеанс ещё не запущен?)")
        reader, _ = await asyncio.open_unix_connection(path)
        return reader

    async def _clients_real(self):
        try:
            p = await asyncio.create_subprocess_exec("hyprctl", "-j", "clients", stdout=asyncio.subprocess.PIPE,
                                                     stderr=asyncio.subprocess.DEVNULL, env=self.env_fn())
            out, _ = await asyncio.wait_for(p.communicate(), 5)
            return {c["address"].replace("0x", ""): {"class": c.get("class", ""), "title": c.get("title", ""),
                                                      "workspace": (c.get("workspace") or {}).get("name", "")}
                    for c in json.loads(out or b"[]")}
        except Exception:
            return {}

    async def run(self):
        attempt = 0
        while True:
            try:
                reader = await self.opener()
            except (OSError, ConnectionError) as e:
                self.set_state("waiting", str(e))
                await asyncio.sleep(self.retry[min(attempt, len(self.retry) - 1)])
                attempt += 1
                continue
            attempt = 0
            self.set_state("running")
            self.windows = dict(await self.snapshot() or {})
            while True:
                raw = await reader.readline()
                if not raw:
                    break
                for etype, data in parse_hypr_line(raw.decode("utf-8", "replace"), self.windows):
                    await self.fire(etype, data)
            self.set_state("waiting", "соединение с Hyprland потеряно, переподключаюсь")
            await asyncio.sleep(self.retry[0])


# ------------------------------------------------------------------------------------------------------ logind
def parse_logind_line(line):
    """One `busctl --system monitor --json=short` line -> list of (type, data)."""
    try:
        msg = json.loads(line)
    except ValueError:
        return []
    if not isinstance(msg, dict) or msg.get("type") != "signal":
        return []
    member = msg.get("member")
    if member == "Lock":
        return [("session.lock", {})]
    if member == "Unlock":
        return [("session.unlock", {})]
    if member == "PrepareForSleep":
        data = (msg.get("payload") or {}).get("data") or [False]
        return [("session.sleep" if data and data[0] else "session.resume", {})]
    return []


class LogindSource(Source):
    name = "logind"
    types = ("session.lock", "session.unlock")

    def __init__(self, spawn=None):
        super().__init__()
        self.spawn = spawn or self._spawn_real

    async def _spawn_real(self):
        p = await asyncio.create_subprocess_exec("busctl", "--system", "monitor", "org.freedesktop.login1", "--json=short",
                                                 stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        return p.stdout, p

    async def run(self):
        reader, proc = await self.spawn()
        try:
            while True:
                raw = await reader.readline()
                if not raw:
                    raise ConnectionError("busctl monitor завершился")
                for etype, data in parse_logind_line(raw.decode("utf-8", "replace")):
                    await self.fire(etype, data)
        finally:
            if proc is not None and getattr(proc, "returncode", 1) is None:
                proc.terminate()


# ------------------------------------------------------------------------------------- login and passive sources
class LoginSource(Source):
    """`session.login` once per graphical session: the marker file keeps a daemon restart from firing it again."""
    name = "login"
    types = ("session.login",)

    def __init__(self, env_fn=session_env, marker=None, wait=(1, 2, 3, 5, 10, 20, 30)):
        super().__init__()
        self.env_fn, self.wait = env_fn, wait
        self.marker = marker or os.path.join(paths.runtime_dir(), "serpantinum", "cmdd.login")

    async def run(self):
        for i in range(10 ** 6):
            sig = self.env_fn().get("HYPRLAND_INSTANCE_SIGNATURE")
            if sig:
                break
            self.state, self.error = "waiting", "жду запуска графического сеанса"
            await asyncio.sleep(self.wait[min(i, len(self.wait) - 1)])
        self.state, self.error = "running", ""
        try:
            with open(self.marker, encoding="utf-8") as f:
                seen = f.read().strip()
        except OSError:
            seen = ""
        if seen != sig:
            os.makedirs(os.path.dirname(self.marker), mode=0o700, exist_ok=True)
            with open(self.marker, "w", encoding="utf-8") as f:
                f.write(sig)
            await self.fire("session.login", {})


class ExternalSource(Source):
    """Passive: events arrive through the daemon's `emit` method (the shell's idle bridge). The daemon publishes the
    list of requested idle durations for the bridge in a small file."""
    name = "idle"
    types = ("idle.start", "idle.stop")

    def __init__(self, request_file=None):
        super().__init__()
        self.request_file = request_file or os.path.join(paths.runtime_dir(), "serpantinum", "cmd-idle.json")

    def configure(self, subs):
        super().configure(subs)
        minutes = sorted({int(s.params.get("minutes") or 0) for s in subs if s.params.get("minutes")})
        try:
            os.makedirs(os.path.dirname(self.request_file), mode=0o700, exist_ok=True)
            tmp = self.request_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"minutes": minutes}, f)
            os.replace(tmp, self.request_file)
        except OSError as e:
            self.error = str(e)

    async def start(self, emit):
        self.emit = emit
        self.state = "running"

    async def stop(self):
        self.state = "idle"
        try:
            os.remove(self.request_file)
        except OSError:
            pass


def default_sources(clock):
    from .sources_b import batch_b_sources
    src = {"time": TimeSource(clock), "hyprland": HyprlandSource(), "logind": LogindSource(),
           "login": LoginSource(), "idle": ExternalSource()}
    src.update(batch_b_sources())
    return src
