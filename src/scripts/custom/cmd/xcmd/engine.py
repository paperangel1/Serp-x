"""The execution engine (design §5): exec wires drive the order, data pins are evaluated lazily, state-changing nodes
register an undo entry that is rolled back when the run ends, is cancelled or fails."""
import asyncio
import collections
import copy

from . import debug as D, executors, interact, pure, ptypes as T, runlog as RL
from .bridge import NullUiBridge, Subscribers
from .clock import RealClock
from .errors import BreakLoop, EngineError, NodeError
from .guard import Guard
from .model import CommandError, approved_ok, policy_of
from .procs import ProcessRunner
from .schema import FN_IN_ID, FN_OUT_ID, MAX_FN_DEPTH
from .validate import Graph, validate
from .xlogshim import log as xlog

BUILTIN_HANDLERS = ("event", "if", "foreach", "delay", "set_var", "get_var", "to_text", "to_int", "break", "increment",
                    "ask", "wait_event", "timer", "fn_input", "fn_output") + tuple(pure.FUNCS)
MAX_STEPS = 10000
PIN_HISTORY = 50
PIN_HISTORY_TTL = 600


def _human_secs(s):
    s = int(round(s))
    if s >= 3600 and s % 60 == 0:
        return "%d ч %02d мин" % (s // 3600, s % 3600 // 60)
    return ("%d мин %02d с" % (s // 60, s % 60)) if s >= 60 else "%d с" % s


class RunCtx:
    def __init__(self, engine, cmd, graph, rid, trigger, start, event_data, dry_run, auto_confirm, sch=None, rehearse=None,
                 gate=None):
        self.engine, self.cmd, self.graph, self.rid = engine, cmd, graph, rid
        self.rehearse, self.gate = rehearse, gate         # Rehearsal / debug Gate or None
        self.loops = []                   # indices of the for-each iterations we are inside (innermost last)
        self.trace_seq = 0
        self.sch = sch or engine.sch
        self.root = self                  # the run's top scope; a function call gets a child scope (see child())
        self.path, self.depth, self.scope_id = [], 0, ""
        self.scope_seq = 0
        self.private = set()              # text of log=length/mask pins seen in this run: hidden everywhere in the run log
        self.scopes = {}                  # scope id -> Graph, for scopes that left undo entries
        self.fn_result = None
        self.trigger, self.start, self.event_data = trigger, start, event_data
        self.dry_run, self.auto_confirm = dry_run, auto_confirm
        self.t0 = self.clock.now()
        self.vars = {}
        self.outputs = {}
        self.epoch = 0
        self.memo = {}
        self.undo = []
        self.bg = []                      # running «Таймер» countdowns (the run lives until they finish)
        self.bg_all = []
        self.steps = []
        self.step_count = 0
        self.failed_node = None
        self.fail_path = None
        self.pin_hist = collections.defaultdict(lambda: collections.deque(maxlen=PIN_HISTORY))

    def child(self, graph, name, values, scope_id):
        """Isolated scope of a function call: own graph, variables, outputs and memo; the run's step log, undo stack,
        counters, cancel/timeout (same task) and pin history are shared with the caller."""
        c = copy.copy(self)
        c.graph, c.vars, c.outputs, c.memo, c.epoch = graph, {}, {}, {}, 0
        c.event_data, c.path, c.depth, c.scope_id, c.fn_result = values, self.path + [name], self.depth + 1, scope_id, None
        return c

    def mark_failed(self, nid):
        if self.depth == 0:
            self.root.failed_node = self.root.failed_node or nid

    @property
    def where(self):
        return " → ".join("«%s»" % p for p in self.path)

    # --- what executors see
    @property
    def proc(self):
        return self.engine.proc

    @property
    def ui(self):
        return self.rehearse.ui if self.rehearse else self.engine.ui

    @property
    def clock(self):
        return self.rehearse.clock if self.rehearse else self.engine.clock


class Engine:
    def __init__(self, sch, store, state, run_log, undo_store, clock=None, proc=None, ui=None, max_parallel=8,
                 max_steps=MAX_STEPS, traces=None):
        self.sch, self.store, self.state, self.runlog, self.undo_store = sch, store, state, run_log, undo_store
        self.clock = clock or RealClock()
        self.proc = proc or ProcessRunner()
        self.ui = ui or NullUiBridge()
        self.events = Subscribers()          # topics: trace, run
        self.guard = Guard(self.clock, state, self._notify)
        self.active = {}
        self.sem = asyncio.Semaphore(max_parallel)
        self.locks = {}
        self.pin_history = {}
        self.waiters = interact.Waiters()   # runs suspended on «Ждать событие»
        self.max_steps = max_steps
        self._seq = 0
        self.traces = traces or D.TraceStore()

    # ------------------------------------------------------------------ public API
    async def run(self, ref, *, trigger="manual", event=None, args=None, dry_run=False, auto_confirm=False,
                  start_node=None, rehearse=None, step=False, breakpoints=None, debug=False):
        """rehearse: None or an options dict ({answer, answers, events}) -> side effects are only described, time is virtual;
        step / breakpoints / debug: the run gets a pause gate (debug_* protocol methods)."""
        try:
            cmd = ref if isinstance(ref, dict) else self.store.find(ref)
        except CommandError as e:
            return {"status": "error", "reason": e.code, "message": e.message, "steps": []}
        if "id" not in cmd:
            cmd = dict(cmd, id="adhoc")
        self._seq += 1
        rid = "%d-%d" % (int(self.clock.now()), self._seq)
        rehearse = {} if rehearse is True else rehearse
        if rehearse is not None:
            dry_run = True
        base = {"run": rid, "cmd": cmd.get("id"), "name": cmd.get("name"), "trigger": trigger, "ts": self.clock.now(),
                "dry_run": bool(dry_run)}
        if rehearse is not None:
            base["rehearse"] = True
        if event:
            from .sources_b import public_event
            shown = public_event(event)                  # clipboard / notification text is never written to the run log
            base["event"] = {"type": event.get("type"), "data": {k: str(v)[:80] for k, v in (shown.get("data") or {}).items()}}
        sch = self.sch.with_functions(cmd.get("functions"))
        report = validate(cmd, sch)
        if not report["ok"]:
            return self._early(base, "invalid", "validation", "Команда не прошла проверку: %s" % report["errors"][0]["message"],
                               errors=report["errors"])
        missing = approved_ok(cmd, report["capabilities"])
        if missing and not dry_run:
            return self._early(base, "denied", "capabilities",
                               "Команда использует неподтверждённые права: %s. Подтвердите их: serpantinum-x cmd approve «%s»"
                               % (", ".join(missing), cmd["name"]), missing=missing)
        pol = policy_of(cmd)
        if trigger != "manual" and rehearse is None:
            if cmd.get("enabled", True) is False:
                return self._early(base, "skipped", "disabled", "Автоматизация выключена")
            if self.state.paused_all:
                return self._early(base, "skipped", "paused_all", "Пропущено: пауза всех автоматизаций")
            if self.state.is_paused(cmd["id"]):
                return self._early(base, "skipped", "paused_cmd", "Пропущено: команда на паузе")
            if not await self.guard.allow(cmd["id"], pol["max_runs_per_min"], cmd["name"]):
                return self._early(base, "skipped", "loop_guard", "Команда приостановлена: слишком частые запуски")
        graph = Graph(cmd, sch)
        start = start_node or next((n for n, d in graph.defs.items() if d.id == "event.manual"), None)
        if start is None or start not in graph.defs:
            return self._early(base, "invalid", "no_start", "В команде нет события для запуска")
        if rehearse is None:                       # a rehearsal never blocks or is blocked by the real runs
            gate = await self._reentrancy(cmd, pol, base)
            if gate is not None:
                return gate
        data = dict(event.get("data", {})) if event else {}
        if trigger == "manual":
            data["arg"] = args or ""
        rh = D.Rehearsal(rehearse, self.clock) if rehearse is not None else None
        gate = D.Gate(step, breakpoints) if (step or breakpoints or debug) else None
        ctx = RunCtx(self, cmd, graph, rid, trigger, start, data, dry_run, auto_confirm, sch, rehearse=rh, gate=gate)
        task = asyncio.ensure_future(self._execute(ctx, base, pol))
        self.active[rid] = {"task": task, "cmd": cmd["id"], "name": cmd["name"], "trigger": trigger, "ts": base["ts"],
                            "gate": gate, "rehearse": rh is not None}
        try:
            return await task
        except asyncio.CancelledError:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            raise
        finally:
            self.active.pop(rid, None)

    def cancel(self, rid):
        a = self.active.get(rid)
        if not a:
            return False
        a["task"].cancel()
        return True

    async def cancel_all(self):
        tasks = [a["task"] for a in self.active.values()]
        for t in tasks:
            t.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    def start_for_event(self, cmd, etype):
        """The event node of `cmd` that listens to `etype` (for simulated trigger events), or None."""
        graph = Graph(cmd, self.sch.with_functions(cmd.get("functions")))
        for nid, nd in graph.defs.items():
            if nd.flow == "event" and (nd.source or {}).get("emits") == etype and nd.id != "event.manual":
                return nid
        return None

    # ---- debugging (protocol methods debug_*): see debug.Gate
    def _gate(self, rid):
        a = self.active.get(rid)
        if not a:
            raise EngineError("no_run", "Запуск «%s» не найден или уже закончился" % rid)
        if a.get("gate") is None:
            raise EngineError("no_debug", "Этот запуск начат без отладки: его нельзя вести по шагам")
        return a["gate"]

    def debug_step(self, rid):
        g = self._gate(rid)
        g.step()
        xlog.info("debug step", run=rid)
        return g.info()

    def debug_continue(self, rid):
        g = self._gate(rid)
        g.cont()
        xlog.info("debug continue", run=rid)
        return g.info()

    def debug_stop(self, rid):
        g = self._gate(rid)
        xlog.info("debug stop", run=rid)
        self.cancel(rid)
        g.ev.set()
        return g.info()

    def debug_breakpoints(self, rid, nodes):
        g = self._gate(rid)
        g.set_breakpoints(nodes)
        return g.info()

    def debug_state(self, rid):
        return self._gate(rid).info()

    def dispatch_event(self, event):
        """Start every enabled automation that listens to this event type; returns the started tasks."""
        tasks = []
        for cmd in self.store.all():
            graph = Graph(cmd, self.sch)
            for nid, nd in graph.defs.items():
                if nd.flow == "event" and (nd.source or {}).get("emits") == event.get("type") and nd.id != "event.manual":
                    tasks.append(asyncio.ensure_future(self.run(cmd, trigger=event["type"], event=event, start_node=nid)))
        return tasks

    def deliver_event(self, event):
        """Hand a normalized event to the runs that wait for it (called by the trigger manager for every event)."""
        n = self.waiters.deliver(event)
        if n:
            xlog.info("event delivered to waiting runs", type=event.get("type"), runs=n)
        return n

    def pin_values(self, rid):
        h = self.pin_history.get(rid)
        if not h:
            return {}
        return {"%s.%s" % k: [v for _, v in d] for k, d in h[1].items()}

    def status(self):
        return {"active": [{"run": r, **{k: v for k, v in a.items() if k not in ("task", "gate")},
                            **({"debug": a["gate"].info()} if a.get("gate") else {})} for r, a in self.active.items()],
                "paused_all": self.state.paused_all, "paused": self.state.paused_cmds(),
                "commands": len(self.store.cmds)}

    # ------------------------------------------------------------------ internals
    def _early(self, base, status, reason, message, **extra):
        res = dict(base, status=status, reason=reason, message=message, steps=[], end=self.clock.now(), dur=0.0, **extra)
        self.runlog.append(res)
        self.events.publish("run", {"ev": "run.end", **{k: res[k] for k in ("run", "cmd", "name", "status", "reason")}})
        return res

    async def _reentrancy(self, cmd, pol, base):
        same = [(r, a) for r, a in self.active.items() if a["cmd"] == cmd["id"]]
        mode = pol["reentrancy"]
        if mode == "skip" and same:
            return self._early(base, "skipped", "reentrancy", "Команда уже выполняется")
        if mode == "parallel" and len(same) >= int(pol.get("parallel", 2)):
            return self._early(base, "skipped", "reentrancy", "Достигнут предел параллельных запусков")
        if mode == "restart":
            for _r, a in same:
                a["task"].cancel()
            await asyncio.gather(*[a["task"] for _r, a in same], return_exceptions=True)
        if mode == "queue":
            lock = self.locks.setdefault(cmd["id"], asyncio.Lock())
            await lock.acquire()
            base["_lock"] = lock
        return None

    async def _notify(self, title, body):
        await self.proc.run(["notify-send", "-a", "Serpantinum", "--", title, body], timeout=5)

    async def _execute(self, ctx, base, pol):
        status, reason, message, undone = "ok", None, None, 0
        lock = base.pop("_lock", None)
        try:
            async with self.sem:
                self.traces.start(ctx.rid, {"cmd": ctx.cmd["id"], "name": ctx.cmd["name"], "trigger": ctx.trigger,
                                            "ts": base["ts"], "dry_run": ctx.dry_run, "rehearse": ctx.rehearse is not None})
                self.events.publish("run", {"ev": "run.start", "run": ctx.rid, "cmd": ctx.cmd["id"], "name": ctx.cmd["name"],
                                            "trigger": ctx.trigger, "rehearse": ctx.rehearse is not None,
                                            "debug": ctx.gate is not None})
                if ctx.rehearse is not None or ctx.gate is not None:
                    xlog.info("debug run start", cmd=ctx.cmd["id"], run=ctx.rid, rehearse=ctx.rehearse is not None,
                              step=bool(ctx.gate and ctx.gate.step_mode), breakpoints=len(ctx.gate.breakpoints) if ctx.gate else 0)
                self._init_vars(ctx)
                try:
                    if ctx.gate is not None:               # a paused run must not hit the run timeout
                        await self._main(ctx)
                    else:
                        await asyncio.wait_for(self._main(ctx), float(pol["timeout_s"]))
                except asyncio.TimeoutError:
                    status, reason, message = "err", "timeout", "Команда превысила таймаут %s с" % pol["timeout_s"]
                except asyncio.CancelledError:
                    status, reason, message = "cancelled", "cancelled", "Запуск отменён"
                except NodeError as e:
                    status, reason, message = "err", "node_error", str(e)
                except BreakLoop:
                    status, reason, message = "err", "break_outside_loop", "«Прервать цикл» сработал вне цикла"
                except EngineError as e:
                    status, reason, message = "err", e.code, e.message
                except Exception as e:                      # engine bug: never leave state half-changed
                    status, reason, message = "err", "internal", "%s: %s" % (type(e).__name__, e)
                undone = await self._rollback(ctx)
                if undone and status != "ok":
                    status = "rolled_back"
        finally:
            if lock:
                lock.release()
        end = ctx.clock.now()
        message = RL.redact_text(message)
        entry = dict(base, status=status, reason=reason, message=message, end=end, dur=round(end - ctx.t0, 3),
                     steps=ctx.steps, undone=undone)
        if ctx.failed_node:
            entry["failed_node"] = ctx.failed_node
        if ctx.fail_path:
            entry["fail_path"] = ctx.fail_path
        self.runlog.append(entry)
        self.undo_store.clear(ctx.rid)
        self.pin_history[ctx.rid] = (end, ctx.pin_hist)
        self.traces.finish(ctx.rid, status=status, reason=reason, message=message, dur=entry["dur"], end=end,
                           failed_node=ctx.failed_node, fail_path=ctx.fail_path)
        if ctx.rehearse is not None or ctx.gate is not None:
            xlog.info("debug run end", cmd=ctx.cmd["id"], run=ctx.rid, status=status, reason=reason, dur=entry["dur"])
        for r in [r for r, (t, _) in self.pin_history.items() if end - t > PIN_HISTORY_TTL]:
            del self.pin_history[r]
        self.events.publish("run", {"ev": "run.end", "run": ctx.rid, "cmd": ctx.cmd["id"], "name": ctx.cmd["name"],
                                    "status": status, "reason": reason, "message": message, "failed_node": ctx.failed_node,
                                    "dur": entry["dur"]})
        return entry

    def _init_vars(self, ctx):
        for name, v in ctx.graph.vars.items():
            if v.get("scope", "run") == "run":
                ctx.vars[name] = v["initial"] if "initial" in v else T.default_value(v.get("type", "text"))

    async def _rollback(self, ctx):
        n = 0
        while ctx.undo:
            e = ctx.undo.pop()
            g = ctx.scopes.get(e.get("scope", "")) or ctx.graph          # entries of a function call know their scope
            nd = g.defs[e["node"]]
            step = {"node": e["node"], "type": nd.type_string, "rollback": True, "status": "ok"}
            if e.get("scope"):
                step["fn"] = e.get("fn", "")
            try:
                if nd.executor.get("kind") == "ipc":
                    await executors.ipc_restore(ctx, nd, e["value"])
                else:
                    await executors.REGISTRY[nd.undo["restore"]](ctx, g.nodes[e["node"]], e["value"])
                n += 1
            except Exception as ex:
                step.update(status="err", error=str(ex))
            ctx.steps.append(step)
            self.undo_store.save(ctx.rid, ctx.cmd["id"], list(ctx.undo))
        return n

    # ---- graph walking
    async def _main(self, ctx):
        """The main chain, then every «Таймер» countdown it started (their «Время вышло» branches run in parallel)."""
        try:
            await self._chain(ctx, ctx.start)
            while ctx.bg:
                batch, ctx.bg[:] = list(ctx.bg), []
                await asyncio.gather(*batch)
        finally:
            pending = [t for t in ctx.bg_all if not t.done()]
            for t in pending:
                t.cancel()
            await asyncio.gather(*pending, return_exceptions=True)

    async def _timer(self, ctx, nid, nd, inputs, step):
        secs, name = float(inputs["seconds"]), str(inputs.get("name") or "")
        if ctx.dry_run and ctx.rehearse is None:
            step["dry_run"] = True
            return
        quiet = ctx.rehearse is not None                 # a rehearsal runs the countdown in fast time, without notifications
        if ctx.rehearse is not None:
            step["dry_run"] = True
            step["fast_forward"] = secs
        title = name or "Таймер"
        if inputs.get("notify_start") and not quiet:
            await self._notify(title, "Запущен: %s" % _human_secs(secs))

        async def tick():
            await ctx.clock.sleep(secs)
            xlog.info("timer finished", cmd=ctx.cmd["id"], run=ctx.rid, node=nid)
            if inputs.get("notify_end") and not quiet:
                await self._notify(title, "Время вышло")
            tgt = self._follow(ctx, nid, "finished")
            if tgt:
                await self._chain(ctx, tgt)
        task = asyncio.ensure_future(tick())
        ctx.root.bg.append(task)
        ctx.root.bg_all.append(task)
        xlog.info("timer started", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, seconds=secs)

    async def _chain(self, ctx, nid):
        cur = nid
        while cur is not None:
            cur = await self._one(ctx, cur)

    def _follow(self, ctx, nid, pin):
        tgt = ctx.graph.exec_out.get((nid, pin))
        if not tgt:
            return None
        self._trace(ctx, "wire", exec=True, frm=[nid, pin], to=list(tgt))
        return tgt[0]

    def _skips(self, ctx, nid, nd, taken):
        """exec outputs that were not taken lead to nodes that will not run (for the «skipped» badge)."""
        outs = [p.id for p in nd.outputs if p.type == "exec"]
        if len(outs) < 2:
            return
        for pin in outs:
            tgt = ctx.graph.exec_out.get((nid, pin))
            if pin != taken and tgt:
                self._trace(ctx, "skip", node=tgt[0], reason="branch", via=[nid, pin])

    def _default_next(self, nd):
        outs = [p.id for p in nd.outputs if p.type == "exec"]
        return "exec_out" if "exec_out" in outs else (outs[0] if outs else None)

    async def _pause(self, ctx, nid):
        g = ctx.root.gate
        reason = g.hit(nid, ctx.depth) if g is not None else None
        if reason is None:
            return
        g.state, g.at, g.reason = "paused", nid, reason
        g.ev.clear()
        self._trace(ctx, "pause", node=nid, reason=reason)
        try:
            await g.ev.wait()
        finally:
            g.state, g.at, g.reason = "running", None, None
        self._trace(ctx, "resume", node=nid, action="step" if g.step_mode else "continue")

    async def _one(self, ctx, nid):
        await self._pause(ctx, nid)
        ctx.root.step_count += 1
        if ctx.root.step_count > self.max_steps:
            raise EngineError("max_steps", "Слишком много шагов в одном запуске (больше %d)" % self.max_steps)
        g = ctx.graph
        nd, node = g.defs[nid], g.nodes[nid]
        props = node.get("props") or {}
        step = {"node": nid, "type": nd.type_string, "t": round(self.clock.now() - ctx.t0, 3), "status": "running",
                "in": {}, "out": {}}
        if ctx.path:
            step["fn"] = ctx.where
        if ctx.root.loops:
            step["iter"] = list(ctx.root.loops)
        ctx.steps.append(step)
        self._trace(ctx, "enter", node=nid, type=nd.type_string)
        t0 = ctx.clock.now()
        nxt_pin = self._default_next(nd)
        loop = None
        try:
            inputs = await self._gather(ctx, nid)
            step["in"] = {p.id: RL.log_value(p, inputs.get(p.id), ctx.root.private) for p in nd.inputs if p.type != "exec" and p.id in inputs}
            outputs, nxt_pin, loop = await self._invoke(ctx, nid, nd, node, inputs, step)
        except NodeError as e:
            if ctx.path and not hasattr(e, "where"):
                e.where = nd.label("ru")                 # the innermost failing node, for the call path in the message
            step.update(status="err", error=str(e), dur=round(ctx.clock.now() - t0, 3))
            self._trace(ctx, "error", node=nid, error=RL.redact_text(str(e)), dur=step["dur"], pins=step.get("in"))
            if props.get("on_error", "stop") == "continue":
                return self._follow(ctx, nid, self._default_next(nd))
            ctx.mark_failed(nid)
            raise
        ctx.epoch += 1
        for pid, val in outputs.items():
            ctx.outputs[(nid, pid)] = val
            ctx.pin_hist[(nid, pid)].append((ctx.clock.now(), RL.shorten(val)))
        step["out"] = {p.id: RL.log_value(p, outputs[p.id], ctx.root.private) for p in nd.outputs if p.id in outputs}
        step.update(status="ok", dur=round(ctx.clock.now() - t0, 3))
        extra = {k: step[k] for k in ("plan", "would_undo", "fast_forward", "simulated", "note") if k in step}
        self._trace(ctx, "exit", node=nid, pins={**step["in"], **step["out"]}, dur=step["dur"], out_pin=nxt_pin if loop is None else None,
                    **extra)
        if loop is None and nxt_pin:
            self._skips(ctx, nid, nd, nxt_pin)
        if loop is not None:                               # for-each: body for every item, then "completed"
            items = loop
            xlog.info("loop start", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, items=len(items))
            for i, item in enumerate(items):
                ctx.outputs[(nid, "item")], ctx.outputs[(nid, "index")] = item, i
                ctx.epoch += 1
                ctx.root.loops.append(i)
                self._trace(ctx, "iter", node=nid, index=i, total=len(items))
                body = self._follow(ctx, nid, "body")
                try:
                    if body is not None:
                        await self._chain(ctx, body)
                except BreakLoop:
                    xlog.info("loop break", cmd=ctx.cmd["id"], run=ctx.rid, node=nid, at=i)
                    step["note"] = "прервано на элементе %d" % (i + 1)
                    break
                finally:
                    ctx.root.loops.pop()
            return self._follow(ctx, nid, "completed")
        return self._follow(ctx, nid, nxt_pin) if nxt_pin else None

    async def _gather(self, ctx, nid):
        nd = ctx.graph.defs[nid]
        out = {}
        for pin in nd.inputs:
            if pin.type != "exec":
                out[pin.id] = await self._input(ctx, nid, nd, pin)
        return out

    async def _input(self, ctx, nid, nd, pin):
        g = ctx.graph
        w = g.in_wire.get((nid, pin.id))
        if w:
            sn, sp = w
            sdef = g.defs[sn]
            if sdef.flow == "pure":
                val = (await self._eval_pure(ctx, sn))[sp]
            elif (sn, sp) in ctx.outputs:
                val = ctx.outputs[(sn, sp)]
            else:
                raise NodeError("Узел «%s» ещё не выполнялся: его выход «%s» пока пуст" % (sdef.label("ru"), sp))
            if g.pin_type(sn, sp, "out") == "int" and g.pin_type(nid, pin.id, "in") == "float":
                val = float(val)
            self._trace(ctx, "wire", frm=[sn, sp], to=[nid, pin.id],
                        value=D.tvalue(next((p for p in sdef.outputs if p.id == sp), None), val))
            return val
        props = g.nodes[nid].get("props") or {}
        if pin.id in props:
            val = props[pin.id]
        elif pin.has_default:
            val = pin.default
        elif pin.required:
            raise NodeError("Не заполнен обязательный вход «%s» узла «%s»" % (pin.id, nd.label("ru")))
        else:
            return None
        if g.pin_type(nid, pin.id, "in") == "float" and isinstance(val, int) and not isinstance(val, bool):
            val = float(val)
        return val

    async def _eval_pure(self, ctx, nid):
        key = (nid, ctx.epoch)
        if key in ctx.memo:
            return ctx.memo[key]
        g = ctx.graph
        nd, node = g.defs[nid], g.nodes[nid]
        step = {"node": nid, "type": nd.type_string, "t": round(self.clock.now() - ctx.t0, 3), "status": "running", "in": {}, "out": {}}
        if ctx.path:
            step["fn"] = ctx.where
        if ctx.root.loops:
            step["iter"] = list(ctx.root.loops)
        ctx.steps.append(step)
        try:
            inputs = await self._gather(ctx, nid)
            out = await self._pure(ctx, nid, nd, inputs)
        except NodeError as e:
            if ctx.path and not hasattr(e, "where"):
                e.where = nd.label("ru")
            step.update(status="err", error=str(e))
            self._trace(ctx, "error", node=nid, error=RL.redact_text(str(e)), pure=True)
            ctx.mark_failed(nid)
            raise
        step["in"] = {p.id: RL.log_value(p, inputs.get(p.id), ctx.root.private) for p in nd.inputs if p.id in inputs}
        step["out"] = {p.id: RL.log_value(p, out.get(p.id), ctx.root.private) for p in nd.outputs if p.id in out}
        step["status"] = "ok"
        for pid, val in out.items():
            ctx.pin_hist[(nid, pid)].append((ctx.clock.now(), RL.shorten(val)))
        self._trace(ctx, "exit", node=nid, pure=True, pins={**step["in"], **step["out"]})
        ctx.memo[key] = out
        return out

    async def _pure(self, ctx, nid, nd, inputs):
        ref = nd.executor.get("ref")
        if nd.executor.get("kind") == "function":
            out, _ = await self._call_function(ctx, nid, nd, inputs, None)
            return out
        if ref == "fn_input":
            return {p.id: ctx.event_data.get(p.id) for p in nd.outputs if p.type != "exec"}
        if ref == "get_var":
            return {"value": self._get_var(ctx, inputs["name"])}
        if ref in pure.FUNCS:
            return pure.FUNCS[ref](inputs)
        if ref == "to_text":
            return {"text": executors.to_text(inputs["value"])}
        if ref == "to_int":
            raw = str(inputs["text"]).strip()
            try:
                return {"value": int(raw)}
            except ValueError:
                raise NodeError("Не удалось превратить «%s» в число" % raw[:60])
        if nd.executor.get("kind") == "py" and ref in executors.REGISTRY:       # read-only data nodes with I/O (selection, clipboard)
            try:
                return await asyncio.wait_for(executors.REGISTRY[ref](ctx, ctx.graph.nodes[nid], inputs), nd.timeout_s)
            except asyncio.TimeoutError:
                raise NodeError("Узел «%s» не ответил за %g с" % (nd.label("ru"), nd.timeout_s))
        raise EngineError("no_handler", "У узла «%s» нет обработчика" % nd.id)

    def _get_var(self, ctx, name):
        decl = ctx.graph.vars.get(name, {})
        if decl.get("scope", "run") == "persist":
            dflt = decl["initial"] if "initial" in decl else T.default_value(decl.get("type", "text"))
            return self.state.get_var(ctx.cmd["id"], name, dflt)
        return ctx.vars.get(name)

    def _set_var(self, ctx, name, val):
        decl = ctx.graph.vars.get(name, {})
        if decl.get("type") == "float" and isinstance(val, int) and not isinstance(val, bool):
            val = float(val)
        if decl.get("scope", "run") == "persist" and not ctx.dry_run:
            self.state.set_var(ctx.cmd["id"], name, val)
        else:
            ctx.vars[name] = val
        decl_secret = decl.get("secret")
        self._trace(ctx, "var", name=name, value="***" if decl_secret else RL.shorten(val, 80))
        return val

    # ---- one node
    async def _invoke(self, ctx, nid, nd, node, inputs, step):
        """-> (outputs, next exec pin, loop items or None)"""
        ex = nd.executor
        kind, ref = ex.get("kind"), ex.get("ref")
        if kind == "builtin":
            if ref == "event":
                return {p.id: ctx.event_data.get(p.id, p.default) for p in nd.outputs if p.type != "exec"}, "exec", None
            if ref == "fn_input":
                return {p.id: ctx.event_data.get(p.id) for p in nd.outputs if p.type != "exec"}, "exec", None
            if ref == "fn_output":
                ctx.fn_result = dict(inputs)
                return {}, None, None
            if ref == "if":
                return {}, ("then" if inputs["condition"] else "else"), None
            if ref == "foreach":
                items = inputs["list"]
                if not isinstance(items, list):
                    raise NodeError("Для «Для каждого» нужен список")
                return {"item": None, "index": 0}, None, items
            if ref == "delay":
                if ctx.rehearse is not None:
                    await ctx.clock.sleep(float(inputs["seconds"]))
                    step.update(dry_run=True, fast_forward=float(inputs["seconds"]))
                elif not ctx.dry_run:
                    await self.clock.sleep(float(inputs["seconds"]))
                else:
                    step["dry_run"] = True
                return {}, "exec_out", None
            if ref == "set_var":
                self._set_var(ctx, inputs["name"], inputs["value"])
                return {}, "exec_out", None
            if ref == "break":
                raise BreakLoop()
            if ref == "increment":
                name, decl = inputs["name"], ctx.graph.vars.get(inputs["name"], {})
                cur, by = self._get_var(ctx, name), inputs["by"]
                if not isinstance(cur, (int, float)) or isinstance(cur, bool):
                    cur = 0
                new = cur + by
                if decl.get("type", "int") == "int" and float(new).is_integer():
                    new = int(new)
                return {"value": self._set_var(ctx, name, new)}, "exec_out", None
            if ref == "timer":
                await self._timer(ctx, nid, nd, inputs, step)
                return {}, "exec_out", None
            if ref == "ask":
                out, pin = await interact.ask(self, ctx, nid, inputs, step)
                return out, pin, None
            if ref == "wait_event":
                out, pin = await interact.wait_event(self, ctx, nid, inputs, step)
                return out, pin, None
            raise EngineError("no_handler", "У узла «%s» нет обработчика" % nd.id)
        if kind == "function":
            out, pin = await self._call_function(ctx, nid, nd, inputs, step)
            return out, pin, None
        if nd.danger == "confirm" and not ctx.dry_run:
            await self._confirm(ctx, nd, node, inputs)
        if ctx.dry_run and nd.side_effects:
            step["dry_run"] = True
            if ctx.rehearse is not None:
                step.update(D.plan(ctx, nd, node, inputs))
            return {p.id: (p.default if p.has_default else T.default_value(p.type)) for p in nd.outputs if p.type != "exec"}, \
                self._default_next(nd), None
        props = node.get("props") or {}
        if nd.undo and not ctx.dry_run:
            mode = props.get("restore", nd.undo.get("default", "off"))
            if mode == "end":
                value = await self._capture(ctx, nd, node, inputs)
                entry = {"node": nid, "mode": mode, "value": value}
                if ctx.depth:
                    ctx.root.scopes[ctx.scope_id] = ctx.graph
                    entry.update(scope=ctx.scope_id, fn=ctx.where)
                ctx.undo.append(entry)
                self.undo_store.save(ctx.rid, ctx.cmd["id"], list(ctx.undo))
        try:
            if kind == "py":
                out = await asyncio.wait_for(executors.REGISTRY[ref](ctx, node, inputs), nd.timeout_s)
            else:
                out = await asyncio.wait_for(executors.ipc_execute(ctx, node, nd, inputs), nd.timeout_s)
        except asyncio.TimeoutError:
            raise NodeError("Узел «%s» не ответил за %g с" % (nd.label("ru"), nd.timeout_s))
        return out or {}, self._default_next(nd), None

    async def _call_function(self, ctx, nid, nd, inputs, step):
        """A call node: run the function graph in an isolated scope (own variables; inputs by value; outputs returned).
        Errors carry the call path; cancel / timeout / rollback work through the shared run (same task, shared undo stack)."""
        fid = nd.executor["ref"]
        fn = ctx.sch.functions.get(fid)
        name = (fn or {}).get("name", nd.label("ru"))
        if fn is None:
            raise NodeError("Функция «%s» не найдена в библиотеке" % name)
        if ctx.depth >= MAX_FN_DEPTH:
            raise EngineError("max_depth", "Функции вложены слишком глубоко (больше %d): %s → «%s»" % (MAX_FN_DEPTH, ctx.where, name))
        root = ctx.root
        root.scope_seq += 1
        graph = Graph({"nodes": fn.get("nodes") or [], "wires": fn.get("wires") or [], "variables": fn.get("variables") or []},
                      ctx.sch.for_function(fn))
        sub = ctx.child(graph, name, dict(inputs), "s%d" % root.scope_seq)
        xlog.debug("function call start", cmd=ctx.cmd["id"], run=ctx.rid, fn=fid, depth=sub.depth)
        t0 = ctx.clock.now()
        try:
            self._init_vars(sub)
            if nd.flow == "pure":
                res = await self._gather(sub, FN_OUT_ID)
            else:
                await self._chain(sub, FN_IN_ID)
                res = sub.fn_result if sub.fn_result is not None else await self._collect_outputs(sub)
        except NodeError as e:
            if hasattr(e, "base"):                       # already carries the full call path from a deeper call
                raise
            where = getattr(e, "where", None)
            base = getattr(e, "base", None) or str(e)
            err = NodeError("%s%s: %s" % ("В функции " + sub.where, (", узел «%s»" % where) if where else "", base))
            err.base = base
            if where:
                err.where = where
            xlog.warn("function call failed", cmd=ctx.cmd["id"], run=ctx.rid, fn=fid, path=sub.where, error=base[:200])
            if ctx.root.fail_path is None:
                ctx.root.fail_path = sub.where
            raise err from None
        except BreakLoop:
            raise NodeError("В функции %s «Прервать цикл» сработал вне цикла" % sub.where)
        xlog.debug("function call end", cmd=ctx.cmd["id"], run=ctx.rid, fn=fid, ms=int((ctx.clock.now() - t0) * 1000))
        outs = {p.id: (res.get(p.id) if res.get(p.id) is not None else (p.default if p.has_default else T.default_value(p.type)))
                for p in nd.outputs if p.type != "exec"}
        return outs, "exec_out"

    async def _collect_outputs(self, sub):
        """The chain of a function ended without reaching «Выход функции» (a group collapsed without an exit wire):
        outputs are still read from the nodes that did run; what never ran stays empty."""
        nd, out = sub.graph.defs.get(FN_OUT_ID), {}
        for pin in (nd.inputs if nd else []):
            if pin.type != "exec":
                try:
                    out[pin.id] = await self._input(sub, FN_OUT_ID, nd, pin)
                except NodeError:
                    pass
        return out

    async def _capture(self, ctx, nd, node, inputs):
        try:
            if nd.executor.get("kind") == "ipc":
                return await executors.ipc_capture(ctx, nd)
            return await executors.REGISTRY[nd.undo["capture"]](ctx, node, inputs)
        except NodeError:
            raise
        except Exception as e:
            raise NodeError("Не удалось запомнить прежнее значение: %s" % e)

    async def _confirm(self, ctx, nd, node, inputs):
        if ctx.auto_confirm:
            return
        summary = ", ".join("%s=%s" % (k, RL.shorten(v, 80)) for k, v in inputs.items())
        answer = await self.ui.request("confirm", {"node": nd.label("ru"), "text": summary}, timeout=60.0)
        if not answer or not answer.get("answer"):
            raise NodeError("Для узла «%s» нужно подтверждение, но его не получено: запуск отменён" % nd.label("ru"))

    def _trace(self, ctx, ev, **kw):
        root = ctx.root
        root.trace_seq += 1
        msg = {"v": D.TRACE_VERSION, "seq": root.trace_seq, "ev": ev, "run": ctx.rid, "t": round(ctx.clock.now() - ctx.t0, 3)}
        if "frm" in kw:
            kw["from"] = kw.pop("frm")
        msg.update({k: v for k, v in kw.items() if v is not None})
        if ctx.path:
            msg["fn"] = list(ctx.path)
        if root.loops:
            msg["iter"] = list(root.loops)
        self.traces.add(ctx.rid, msg)
        self.events.publish("trace", msg)
