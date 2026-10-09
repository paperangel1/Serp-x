"""Nodes that wait for the outside world: «Спросить меня» (ui.request -> ui_response) and «Ждать событие» (a normalized
event from the trigger sources or `cmd emit`). Both are cancellable (the run task is cancelled) and always have a way out:
a cancel pin and/or a timeout pin. Logged through xlog: lifecycle only, never the answer text."""
import asyncio
import re

from .errors import NodeError
from .xlogshim import log as xlog

MAX_TEXT = 4096


class Waiters:
    """Runs suspended on an event. The trigger manager feeds `deliver`, and asks `types()` which sources it must keep running."""

    def __init__(self):
        self.items = []
        self.on_change = None

    def types(self):
        return {w["type"] for w in self.items}

    def deliver(self, event):
        from .triggers import text_filter
        hit = 0
        data = event.get("data") or {}
        text = " ".join(str(v) for v in data.values())
        for w in list(self.items):
            if w["type"] == event.get("type") and not w["fut"].done() and text_filter(w["match"], text):
                w["fut"].set_result({"type": event["type"], "data": data})
                hit += 1
        return hit

    def add(self, etype, match):
        w = {"type": etype, "match": match, "fut": asyncio.get_event_loop().create_future()}
        self.items.append(w)
        if self.on_change:
            self.on_change()
        return w

    def remove(self, w):
        if w in self.items:
            self.items.remove(w)
            if self.on_change:
                self.on_change()


def event_detail(ev):
    return ", ".join("%s=%s" % (k, v) for k, v in (ev.get("data") or {}).items())[:500]


async def wait_event(engine, ctx, nid, inputs, step):
    etype, match, timeout = inputs["event"], inputs.get("match") or "", float(inputs["timeout"])
    if ctx.rehearse is not None:
        ev = ctx.rehearse.take_event(etype, match)
        step["dry_run"] = True
        if ev is not None:
            step["simulated"] = "событие «%s» подставлено репетицией" % etype
            return {"detail": event_detail(ev)}, "exec_out"
        await ctx.clock.sleep(timeout)
        step.update(note="время ожидания вышло (в репетиции время ускорено)", fast_forward=timeout)
        return {"detail": ""}, "timed_out"
    if ctx.dry_run:
        step["dry_run"] = True
        return {"detail": ""}, "exec_out"
    w = engine.waiters.add(etype, match)
    xlog.info("wait_event start", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, event=etype, timeout=timeout)
    try:
        ev = await asyncio.wait_for(asyncio.shield(w["fut"]), timeout)
    except asyncio.TimeoutError:
        xlog.info("wait_event timeout", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, event=etype)
        step["note"] = "время ожидания вышло"
        return {"detail": ""}, "timed_out"
    finally:
        engine.waiters.remove(w)
    xlog.info("wait_event matched", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, event=etype)
    return {"detail": event_detail(ev)}, "exec_out"


def _num(raw):
    try:
        return float(str(raw).replace(",", ".").strip())
    except ValueError:
        return None


def ask_defaults(inputs):
    mode, d = inputs["mode"], inputs.get("default") or ""
    opts = list(inputs.get("options") or [])
    idx = opts.index(d) if mode == "choice" and d in opts else (0 if mode == "choice" and opts else -1)
    n = _num(d)
    return {"text": opts[idx] if idx >= 0 else d, "number": n if n is not None else 0.0, "index": idx,
            "yes": str(d).lower() in ("1", "true", "yes", "да")}


async def ask(engine, ctx, nid, inputs, step):
    mode = inputs["mode"]
    opts = [str(o) for o in (inputs.get("options") or [])]
    if mode == "choice" and not opts:
        raise NodeError("Для вопроса с выбором нужен список вариантов (он пуст)")
    if ctx.dry_run and ctx.rehearse is None:
        step["dry_run"] = True
        return ask_defaults(inputs), "exec_out"
    if ctx.rehearse is not None:
        step.update(dry_run=True, simulated="ответ подставлен репетицией")
    timeout = float(inputs["timeout"])
    payload = {"mode": mode, "title": str(inputs.get("title") or ""), "options": opts,
               "default": str(inputs.get("default") or ""), "timeout": timeout, "command": ctx.cmd.get("name", ""),
               "run": ctx.rid, "node": nid}
    xlog.info("ask open", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, mode=mode, options=len(opts), timeout=timeout)
    ans = await ctx.ui.request("ask", payload, timeout=timeout)
    base = ask_defaults({"mode": mode, "options": [], "default": ""})
    if ans is None:
        xlog.info("ask timeout", cmd=ctx.cmd["id"], run=ctx.rid, node=nid)
        step["note"] = "ответа нет (время вышло или оболочка не подключена)"
        return base, "timed_out"
    if ans.get("cancel"):
        xlog.info("ask cancelled", cmd=ctx.cmd["id"], run=ctx.rid, node=nid)
        return base, "cancelled"
    out = dict(base)
    if mode == "choice":
        idx = ans.get("index")
        if not isinstance(idx, int) or isinstance(idx, bool) or not 0 <= idx < len(opts):
            val = ans.get("value")
            if val in opts:
                idx = opts.index(val)
            else:
                raise NodeError("Из окна пришёл неизвестный вариант ответа")
        out.update(index=idx, text=opts[idx])
    elif mode == "text":
        out["text"] = str(ans.get("value", ""))[:MAX_TEXT]
    elif mode == "number":
        raw = ans.get("value")
        n = raw if isinstance(raw, (int, float)) and not isinstance(raw, bool) else _num(raw)
        if n is None:
            raise NodeError("Ответ «%s» не похож на число" % str(raw)[:40])
        out.update(number=float(n), text=re.sub(r"\.0$", "", str(n)))
    else:
        out["yes"] = bool(ans.get("answer", ans.get("value")))
        out["text"] = "да" if out["yes"] else "нет"
    xlog.info("ask answered", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, mode=mode)
    return out, "exec_out"
