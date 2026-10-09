"""Stage 6: functions = custom nodes. Storage, call nodes, isolated scope, outputs, nested calls, cycle rejection,
cancel/rollback through a call, capability union, call paths in errors, export/import without silent overrides."""
import asyncio
import glob
import json
import os
import subprocess
import unittest

import common as C
from common import node, wire, make_cmd
from test_logic import ScriptedUi
from xcmd import fnstore, schema as S
from xcmd.model import compute_capabilities
from xcmd.validate import validate, validate_function


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fn_doc(fid, name, inputs=(), outputs=(), nodes=(), wires=(), variables=(), has_exec=True):
    d = fnstore.empty_function(fid, name, has_exec)
    d["inputs"], d["outputs"] = [dict(p) for p in inputs], [dict(p) for p in outputs]
    d["nodes"] += [dict(n) for n in nodes]
    d["wires"] = [dict(w) for w in wires]
    d["variables"] = list(variables)
    return d


def pin(pid, typ, label=None, **kw):
    return dict({"id": pid, "type": typ, "label": label or pid}, **kw)


FIN, FOUT = S.FN_IN_ID, S.FN_OUT_ID


def greet_fn():
    """exec function: name:text -> shows «Привет, <name>!» and returns it as msg."""
    return fn_doc("greet", "Приветствие", [pin("name", "text", "Имя", default="мир")], [pin("msg", "text", "Сообщение")],
                  [node("t", "data.format@1", template="Привет, {a}!"), node("n", "action.notify@1")],
                  [wire(FIN, "exec", "n", "exec_in"), wire(FIN, "name", "t", "a"), wire("t", "text", "n", "title"),
                   wire("n", "exec_out", FOUT, "exec_in"), wire("t", "text", FOUT, "msg")])


def avg_fn():
    """pure function: x, y -> (x + y) / 2"""
    return fn_doc("avg", "Среднее", [pin("x", "float"), pin("y", "float")], [pin("avg", "float")],
                  [node("s", "data.math@1", op="+"), node("d", "data.math@1", op="/", b=2)],
                  [wire(FIN, "x", "s", "a"), wire(FIN, "y", "s", "b"), wire("s", "result", "d", "a"), wire("d", "result", FOUT, "avg")],
                  has_exec=False)


class FnCase(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.call_ui = None

    def put(self, *fns):
        for f in fns:
            self.rt.fnstore.save(f)
        self.rt.sch.set_functions(self.rt.fnstore.all())

    def cmd(self, name, nodes, wires, **kw):
        c = make_cmd(name, [node("e", "event.manual@1")] + nodes, wires, **kw)
        self.add(c)
        return c

    async def run_cmd(self, name):
        return await self.rt.engine.run(name, auto_confirm=True)

    def notes(self):
        return self.env.lines("notify.log")


class Storage(FnCase):
    async def test_save_load_history_trash_and_env_dir(self):
        fs = self.rt.fnstore
        self.assertEqual(fs.dir, os.path.join(self.env.cmds, "functions"))
        f = fs.create("Тест")
        self.assertTrue(os.path.isfile(os.path.join(fs.dir, f["id"] + ".fn.json")))
        self.assertEqual(f["format"], 1)
        f2 = dict(f, description="v2")
        fs.save(f2)
        self.assertEqual(len(os.listdir(os.path.join(self.env.state, "history", "functions", f["id"]))), 1)
        fs2 = fnstore.FnStore(fs.dir).load()
        self.assertEqual(fs2.get(f["id"])["description"], "v2")
        res = fs.delete(f)
        self.assertTrue(os.path.isfile(res["file"]))
        self.assertIsNone(fs.get(f["id"]))
        self.assertFalse(glob.glob(os.path.join(fs.dir, "*.fn.json")))

    async def test_names_unique_rename_duplicate_usages(self):
        fs = self.rt.fnstore
        a = fs.create("Один")
        with self.assertRaises(Exception):
            fs.create("один")
        b = fs.duplicate(a)
        self.assertEqual(b["name"], "Один (копия)")
        self.assertNotEqual(a["id"], b["id"])
        fs.rename(b, "Два", "описание")
        self.assertEqual(fs.get(b["id"])["description"], "описание")
        self.put(greet_fn())
        self.cmd("user", [node("c", "fn.greet@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertEqual([u["name"] for u in fs.usages("greet", self.rt.store)], ["user"])

    async def test_broken_file_reported_not_fatal(self):
        os.makedirs(self.rt.fnstore.dir)
        with open(os.path.join(self.rt.fnstore.dir, "bad.fn.json"), "w") as f:
            f.write("{nope")
        self.rt.fnstore.load()
        self.assertEqual(len(self.rt.fnstore.errors), 1)


class Calls(FnCase):
    async def test_call_node_generated_from_function(self):
        self.put(greet_fn(), avg_fn())
        nd, _ = self.rt.sch.get("fn.greet@1")
        self.assertEqual((nd.category, nd.flow, nd.label("ru")), ("function", "action", "Приветствие"))
        self.assertEqual([p.id for p in nd.inputs], ["exec_in", "name"])
        self.assertEqual([p.id for p in nd.outputs], ["exec_out", "msg"])
        self.assertEqual(nd.capabilities, ["notify.show"])
        pure, _ = self.rt.sch.get("fn.avg@1")
        self.assertEqual(pure.flow, "pure")
        self.assertFalse([p for p in pure.inputs + pure.outputs if p.type == "exec"])

    async def test_inputs_outputs_and_default(self):
        self.put(greet_fn())
        self.cmd("hi", [node("c", "fn.greet@1", name="Мир"), node("c2", "fn.greet@1"), node("n", "action.notify@1")],
                 [wire("e", "exec", "c", "exec_in"), wire("c", "exec_out", "c2", "exec_in"), wire("c2", "exec_out", "n", "exec_in"),
                  wire("c", "msg", "n", "body"), wire("c2", "msg", "n", "title")])
        res = await self.run_cmd("hi")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.notes(), ["-a Serpantinum -- Привет, Мир!", "-a Serpantinum -- Привет, мир!",
                                        "-a Serpantinum -- Привет, мир! Привет, Мир!"])
        inner = [s for s in res["steps"] if s.get("fn")]
        self.assertTrue(inner and all(s["fn"] == "«Приветствие»" for s in inner))

    async def test_function_without_exit_wire_still_returns_outputs(self):
        f = fn_doc("noexit", "Без выхода", [], [pin("msg", "text")], [node("t", "data.format@1", template="готово"), node("n", "action.notify@1", title="x")],
                   [wire(FIN, "exec", "n", "exec_in"), wire("t", "text", FOUT, "msg")])
        self.put(f)
        self.cmd("ne", [node("c", "fn.noexit@1"), node("n", "action.notify@1")],
                 [wire("e", "exec", "c", "exec_in"), wire("c", "exec_out", "n", "exec_in"), wire("c", "msg", "n", "title")])
        res = await self.run_cmd("ne")
        self.assertEqual((res["status"], self.notes()), ("ok", ["-a Serpantinum -- x", "-a Serpantinum -- готово"]), res)

    async def test_pure_function_in_data_wire(self):
        self.put(avg_fn())
        self.cmd("avg", [node("c", "fn.avg@1", x=3, y=8), node("t", "convert.to_text@1"), node("n", "action.notify@1")],
                 [wire("e", "exec", "n", "exec_in"), wire("c", "avg", "t", "value"), wire("t", "text", "n", "title")])
        res = await self.run_cmd("avg")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.notes(), ["-a Serpantinum -- 5.5"])

    async def test_scope_isolation_variables(self):
        f = fn_doc("setx", "Задать x", [], [pin("seen", "text")],
                   [node("s", "logic.set_var@1", name="x", value="внутри"), node("g", "data.get_var@1", name="x")],
                   [wire(FIN, "exec", "s", "exec_in"), wire("s", "exec_out", FOUT, "exec_in"), wire("g", "value", FOUT, "seen")],
                   variables=[{"name": "x", "type": "text", "initial": "?"}])
        self.put(f)
        self.cmd("scope", [node("sv", "logic.set_var@1", name="x", value="снаружи"), node("c", "fn.setx@1"),
                           node("g", "data.get_var@1", name="x"), node("n", "action.notify@1")],
                 [wire("e", "exec", "sv", "exec_in"), wire("sv", "exec_out", "c", "exec_in"), wire("c", "exec_out", "n", "exec_in"),
                  wire("g", "value", "n", "title"), wire("c", "seen", "n", "body")],
                 variables=[{"name": "x", "type": "text"}])
        res = await self.run_cmd("scope")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.notes(), ["-a Serpantinum -- снаружи внутри"])

    async def test_function_cannot_see_caller_variable(self):
        f = fn_doc("peek", "Подсмотреть", [], [], [node("s", "logic.set_var@1", name="outer", value="1")],
                   [wire(FIN, "exec", "s", "exec_in"), wire("s", "exec_out", FOUT, "exec_in")])
        self.put(f)
        c = self.cmd("peek", [node("c", "fn.peek@1")], [wire("e", "exec", "c", "exec_in")], variables=[{"name": "outer", "type": "text"}])
        res = await self.run_cmd("peek")
        self.assertEqual(res["status"], "invalid", res)       # «переменная не объявлена»: scope is really separate
        self.assertIn("fn_invalid", [e["code"] for e in validate(c, self.rt.sch)["errors"]])

    async def test_nested_calls_and_foreach_in_function(self):
        inner = fn_doc("loop3", "Три раза", [pin("what", "text")], [],
                       [node("f", "logic.foreach@1", list=[1, 2, 3]), node("n", "action.notify@1")],
                       [wire(FIN, "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire(FIN, "what", "n", "title"),
                        wire("f", "completed", FOUT, "exec_in")])
        outer = fn_doc("outer", "Обёртка", [], [], [node("c", "fn.loop3@1", what="ура")],
                       [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        self.put(inner, outer)
        self.cmd("nest", [node("c", "fn.outer@1")], [wire("e", "exec", "c", "exec_in")])
        res = await self.run_cmd("nest")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.notes(), ["-a Serpantinum -- ура"] * 3)
        self.assertIn("«Обёртка» → «Три раза»", [s.get("fn") for s in res["steps"]])

    async def test_delay_and_ask_inside_function(self):
        f = fn_doc("slow", "Медленно", [], [pin("answer", "text")],
                   [node("d", "logic.delay@1", seconds=2), node("a", "logic.ask@1", mode="text", title="Как дела?")],
                   [wire(FIN, "exec", "d", "exec_in"), wire("d", "exec_out", "a", "exec_in"), wire("a", "exec_out", FOUT, "exec_in"),
                    wire("a", "text", FOUT, "answer")])
        ui = ScriptedUi({"value": "норм"})
        self.runtime(ui=ui)
        self.put(f)
        self.cmd("slow", [node("c", "fn.slow@1"), node("n", "action.notify@1")],
                 [wire("e", "exec", "c", "exec_in"), wire("c", "exec_out", "n", "exec_in"), wire("c", "answer", "n", "title")])
        res = await self.run_cmd("slow")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.clock.sleeps, [2.0])
        self.assertEqual(len(ui.requests), 1)
        self.assertEqual(self.notes(), ["-a Serpantinum -- норм"])

    async def test_error_reports_call_path_in_russian(self):
        inner = fn_doc("bad", "Плохая", [], [], [node("s", "action.shell@1", command="exit 3")],
                       [wire(FIN, "exec", "s", "exec_in"), wire("s", "exec_out", FOUT, "exec_in")])
        outer = fn_doc("wrap", "Оболочка", [], [], [node("c", "fn.bad@1")],
                       [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        self.put(inner, outer)
        self.cmd("fail", [node("c", "fn.wrap@1")], [wire("e", "exec", "c", "exec_in")])
        res = await self.run_cmd("fail")
        self.assertEqual(res["status"], "err", res)
        self.assertIn("В функции «Оболочка» → «Плохая», узел «Выполнить команду оболочки»", res["message"])
        self.assertEqual(res["failed_node"], "c")
        self.assertEqual(res["fail_path"], "«Оболочка» → «Плохая»")

    async def test_on_error_continue_works_on_call_node(self):
        inner = fn_doc("bad", "Плохая", [], [], [node("s", "action.shell@1", command="exit 3")],
                       [wire(FIN, "exec", "s", "exec_in"), wire("s", "exec_out", FOUT, "exec_in")])
        self.put(inner)
        self.cmd("cont", [node("c", "fn.bad@1", on_error="continue"), node("n", "action.notify@1", title="дальше")],
                 [wire("e", "exec", "c", "exec_in"), wire("c", "exec_out", "n", "exec_in")])
        res = await self.run_cmd("cont")
        self.assertEqual((res["status"], self.notes()), ("ok", ["-a Serpantinum -- дальше"]))


def clip_fn(after=()):
    nodes = [node("c", "action.clipboard_set@1", text="новое", restore="end")] + list(after)
    wires = [wire(FIN, "exec", "c", "exec_in")]
    prev = "c"
    for n in after:
        wires.append(wire(prev, "exec_out", n["id"], "exec_in"))
        prev = n["id"]
    wires.append(wire(prev, "exec_out", FOUT, "exec_in"))
    return fn_doc("clip", "Буфер", [], [], nodes, wires)


class Rollback(FnCase):
    async def test_rollback_after_error_in_caller(self):
        self.env.write_fake("clipboard.txt", "прежнее")
        self.put(clip_fn())
        self.cmd("rb", [node("c", "fn.clip@1"), node("s", "action.shell@1", command="exit 1")],
                 [wire("e", "exec", "c", "exec_in"), wire("c", "exec_out", "s", "exec_in")])
        res = await self.run_cmd("rb")
        self.assertEqual((res["status"], res["undone"]), ("rolled_back", 1), res)
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")
        rb = [s for s in res["steps"] if s.get("rollback")]
        self.assertEqual(rb[0]["fn"], "«Буфер»")

    async def test_ok_run_restores_at_end(self):
        self.env.write_fake("clipboard.txt", "прежнее")
        self.put(clip_fn())
        self.cmd("rbok", [node("c", "fn.clip@1")], [wire("e", "exec", "c", "exec_in")])
        res = await self.run_cmd("rbok")
        self.assertEqual((res["status"], res["undone"]), ("ok", 1))
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")


class RollbackCancel(FnCase):
    use_fake_clock = False

    async def test_cancel_inside_function_rolls_back(self):
        self.runtime()
        self.env.write_fake("clipboard.txt", "прежнее")
        self.put(clip_fn([node("d", "logic.delay@1", seconds=5)]))
        self.cmd("cc", [node("c", "fn.clip@1")], [wire("e", "exec", "c", "exec_in")])
        t = asyncio.ensure_future(self.run_cmd("cc"))
        for _ in range(300):
            if self.env.read("clipboard.txt") == "новое":
                break
            await asyncio.sleep(0.01)
        self.rt.engine.cancel(next(iter(self.rt.engine.active)))
        res = await t
        self.assertEqual((res["status"], res["undone"]), ("rolled_back", 1), res)
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")

    async def test_run_timeout_propagates_through_call(self):
        self.runtime()
        self.env.write_fake("clipboard.txt", "прежнее")
        self.put(clip_fn([node("d", "logic.delay@1", seconds=30)]))
        self.cmd("to", [node("c", "fn.clip@1")], [wire("e", "exec", "c", "exec_in")], policy={"timeout_s": 0.3})
        res = await self.run_cmd("to")
        self.assertEqual(res["reason"], "timeout", res)
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")


class Validation(FnCase):
    def codes(self, cmd, level="errors"):
        return [i["code"] for i in validate(cmd, self.rt.sch)[level]]

    async def test_cycle_a_b_a_and_self_rejected(self):
        a = fn_doc("fa", "А", [], [], [node("c", "fn.fb@1")], [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        b = fn_doc("fb", "Б", [], [], [node("c", "fn.fa@1")], [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        me = fn_doc("fs", "Сам", [], [], [node("c", "fn.fs@1")], [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        self.put(a, b, me)
        for fid in ("fa", "fb", "fs"):
            rep = validate_function(self.rt.sch.functions[fid], self.rt.sch)
            self.assertIn("fn_cycle", [e["code"] for e in rep["errors"]], fid)
        cmd = self.cmd("cyc", [node("c", "fn.fa@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertIn("fn_cycle", self.codes(cmd))
        msg = next(e["message"] for e in validate(cmd, self.rt.sch)["errors"] if e["code"] == "fn_cycle")
        self.assertIn("«А» → «Б» → «А»", msg)
        res = await self.run_cmd("cyc")
        self.assertEqual(res["status"], "invalid")

    async def test_depth_limit(self):
        fns = []
        for i in range(S.MAX_FN_DEPTH + 1):
            nodes = [node("c", "fn.d%d@1" % (i + 1))] if i < S.MAX_FN_DEPTH else []
            wires = [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")] if nodes else [wire(FIN, "exec", FOUT, "exec_in")]
            fns.append(fn_doc("d%d" % i, "Уровень %d" % i, [], [], nodes, wires))
        self.put(*fns)
        cmd = self.cmd("deep", [node("c", "fn.d0@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertIn("fn_depth", self.codes(cmd))

    async def test_runtime_depth_guard_even_if_validation_skipped(self):
        # defence in depth: the engine itself refuses a call chain deeper than the limit
        fns = []
        for i in range(S.MAX_FN_DEPTH + 2):
            nodes = [node("c", "fn.e%d@1" % (i + 1))] if i < S.MAX_FN_DEPTH + 1 else []
            wires = [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")] if nodes else [wire(FIN, "exec", FOUT, "exec_in")]
            fns.append(fn_doc("e%d" % i, "Е%d" % i, [], [], nodes, wires))
        self.put(*fns)
        self.assertIsNotNone(self.rt.sch.call_problem("e0"))

    async def test_type_mismatch_at_call_site_offers_converter(self):
        self.put(avg_fn())
        cmd = self.cmd("tm", [node("c", "fn.avg@1"), node("n", "action.notify@1")],
                       [wire("e", "exec", "n", "exec_in"), wire("c", "avg", "n", "title")])
        errs = [e for e in validate(cmd, self.rt.sch)["errors"] if e["code"] == "type_mismatch"]
        self.assertEqual(len(errs), 1)
        self.assertEqual(errs[0]["fix"]["kind"], "insert_converter")

    async def test_function_rules(self):
        ev = fn_doc("ev", "С событием", [], [], [node("x", "event.manual@1")], [wire(FIN, "exec", FOUT, "exec_in")])
        imp = fn_doc("imp", "Чистая, но действует", [], [], [node("n", "action.notify@1", title="x")], [], has_exec=False)
        pers = fn_doc("pe", "Постоянная", [], [], [], [wire(FIN, "exec", FOUT, "exec_in")], variables=[{"name": "v", "type": "int", "scope": "persist"}])
        badpin = fn_doc("bp", "Плохой пин", [pin("Bad Id", "int"), pin("ok", "nonsense")], [], [], [wire(FIN, "exec", FOUT, "exec_in")])
        self.put(ev, imp, pers, badpin)
        codes = lambda f: [e["code"] for e in validate_function(self.rt.sch.functions[f], self.rt.sch)["errors"]]
        self.assertIn("fn_event_node", codes("ev"))
        self.assertIn("fn_impure", codes("imp"))
        self.assertIn("bad_variable", codes("pe"))
        self.assertEqual(codes("bp").count("fn_interface"), 2)
        for f in (greet_fn(), avg_fn()):
            self.assertTrue(validate_function(f, self.rt.sch)["ok"], validate_function(f, self.rt.sch))

    async def test_broken_function_makes_call_site_invalid(self):
        imp = fn_doc("imp", "Чистая, но действует", [], [], [node("n", "action.notify@1", title="x")], [], has_exec=False)
        self.put(imp)
        cmd = self.cmd("bf", [node("c", "fn.imp@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertIn("fn_invalid", self.codes(cmd))
        self.assertEqual((await self.run_cmd("bf"))["status"], "invalid")


class Capabilities(FnCase):
    async def test_union_of_inner_nodes_and_nested(self):
        shell = fn_doc("sh", "Скрипт", [], [], [node("s", "action.shell@1", command="true")],
                       [wire(FIN, "exec", "s", "exec_in"), wire("s", "exec_out", FOUT, "exec_in")])
        outer = fn_doc("ou", "Внешняя", [], [], [node("c", "fn.sh@1"), node("n", "action.notify@1", title="x")],
                       [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", "n", "exec_in"), wire("n", "exec_out", FOUT, "exec_in")])
        self.put(shell, outer)
        nd, _ = self.rt.sch.get("fn.ou@1")
        self.assertEqual(nd.capabilities, ["exec.script", "notify.show"])
        cmd = self.cmd("caps", [node("c", "fn.ou@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertEqual(compute_capabilities(cmd, self.rt.sch), ["exec.script", "notify.show"])
        self.assertEqual(validate(cmd, self.rt.sch)["capabilities"], ["exec.script", "notify.show"])

    async def test_unapproved_capability_from_function_blocks_run(self):
        self.put(greet_fn())
        c = make_cmd("deny", [node("e", "event.manual@1"), node("c", "fn.greet@1")], [wire("e", "exec", "c", "exec_in")])
        self.add(c, approve=False)
        res = await self.run_cmd("deny")
        self.assertEqual((res["status"], res["missing"]), ("denied", ["notify.show"]))
        self.assertFalse(self.notes())

    async def test_function_gaining_a_capability_revokes_approval(self):
        self.put(greet_fn())
        self.cmd("grow", [node("c", "fn.greet@1")], [wire("e", "exec", "c", "exec_in")])
        self.assertEqual((await self.run_cmd("grow"))["status"], "ok")
        g = greet_fn()
        g["nodes"].append(node("s", "action.shell@1", command="true"))
        self.put(g)
        res = await self.run_cmd("grow")
        self.assertEqual((res["status"], res["missing"]), ("denied", ["exec.script"]))


class ExportImport(FnCase):
    async def test_embedded_command_runs_without_library_and_ingests(self):
        g = greet_fn()
        c = make_cmd("emb", [node("e", "event.manual@1"), node("c", "fn.greet@1", name="Я")], [wire("e", "exec", "c", "exec_in")])
        c["functions"] = [g]
        self.assertEqual(self.rt.sch.functions, {})
        approved = dict(c, approved_capabilities=compute_capabilities(c, self.rt.sch))
        res = await self.rt.engine.run(approved)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.notes(), ["-a Serpantinum -- Привет, Я!"])
        self.assertEqual(compute_capabilities(c, self.rt.sch), ["notify.show"])

    async def test_export_command_embeds_and_import_never_overrides(self):
        self.put(greet_fn())
        c = self.cmd("exp", [node("c", "fn.greet@1")], [wire("e", "exec", "c", "exec_in")])
        c = self.rt.store.save(c, self.rt.sch)
        out = os.path.join(self.env.root, "exp.scmd")
        self.rt.store.export(c, out, self.rt.sch, self.rt.fnstore)
        pkg = _load(out)
        self.assertEqual([f["id"] for f in pkg["command"]["functions"]], ["greet"])
        # 1) same content: reused, nothing new
        self.rt.store.delete(self.rt.store.find("exp"))
        r = self.rt.api and __import__("xcmd.model", fromlist=["x"]).import_package(out, self.rt.store, self.rt.sch, self.rt.fnstore)
        self.assertEqual([i["status"] for i in r["functions"]], ["same"])
        self.assertEqual(len(self.rt.fnstore.fns), 1)
        # 2) local greet changed: the imported (old) one comes in under a new id, local is untouched
        local = dict(self.rt.fnstore.get("greet"), description="локальная правка")
        self.rt.fnstore.save(local)
        self.rt.store.delete(self.rt.store.find("exp"))
        r = __import__("xcmd.model", fromlist=["x"]).import_package(out, self.rt.store, self.rt.sch, self.rt.fnstore)
        self.assertEqual([i["status"] for i in r["functions"]], ["renamed"])
        self.assertEqual(self.rt.fnstore.get("greet")["description"], "локальная правка")
        self.assertEqual(len(self.rt.fnstore.fns), 2)
        self.assertTrue(any("greet" in w for w in r["warnings"]))
        imported = self.rt.store.find(r["command"])
        self.assertNotIn("functions", imported)
        new_id = r["functions"][0]["id"]
        self.assertEqual(imported["nodes"][1]["type"], "fn.%s@1" % new_id)
        self.assertFalse(imported["enabled"])

    async def test_function_package_roundtrip_with_deps_and_tamper_check(self):
        inner, outer = greet_fn(), fn_doc("wr", "Обёртка", [], [], [node("c", "fn.greet@1")],
                                          [wire(FIN, "exec", "c", "exec_in"), wire("c", "exec_out", FOUT, "exec_in")])
        self.put(inner, outer)
        out = os.path.join(self.env.root, "wr.sfn")
        res = self.rt.fnstore.export(outer, out)
        self.assertEqual(res["functions"], 2)
        other = fnstore.FnStore(os.path.join(self.env.root, "other", "functions"), clock=self.rt.fnstore.clock)
        r = other.import_package(out)
        self.assertEqual(sorted(i["status"] for i in r["functions"]), ["new", "new"])
        self.assertEqual(sorted(other.fns), ["greet", "wr"])
        pkg = _load(out)
        pkg["function"]["name"] = "Подделка"
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(pkg, fh)
        with self.assertRaises(Exception) as cm:
            other.import_package(out)
        self.assertEqual(cm.exception.code, "bad_checksum")


class ApiAndCli(FnCase):
    async def test_api_create_delete_with_usage_check(self):
        api = self.rt.api
        res = await api.call("fn_create", {"function": greet_fn(), "name": "Новая"})
        self.assertTrue(res["report"]["ok"], res["report"])
        self.assertEqual(res["type"], "fn." + res["id"] + "@1")
        self.assertIsNotNone(self.rt.sch.get(res["type"])[0])
        self.cmd("u", [node("c", res["type"])], [wire("e", "exec", "c", "exec_in")])
        from xcmd.api import ApiError
        with self.assertRaises(ApiError) as cm:
            await api.call("fn_delete", {"ref": res["id"]})
        self.assertEqual(cm.exception.code, "in_use")
        self.rt.store.delete(self.rt.store.find("u"))
        out = await api.call("fn_delete", {"ref": res["id"]})
        self.assertEqual(out["id"], res["id"])
        self.assertIsNone(self.rt.sch.get(res["type"])[0])

    async def test_cli_fn_commands(self):
        x = os.path.join(C.CMD_DIR, "x_cmd.sh")
        env = self.env.env_for_subprocess()

        def cli(*a, stdin=None):
            return subprocess.run(["bash", x, "--local", "--json", *a], input=stdin, capture_output=True, text=True, env=env)
        r = cli("fn", "create", "--stdin", stdin=json.dumps(greet_fn()))
        self.assertEqual(r.returncode, 0, r.stderr)
        fid = json.loads(r.stdout)["id"]
        self.assertEqual([f["id"] for f in json.loads(cli("fn", "list").stdout)["functions"]], [fid])
        self.assertEqual(json.loads(cli("fn", "show", "Приветствие").stdout)["id"], fid)
        self.assertEqual(json.loads(cli("fn", "validate", "Приветствие").stdout)["ok"], True)
        out = os.path.join(self.env.root, "g.sfn")
        self.assertEqual(cli("fn", "export", fid, out).returncode, 0)
        self.assertEqual(cli("fn", "delete", fid).returncode, 0)
        self.assertEqual(json.loads(cli("fn", "list").stdout)["functions"], [])
        r = cli("fn", "import", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["functions"][0]["status"], "new")
        r = cli("fn", "validate", "--stdin", stdin=json.dumps(avg_fn()))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = cli("ui-fn-get", fid)
        view = json.loads(r.stdout)
        self.assertEqual(view["function"]["id"], fid)
        self.assertEqual({n["id"] for n in view["nodes"]}, {FIN, FOUT, "t", "n"})
        self.assertEqual(len(view["iface_catalog"]), 2)

    async def test_new_from_example_ingests_embedded_functions(self):
        ex = os.path.join(C.CMD_DIR, "examples", "use-functions.cmd.json")
        res = await self.rt.api.call("new", {"name": "Мои функции", "from": ex})
        cmd = self.rt.store.cmds[res["id"]]
        self.assertNotIn("functions", cmd)
        self.assertEqual(sorted(self.rt.fnstore.fns), ["average", "greet"])
        self.assertTrue(validate(cmd, self.rt.sch)["ok"])
        await self.rt.api.call("approve", {"ref": res["id"]})
        run = await self.rt.engine.run(res["id"])
        self.assertEqual(run["status"], "ok", run)
        self.assertEqual(self.notes(), ["-a Serpantinum -- Привет, Serpantinum!", "-a Serpantinum -- Среднее 3 и 8 5.5"])

    async def test_docs_include_function_help(self):
        from xcmd import docs
        self.put(greet_fn())
        text = docs.render_all(self.rt.sch, "ru")
        self.assertIn("Приветствие", text)
        self.assertIn("## Функции", text)
        self.assertIn("`name`", text)


class Examples(unittest.TestCase):
    def test_example_functions_and_command_validate(self):
        sch = S.load_schema([os.path.join(C.CMD_DIR, "nodes")])
        fns = [_load(f) for f in sorted(glob.glob(os.path.join(C.CMD_DIR, "examples", "*.fn.json")))]
        self.assertGreaterEqual(len(fns), 2)
        sch.set_functions(fns)
        for f in fns:
            rep = validate_function(f, sch)
            self.assertTrue(rep["ok"], (f["name"], rep["errors"]))
        cmd = _load(os.path.join(C.CMD_DIR, "examples", "use-functions.cmd.json"))
        self.assertTrue(cmd.get("functions"))
        rep = validate(cmd, S.load_schema([os.path.join(C.CMD_DIR, "nodes")]))      # self-contained: no library needed
        self.assertTrue(rep["ok"], rep["errors"])


if __name__ == "__main__":
    unittest.main()
