"""The operations of the engine, independent of transport: used by the socket server and by the CLI's local mode."""
import time

import copy

from . import model, pins
from .errors import EngineError
from .fnstore import canonical_sha256 as fn_hash, used_function_ids
from .model import CommandError, TRASH_KEEP_DAYS, approved_ok, compute_capabilities
from .util import read_json
from .validate import validate, validate_function
from .xlogshim import log as xlog


class ApiError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def summary(cmd, sch, state):
    caps = compute_capabilities(cmd, sch)
    return {"id": cmd["id"], "name": cmd["name"], "description": cmd.get("description", ""),
            "enabled": cmd.get("enabled", True), "imported": bool(cmd.get("imported")), "capabilities": caps,
            "approved": not approved_ok(cmd, caps), "paused": state.is_paused(cmd["id"])}


def _ref(p):
    """Which command a request is about (name/id only, never the graph or values)."""
    if not isinstance(p, dict):
        return None
    r = p.get("ref") or p.get("name") or (p.get("command") or {}).get("name") if isinstance(p.get("command"), dict) else p.get("ref") or p.get("name")
    return str(r)[:80] if r else None


MUTATING = frozenset(("save", "new", "rename", "duplicate", "delete", "restore", "purge", "revert", "enable", "disable",
                     "approve", "import", "reload", "fn_save", "fn_create", "fn_rename", "fn_duplicate", "fn_delete",
                     "fn_import"))


class Api:
    def __init__(self, engine, store, state, sch, run_log, fnstore=None):
        self.engine, self.store, self.state, self.sch, self.runlog = engine, store, state, sch, run_log
        self.fnstore = fnstore
        self.triggers = None                    # TriggerManager, set by the daemon

    def _cmd(self, ref):
        try:
            return self.store.find(ref)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    async def call(self, method, params=None):
        p = params or {}
        fn = getattr(self, "m_" + method, None)
        if fn is None:
            raise ApiError("unknown_method", "Неизвестный метод «%s»" % method)
        t0 = time.monotonic()
        try:
            res = await fn(p)
        except ApiError as e:
            xlog.warn("api %s rejected" % method, code=e.code, ref=_ref(p))
            raise
        except Exception as e:
            xlog.exception("api %s crashed" % method, exc=e, ref=_ref(p))
            raise
        if method in MUTATING or method in ("validate", "run"):
            xlog.info("api %s" % method, ref=_ref(p), ms=int((time.monotonic() - t0) * 1000))
        if self.triggers is not None and method in MUTATING:
            self.triggers.dirty()
        return res

    async def m_emit(self, p):
        """Inject a normalized event (debugging, the shell's idle bridge). Runs the matching automations for real."""
        if self.triggers is None:
            raise ApiError("no_triggers", "Триггеры работают только в демоне: запустите службу serpantinum-cmdd")
        etype = str(p["type"])
        data = p.get("data") or {}
        if not isinstance(data, dict):
            raise ApiError("bad_params", "data должен быть объектом")
        tasks = await self.triggers.on_event({"type": etype, "data": data, "src": p.get("origin") or "emit",
                                              "synthetic": True})
        return {"type": etype, "started": len(tasks)}

    async def m_triggers(self, p):
        return self.triggers.status() if self.triggers is not None else {"running": False, "sources": {}, "active": [],
                                                                         "subscriptions": [], "recent": []}

    async def m_list(self, p):
        return {"commands": pins.mark([summary(c, self.sch, self.state) for c in self.store.all()]),
                "errors": self.store.errors}

    async def m_get(self, p):
        return self._cmd(p["ref"])

    async def m_validate(self, p):
        cmd = p["command"] if "command" in p else self._cmd(p["ref"])
        return validate(cmd, self.sch)

    async def m_save(self, p):
        """Save the edited command. The editor sends the whole document; rights stay approved only as far as the
        user approved them (a node that needs a new right makes the command «not approved» again)."""
        cmd = p.get("command")
        if not isinstance(cmd, dict) or not str(cmd.get("name", "")).strip():
            raise ApiError("bad_command", "У команды нет названия")
        if not isinstance(cmd.get("nodes"), list) or not isinstance(cmd.get("wires", []), list):
            raise ApiError("bad_command", "Нужны списки nodes и wires")
        cmd["name"] = cmd["name"].strip()
        if self.store.name_taken(cmd["name"], except_id=cmd.get("id")):
            raise ApiError("name_taken", "Команда «%s» уже есть: выберите другое название" % cmd["name"])
        known = self.store.cmds.get(cmd.get("id"))
        if known is not None:        # flags that belong to the engine, not to the editor, are never taken from the client
            for k in ("approved_capabilities", "imported", "enabled"):
                if k in known:
                    cmd[k] = known[k]
                else:
                    cmd.pop(k, None)
        else:
            cmd.pop("imported", None)
            cmd["approved_capabilities"] = []
        saved = self.store.save(cmd, self.sch)
        return {"id": saved["id"], "name": saved["name"], "report": validate(saved, self.sch),
                "command": summary(saved, self.sch, self.state)}

    async def m_new(self, p):
        template = None
        if p.get("from"):
            try:
                template = read_json(p["from"])
            except (OSError, ValueError) as e:
                raise ApiError("bad_file", "Не удалось прочитать образец: %s" % e)
        try:
            if template is not None and template.get("functions") and self.fnstore is not None:
                template, _items = self.fnstore.ingest(template)       # an example's functions join the library
                self._refresh_functions()
            saved = self.store.create(p.get("name", ""), template, self.sch)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        return {"id": saved["id"], "name": saved["name"], "command": summary(saved, self.sch, self.state)}

    async def m_rename(self, p):
        try:
            return summary(self.store.rename(self._cmd(p["ref"]), p.get("name", ""), self.sch), self.sch, self.state)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    async def m_duplicate(self, p):
        try:
            return summary(self.store.duplicate(self._cmd(p["ref"]), p.get("name"), self.sch), self.sch, self.state)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    async def m_delete(self, p):
        cmd = self._cmd(p["ref"])
        try:
            res = self.store.delete(cmd)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self.state.resume_cmd(cmd["id"])
        return {"deleted": res["name"], "id": res["id"], "keep_days": TRASH_KEEP_DAYS}

    async def m_trash(self, p):
        return {"items": self.store.trash_list(), "keep_days": TRASH_KEEP_DAYS}

    async def m_restore(self, p):
        try:
            return summary(self.store.restore(p["ref"], self.sch), self.sch, self.state)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    async def m_purge(self, p):
        return {"removed": self.store.purge_trash(int(p.get("days", TRASH_KEEP_DAYS)))}

    async def m_export(self, p):
        try:
            return self.store.export(self._cmd(p["ref"]), p["path"], self.sch, self.fnstore)
        except (CommandError, OSError) as e:
            raise ApiError(getattr(e, "code", "io_error"), getattr(e, "message", str(e)))

    async def m_history(self, p):
        return {"versions": self.store.history(self._cmd(p["ref"]))}

    async def m_revert(self, p):
        try:
            saved = self.store.revert(self._cmd(p["ref"]), p["version"], self.sch)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        return {"command": summary(saved, self.sch, self.state), "report": validate(saved, self.sch)}

    async def m_run(self, p):
        """Besides dry_run: rehearse (true | {answer, answers:{node:..}, events:[{type,data}]}), event {type,data} (start the
        event node of that type instead of «Вручную»), step, breakpoints [node ids], debug (gate without pausing)."""
        kw = {}
        rh = p.get("rehearse")
        if rh:
            kw["rehearse"] = rh if isinstance(rh, dict) else True
        ev = p.get("event")
        if ev:
            if not isinstance(ev, dict) or not ev.get("type"):
                raise ApiError("bad_params", "event должен быть объектом {type, data}")
            cmd = self._cmd(p["ref"])
            start = self.engine.start_for_event(cmd, str(ev["type"]))
            if start is None:
                raise ApiError("no_start", "В команде нет события «%s»" % ev["type"])
            kw.update(trigger=str(ev["type"]), event={"type": str(ev["type"]), "data": ev.get("data") or {}}, start_node=start)
        if p.get("step") or p.get("breakpoints") or p.get("debug"):
            kw.update(step=bool(p.get("step")), breakpoints=[str(x) for x in p.get("breakpoints") or []], debug=True)
        return await self.engine.run(p["ref"], args=p.get("args"), dry_run=bool(p.get("dry_run")),
                                     auto_confirm=bool(p.get("yes")), **kw)

    def _debug(self, fn, *a):
        try:
            return fn(*a)
        except EngineError as e:
            raise ApiError(e.code, e.message)

    async def m_debug_step(self, p):
        return self._debug(self.engine.debug_step, p["run"])

    async def m_debug_continue(self, p):
        return self._debug(self.engine.debug_continue, p["run"])

    async def m_debug_stop(self, p):
        return self._debug(self.engine.debug_stop, p["run"])

    async def m_debug_breakpoints(self, p):
        return self._debug(self.engine.debug_breakpoints, p["run"], [str(x) for x in p.get("nodes") or []])

    async def m_debug_state(self, p):
        return self._debug(self.engine.debug_state, p["run"])

    async def m_trace(self, p):
        """The recorded trace of a run (ring of the last runs). `run` or `ref`+`last` (the newest run of that command)."""
        rid = p.get("run")
        if not rid:
            cmd = self._cmd(p["ref"])
            lst = self.engine.traces.list(cmd["id"], 1)
            if not lst:
                raise ApiError("no_trace", "У команды «%s» ещё нет сохранённых трасс" % cmd["name"])
            rid = lst[-1]["run"]
        rec = self.engine.traces.get(str(rid))
        if rec is None:
            raise ApiError("no_trace", "Трасса запуска «%s» не найдена (хранятся последние %d запусков)" % (rid, self.engine.traces.keep))
        return rec

    async def m_traces(self, p):
        cmd = self._cmd(p["ref"])["id"] if p.get("ref") else None
        return {"runs": self.engine.traces.list(cmd, int(p.get("n", 30)))}

    async def m_cancel(self, p):
        return {"cancelled": self.engine.cancel(p["run"])}

    async def m_pause(self, p):
        if p.get("ref"):
            cmd = self._cmd(p["ref"])
            self.state.pause_cmd(cmd["id"], "manual", self.engine.clock.now())
        else:
            self.state.set_paused_all(True)
        return {"paused_all": self.state.paused_all, "paused": self.state.paused_cmds()}

    async def m_resume(self, p):
        if p.get("ref"):
            self.state.resume_cmd(self._cmd(p["ref"])["id"])
            self.engine.guard.hits.pop(self._cmd(p["ref"])["id"], None)
        else:
            self.state.set_paused_all(False)
            for cid in list(self.state.paused_cmds()):
                self.state.resume_cmd(cid)
        return {"paused_all": self.state.paused_all, "paused": self.state.paused_cmds()}

    async def m_status(self, p):
        st = self.engine.status()
        st["triggers"] = await self.m_triggers({})
        return st

    async def m_enable(self, p):
        return summary(self.store.set_flag(self._cmd(p["ref"]), enabled=True), self.sch, self.state)

    async def m_disable(self, p):
        return summary(self.store.set_flag(self._cmd(p["ref"]), enabled=False), self.sch, self.state)

    async def m_approve(self, p):
        cmd = self._cmd(p["ref"])
        report = validate(cmd, self.sch)
        caps = report["capabilities"]
        saved = self.store.set_flag(cmd, approved_capabilities=caps, imported=False)
        return {"approved_capabilities": caps, "command": summary(saved, self.sch, self.state)}

    async def m_log(self, p):
        n = int(p.get("n", 20))
        if p.get("ref"):
            cid = self._cmd(p["ref"])["id"]
            runs = [r for r in self.runlog.read() if r.get("cmd") == cid and "run" in r][-n:]
            runs = [{k: v for k, v in r.items() if k != "steps"} | {"trace": self.engine.traces.has(r["run"])} for r in runs]
            return {"runs": runs}
        return {"runs": self.runlog.tail(n)}

    async def m_reload(self, p):
        if self.fnstore is not None:
            self.fnstore.load()
            self._refresh_functions()
        self.store.load()
        return {"commands": len(self.store.cmds), "errors": self.store.errors}

    async def m_pin_values(self, p):
        return self.engine.pin_values(p["run"])

    async def m_import(self, p):
        try:
            return model.import_package(p["path"], self.store, self.sch, self.fnstore)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    # ---- functions (custom nodes) --------------------------------------------------------------------------------
    def _fns(self):
        if self.fnstore is None:
            raise ApiError("no_functions", "Библиотека функций недоступна")
        return self.fnstore

    def _refresh_functions(self):
        self.sch.set_functions(self.fnstore.all())

    def _fn(self, ref):
        try:
            return self._fns().find(ref)
        except CommandError as e:
            raise ApiError(e.code, e.message)

    def _fn_summary(self, fn):
        nd, _ = self.sch.get("fn." + fn["id"] + "@1")
        return {"id": fn["id"], "name": fn["name"], "description": fn.get("description", ""), "exec": bool(fn.get("exec")),
                "inputs": fn.get("inputs", []), "outputs": fn.get("outputs", []), "nodes": len(fn.get("nodes", [])) - 2,
                "capabilities": list(nd.capabilities) if nd else [], "imported": bool(fn.get("imported")),
                "hash": fn_hash(fn)[:12], "type": "fn.%s@1" % fn["id"],
                "ok": validate_function(fn, self.sch)["ok"]}

    async def m_fn_list(self, p):
        fs = self._fns()
        return {"functions": [self._fn_summary(f) for f in fs.all()], "errors": fs.errors}

    async def m_fn_get(self, p):
        return self._fn(p["ref"])

    async def m_fn_validate(self, p):
        fn = p["function"] if "function" in p else self._fn(p["ref"])
        return validate_function(fn, self.sch)

    async def m_fn_save(self, p):
        """Save the edited function graph (the editor sends the whole document). A changed interface is allowed:
        call sites then show broken wires through validation."""
        fn = p.get("function")
        if not isinstance(fn, dict) or not str(fn.get("name", "")).strip() or not isinstance(fn.get("nodes"), list):
            raise ApiError("bad_function", "У функции нет названия или графа")
        fn["name"] = fn["name"].strip()
        fs = self._fns()
        if fs.name_taken(fn["name"], except_id=fn.get("id")):
            raise ApiError("name_taken", "Функция «%s» уже есть: выберите другое название" % fn["name"])
        if fn.get("id") and fn["id"] not in fs.fns:
            raise ApiError("not_found", "Такой функции нет: создайте её заново")
        try:
            saved = fs.save(fn)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        return {"id": saved["id"], "name": saved["name"], "report": validate_function(saved, self.sch),
                "function": self._fn_summary(saved)}

    async def m_fn_create(self, p):
        """New function from the editor's «Свернуть в узел»: the full function document, or just a name (empty graph)."""
        fs = self._fns()
        fn = p.get("function")
        if fn is not None and (not isinstance(fn, dict) or not isinstance(fn.get("nodes"), list)):
            raise ApiError("bad_function", "Нужен граф функции")
        try:
            saved = fs.create(p.get("name") or (fn or {}).get("name", ""), fn)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        xlog.info("function created", fn=saved["id"], name=saved["name"], nodes=len(saved.get("nodes", [])))
        return {"id": saved["id"], "name": saved["name"], "report": validate_function(saved, self.sch),
                "function": self._fn_summary(saved), "type": "fn.%s@1" % saved["id"]}

    async def m_fn_rename(self, p):
        try:
            saved = self._fns().rename(self._fn(p["ref"]), p.get("name", ""), p.get("description"))
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        return self._fn_summary(saved)

    async def m_fn_duplicate(self, p):
        try:
            saved = self._fns().duplicate(self._fn(p["ref"]), p.get("name"))
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        return self._fn_summary(saved)

    async def m_fn_usages(self, p):
        return {"usages": self._fns().usages(self._fn(p["ref"])["id"], self.store)}

    async def m_fn_delete(self, p):
        fn = self._fn(p["ref"])
        users = self._fns().usages(fn["id"], self.store)
        if users and not p.get("force"):
            raise ApiError("in_use", "Функцию «%s» используют: %s. Сначала уберите её оттуда." % (
                fn["name"], ", ".join("«%s»" % u["name"] for u in users[:5])))
        try:
            res = self._fns().delete(fn)
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        return {"deleted": res["name"], "id": res["id"], "keep_days": TRASH_KEEP_DAYS}

    async def m_fn_export(self, p):
        try:
            return self._fns().export(self._fn(p["ref"]), p["path"])
        except (CommandError, OSError) as e:
            raise ApiError(getattr(e, "code", "io_error"), getattr(e, "message", str(e)))

    async def m_fn_import(self, p):
        try:
            res = self._fns().import_package(p["path"])
        except CommandError as e:
            raise ApiError(e.code, e.message)
        self._refresh_functions()
        return res
