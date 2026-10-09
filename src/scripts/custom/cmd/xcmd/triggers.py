"""Trigger manager (design §6): turns normalized events into runs of the automations that listen to them.

* Subscriptions come from ENABLED, approved, valid commands that contain an event node other than «Вручную».
* A source starts only while somebody listens to one of its types and stops when the last listener goes away.
* Every event is published on the `event` topic (cmd events), deduplicated, filtered per node and started through
  Engine.run — so the loop guard, global/command pause and the run log apply exactly as for every other run."""
import asyncio
import json
import logging
import re

from .model import approved_ok
from .sources import Sub, default_sources
from .sources_b import SENSITIVE, matches_b, public_event
from .validate import Graph, validate

log = logging.getLogger("xcmd.triggers")

DEDUP_S = {"window.open": 0.3, "window.close": 0.3, "workspace": 0.3, "monitor.added": 1.0, "monitor.removed": 1.0,
           "session.lock": 1.0, "session.unlock": 1.0}


def text_filter(pattern, value):
    """Empty matches everything; «re:» prefix = regular expression; otherwise a case-insensitive substring."""
    pattern = str(pattern or "")
    value = str(value or "")
    if not pattern:
        return True
    if pattern.startswith("re:"):
        try:
            return re.search(pattern[3:], value, re.I) is not None
        except re.error:
            return False
    return pattern.lower() in value.lower()


def matches(sub, event):
    """May this event start this subscription? Targeted events (time sources) carry the subscription key."""
    if event.get("key"):
        return event["key"] == sub.key
    p, d = sub.params, event.get("data") or {}
    t = sub.emits
    hit = matches_b(sub, event)
    if hit is not None:
        return hit
    if t in ("window.open", "window.close"):
        return text_filter(p.get("class_filter"), d.get("class")) and text_filter(p.get("title_filter"), d.get("title"))
    if t == "workspace":
        return not p.get("workspace_filter") or str(p.get("workspace_filter")) in (str(d.get("workspace")), str(d.get("id")))
    if t in ("monitor.added", "monitor.removed"):
        return text_filter(p.get("monitor_filter"), d.get("monitor"))
    if t in ("idle.start", "idle.stop"):
        return int(p.get("minutes") or 0) == int(d.get("minutes") or -1)
    return True


class TriggerManager:
    def __init__(self, engine, clock=None, sources=None, refresh_delay=0.2):
        self.engine = engine
        self.clock = clock or engine.clock
        self.sources = sources if sources is not None else default_sources(self.clock)
        self.refresh_delay = refresh_delay
        self.subs = []
        self.active = set()
        self.running = False
        self._seen = {}
        self._refresh_task = None
        self.recent = []                      # last normalized events (status/debug)
        engine.waiters.on_change = self.dirty  # a run started/stopped waiting for an event: keep its source running

    # ------------------------------------------------------------------ subscriptions
    def collect(self):
        subs, sch = [], self.engine.sch
        for cmd in self.engine.store.all():
            if cmd.get("enabled", True) is False or cmd.get("imported"):
                continue
            graph = Graph(cmd, sch)
            events = [(nid, nd) for nid, nd in graph.defs.items() if nd.flow == "event" and nd.id != "event.manual"
                      and (nd.source or {}).get("src")]
            if not events:
                continue
            report = validate(cmd, sch)
            if not report["ok"] or approved_ok(cmd, report["capabilities"]):
                continue
            for nid, nd in events:
                props = graph.nodes[nid].get("props") or {}
                params = {p.id: props.get(p.id, p.default) for p in nd.inputs if p.type != "exec"}
                subs.append(Sub("%s:%s" % (cmd["id"], nid), cmd["id"], nid, nd.source["emits"], nd.source["src"], params))
        for etype in sorted(self.engine.waiters.types()):          # «Ждать событие»: sources run only while someone waits
            src = next((n for n, s in self.sources.items() if etype in s.types), None)
            if src:
                subs.append(Sub("wait:%s" % etype, None, None, etype, src, {}))
        return subs

    async def start(self):
        self.running = True
        await self.refresh()

    async def stop(self):
        self.running = False
        if self._refresh_task:
            self._refresh_task.cancel()
        for name in list(self.active):
            await self.sources[name].stop()
        self.active.clear()

    def dirty(self):
        """Commands changed: refresh soon (debounced)."""
        if not self.running:
            return
        if self._refresh_task and not self._refresh_task.done():
            return

        async def later():
            await asyncio.sleep(self.refresh_delay)
            await self.refresh()
        self._refresh_task = asyncio.ensure_future(later())

    async def refresh(self):
        before = len(self.subs)
        self.subs = self.collect()
        if len(self.subs) != before:
            log.info("subscriptions: %d -> %d", before, len(self.subs))
        by_src = {}
        for s in self.subs:
            by_src.setdefault(s.src, []).append(s)
        for name, subs in by_src.items():
            src = self.sources.get(name)
            if src is None:
                continue
            src.configure(subs)
            if name not in self.active:
                self.active.add(name)
                log.info("start source %s (%d subscription%s)", name, len(subs), "" if len(subs) == 1 else "s")
                await src.start(self.on_event)
        for name in list(self.active):
            if name not in by_src:
                self.active.discard(name)
                log.info("stop source %s (no listeners)", name)
                self.sources[name].configure([])
                await self.sources[name].stop()

    # ------------------------------------------------------------------ events
    async def on_event(self, event):
        """Entry of every source (and of `emit`): normalize, publish, deduplicate, start matching runs."""
        event = dict(event)
        event.setdefault("ts", self.clock.now())
        event.setdefault("data", {})
        shown = public_event(event)                  # clipboard / notification text never reaches `cmd events` or status
        self.recent = (self.recent + [{k: shown[k] for k in ("type", "ts", "data")}])[-20:]
        self.engine.events.publish("event", {"ev": "event", **{k: v for k, v in shown.items() if k != "key"}})
        if not event.get("key") and event["type"] not in SENSITIVE:
            self.engine.deliver_event(event)
        window = DEDUP_S.get(event["type"], 0.0)
        if window and not event.get("key"):
            sig = (event["type"], json.dumps(event["data"], sort_keys=True, default=str))
            last = self._seen.get(sig)
            self._seen[sig] = event["ts"]
            if len(self._seen) > 500:
                self._seen = {k: v for k, v in self._seen.items() if event["ts"] - v < 5}
            if last is not None and event["ts"] - last < window:
                return []
        return self.dispatch(event)

    def dispatch(self, event, dry_run=False):
        tasks = []
        for sub in self.subs:
            if sub.cmd_id is None or sub.emits != event["type"] or not matches(sub, event):
                continue
            log.info("event %s -> command %s (node %s)%s", event["type"], sub.cmd_id, sub.nid, " [dry run]" if dry_run else "")
            tasks.append(asyncio.ensure_future(self.engine.run(
                sub.cmd_id, trigger=event["type"], event={"type": event["type"], "ts": event["ts"], "data": event["data"]},
                start_node=sub.nid, dry_run=dry_run)))
        return tasks

    # ------------------------------------------------------------------ status
    def status(self):
        return {"running": self.running,
                "sources": {n: self.sources[n].info() for n in sorted(self.sources)},
                "active": sorted(self.active),
                "subscriptions": [{"command": s.cmd_id, "node": s.nid, "event": s.emits, "source": s.src, "params": s.params}
                                  for s in self.subs],
                "recent": self.recent[-5:]}
