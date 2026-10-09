"""Debugging support of the engine (design §5, §11): bounded per-run trace ring, the step/breakpoint gate and the
rehearsal mode («Репетиция»): side-effecting nodes are replaced by simulations that only describe what WOULD happen,
time is a fake clock, dialogs are answered with a configurable fake answer and trigger events can be injected."""
import asyncio
import json
import os
import re

from . import runlog as RL
from .xlogshim import log as xlog

TRACE_VERSION = 1
KEEP_RUNS = 30
MAX_EVENTS = 3000
_RID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def tvalue(pin, value):
    """A pin value as it may appear in a trace: truncated, masked by the pin's log mode, credential-looking text hidden."""
    return RL.log_value(pin, value)


# ---------------------------------------------------------------------------------------------- trace ring
class TraceStore:
    """Last KEEP_RUNS run traces: in memory and (when a directory is given) as <dir>/<run>.json, pruned by age."""

    def __init__(self, directory=None, keep=KEEP_RUNS, max_events=MAX_EVENTS):
        self.dir, self.keep, self.max_events = directory, keep, max_events
        self.mem = {}                       # run id -> record (insertion order = age)
        if directory:
            os.makedirs(directory, exist_ok=True)

    def start(self, rid, header):
        rec = dict(header, v=TRACE_VERSION, run=rid, status="running", events=[], truncated=False)
        self.mem[rid] = rec
        return rec

    def add(self, rid, ev):
        rec = self.mem.get(rid)
        if rec is None:
            return
        if len(rec["events"]) >= self.max_events:
            rec["truncated"] = True
            return
        rec["events"].append(ev)

    def finish(self, rid, **summary):
        rec = self.mem.get(rid)
        if rec is None:
            return
        rec.update(summary)
        if self.dir:
            try:
                tmp = os.path.join(self.dir, rid + ".json.tmp")
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(rec, f, ensure_ascii=False)
                os.replace(tmp, os.path.join(self.dir, rid + ".json"))
            except OSError as e:
                xlog.warn("trace save failed", run=rid, error=str(e)[:120])
        self._prune()

    def _prune(self):
        done = [r for r, rec in self.mem.items() if rec.get("status") != "running"]
        for r in done[:max(0, len(done) - self.keep)]:
            self.mem.pop(r, None)
        if not self.dir:
            return
        try:
            files = sorted((os.path.getmtime(os.path.join(self.dir, f)), f) for f in os.listdir(self.dir) if f.endswith(".json"))
        except OSError:
            return
        for _t, f in files[:max(0, len(files) - self.keep)]:
            try:
                os.remove(os.path.join(self.dir, f))
            except OSError:
                pass

    def get(self, rid):
        if rid in self.mem:
            return self.mem[rid]
        if self.dir and _RID.match(str(rid)):
            try:
                with open(os.path.join(self.dir, rid + ".json"), encoding="utf-8") as f:
                    return json.load(f)
            except (OSError, ValueError):
                return None
        return None

    def has(self, rid):
        return rid in self.mem or bool(self.dir and _RID.match(str(rid)) and os.path.exists(os.path.join(self.dir, rid + ".json")))

    def list(self, cmd=None, n=KEEP_RUNS):
        recs = {}
        if self.dir:
            try:
                for f in os.listdir(self.dir):
                    if f.endswith(".json"):
                        r = self.get(f[:-5])
                        if r:
                            recs[r["run"]] = r
            except OSError:
                pass
        recs.update(self.mem)
        out = [{k: r.get(k) for k in ("run", "cmd", "name", "trigger", "ts", "status", "reason", "message", "dur",
                                      "dry_run", "rehearse", "failed_node", "truncated")} | {"events": len(r["events"])}
               for r in recs.values() if cmd is None or r.get("cmd") == cmd]
        out.sort(key=lambda r: (r.get("ts") or 0, r["run"]))
        return out[-n:]


# ---------------------------------------------------------------------------------------------- step / breakpoints
class Gate:
    """Pause control of one run. States: running -> paused (step mode or a breakpoint hit) -> running (step / continue)."""

    def __init__(self, step=False, breakpoints=()):
        self.step_mode = bool(step)
        self.breakpoints = set(breakpoints or ())
        self.state = "running"
        self.at = None
        self.reason = None
        self.ev = asyncio.Event()

    def hit(self, nid, depth):
        if self.step_mode:
            return "step"
        if depth == 0 and nid in self.breakpoints:
            return "breakpoint"
        return None

    def step(self):
        self.step_mode = True
        self.ev.set()

    def cont(self):
        self.step_mode = False
        self.ev.set()

    def set_breakpoints(self, nodes):
        self.breakpoints = set(nodes or ())

    def info(self):
        return {"state": self.state, "node": self.at, "reason": self.reason, "step": self.step_mode,
                "breakpoints": sorted(self.breakpoints)}


# ---------------------------------------------------------------------------------------------- rehearsal
class RehearseClock:
    """Virtual time: sleeping advances the clock instantly. Fully deterministic: now() only changes by what the graph slept."""

    def __init__(self, base):
        self.t0 = base.now()
        self.off = 0.0

    def now(self):
        return self.t0 + self.off

    async def sleep(self, seconds):
        self.off += max(0.0, float(seconds))
        await asyncio.sleep(0)


class RehearseUi:
    """Answers every dialog without showing it: `answers[node]` (or `answer`) as the user would send it, else the pin default."""

    def __init__(self, opts):
        self.opts = opts
        self.asked = []

    async def request(self, kind, payload, timeout=3.0):
        if kind != "ask":
            return {"answer": True}
        node = payload.get("node")
        ans = (self.opts.get("answers") or {}).get(node)
        if ans is None:
            ans = self.opts.get("answer")
        self.asked.append(node)
        if ans is not None:
            return ans if isinstance(ans, dict) else {"value": ans}
        mode, d, opts = payload["mode"], payload.get("default") or "", payload.get("options") or []
        if mode == "choice":
            return {"index": opts.index(d) if d in opts else 0}
        if mode == "confirm":
            return {"answer": str(d).lower() in ("1", "true", "yes", "да")}
        return {"value": d}


class Rehearsal:
    def __init__(self, opts, base_clock):
        self.opts = opts if isinstance(opts, dict) else {}
        self.clock = RehearseClock(base_clock)
        self.ui = RehearseUi(self.opts)
        self.events = [dict(e) for e in (self.opts.get("events") or []) if isinstance(e, dict) and e.get("type")]

    def take_event(self, etype, match):
        from .triggers import text_filter
        for i, e in enumerate(self.events):
            data = e.get("data") or {}
            if e["type"] == etype and text_filter(match, " ".join(str(v) for v in data.values())):
                return self.events.pop(i)
        return None


def _clip(s, n=120):
    s = RL.redact_text(str(s))
    return s if len(s) <= n else s[:n - 1] + "…"


def plan(ctx, nd, node, inputs):
    """What a side-effecting node would do (Russian text, never clipboard content) and how it would be undone."""
    ex = nd.executor
    ref = ex.get("ref")
    label = nd.label("ru")
    if ex.get("kind") == "ipc":
        args = ", ".join(_clip(inputs[p.id], 40) for p in nd.inputs if p.type != "exec" and p.id in inputs)
        text = "вызвал бы %s.%s(%s)" % (ex.get("target"), ex.get("fn"), args)
    elif ref == "notify":
        text = "показал бы уведомление «%s»%s" % (_clip(inputs.get("title"), 60), (": " + _clip(inputs["body"], 80)) if inputs.get("body") else "")
    elif ref == "shell":
        text = "выполнил бы команду: %s" % _clip(inputs.get("command"))
    elif ref == "clipboard_set":
        text = "записал бы в буфер обмена %d симв." % len(str(inputs.get("text") or ""))
    elif ref == "show_result":
        text = "показал бы окно с результатом: %s" % _clip(inputs.get("value"), 80)
    else:
        text = "выполнил бы узел «%s»" % label
    out = {"plan": text}
    if nd.undo:
        mode = ((node.get("props") or {}).get("restore")) or nd.undo.get("default", "off")
        if mode == "end":
            out["would_undo"] = "вернул бы прежнее значение, когда запуск закончится"
        elif mode == "off_event":
            out["would_undo"] = "вернул бы прежнее значение, когда придёт обратное событие"
    return out
