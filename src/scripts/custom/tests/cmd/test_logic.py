"""Stage 5: logic nodes (if/compare, for-each + break, variables, ask, wait-for-event) and their validation."""
import asyncio
import glob
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd
from test_protocol import DaemonCase
from test_triggers import FakeSource
from xcmd import schema as S, triggers as TR
from xcmd.validate import validate

SCH = S.load_schema()
EXAMPLES = sorted(glob.glob(os.path.join(C.CMD_DIR, "examples", "*.cmd.json")))


def codes(cmd, level="errors"):
    return [i["code"] for i in validate(cmd, SCH)[level]]


class ScriptedUi:
    """UI bridge: answers from a script; a None answer = the shell did not answer in time."""

    def __init__(self, *answers):
        self.answers, self.requests = list(answers), []

    async def request(self, kind, payload, timeout=3.0):
        self.requests.append((kind, payload, timeout))
        return self.answers.pop(0) if self.answers else None


def ask_cmd(name, mode="choice", **props):
    nodes = [node("e", "event.manual@1"), node("a", "logic.ask@1", mode=mode, **props),
             node("ok", "action.notify@1", title="ok"), node("ca", "action.notify@1", title="cancel"),
             node("to", "action.notify@1", title="timeout")]
    w = [wire("e", "exec", "a", "exec_in"), wire("a", "exec_out", "ok", "exec_in"), wire("a", "cancelled", "ca", "exec_in"),
         wire("a", "timed_out", "to", "exec_in")]
    return make_cmd(name, nodes, w)


class DataNodes(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    async def calc(self, ntype, wires_in=None, **props):
        """Run a pure node and read its first output through a notification title."""
        sch_nd = SCH.get(ntype)[0]
        out = next(p for p in sch_nd.outputs)
        nodes = [node("e", "event.manual@1"), node("p", ntype, **props), node("c", "convert.to_text@1"), node("n", "action.notify@1")]
        w = [wire("e", "exec", "n", "exec_in"), wire("p", out.id, "c", "value"), wire("c", "text", "n", "title")]
        self.add(make_cmd("calc", nodes, w, id="calc"))
        res = await self.rt.engine.run("calc")
        self.assertEqual(res["status"], "ok", res)
        return self.env.lines("notify.log")[-1].replace("-a Serpantinum -- ", "")

    async def test_math_and_compare(self):
        self.assertEqual(await self.calc("data.math@1", a=7, op="+", b=4), "11")
        self.assertEqual(await self.calc("data.math@1", a=7, op="/", b=2), "3.5")
        self.assertEqual(await self.calc("data.compare_number@1", a=3, op=">=", b=3), "да")
        self.assertEqual(await self.calc("data.compare_number@1", a=3, op="<", b=3), "нет")

    async def test_division_by_zero_is_a_russian_error(self):
        nodes = [node("e", "event.manual@1"), node("p", "data.math@1", a=1, op="/", b=0), node("c", "convert.to_text@1"),
                 node("n", "action.notify@1")]
        self.add(make_cmd("dz", nodes, [wire("e", "exec", "n", "exec_in"), wire("p", "result", "c", "value"), wire("c", "text", "n", "title")]))
        res = await self.rt.engine.run("dz")
        self.assertEqual((res["status"], res["reason"]), ("err", "node_error"))
        self.assertIn("Деление на ноль", res["message"])

    async def test_text_nodes(self):
        self.assertEqual(await self.calc("data.compare_text@1", a="Привет, Мир", op="contains", b="мир"), "да")
        self.assertEqual(await self.calc("data.compare_text@1", a="abc123", op="regex", b="^[a-c]+\\d+$"), "да")
        self.assertEqual(await self.calc("data.compare_text@1", a="Мир", op="equals", b="мир", ignore_case=False), "нет")
        self.assertEqual(await self.calc("data.concat@1", a="При", b="вет"), "Привет")
        self.assertEqual(await self.calc("data.format@1", template="{a} из {b}", a=3, b=10), "3 из 10")
        self.assertEqual(await self.calc("data.split@1", text="a,b,c", sep=","), "a, b, c")
        self.assertEqual(await self.calc("data.range@1", start=1, count=3), "1, 2, 3")
        self.assertEqual(await self.calc("data.list_length@1", list=["x", "y"]), "2")
        self.assertEqual(await self.calc("data.list_get@1", list=["x", "y"], index=1), "y")

    async def test_bool_nodes(self):
        self.assertEqual(await self.calc("data.and@1", a=True, b=False), "нет")
        self.assertEqual(await self.calc("data.or@1", a=True, b=False), "да")
        self.assertEqual(await self.calc("data.not@1", value=False), "да")

    async def test_list_get_out_of_range(self):
        nodes = [node("e", "event.manual@1"), node("p", "data.list_get@1", list=["a"], index=3), node("n", "action.notify@1")]
        self.add(make_cmd("lg", nodes, [wire("e", "exec", "n", "exec_in"), wire("p", "item", "n", "title")]))
        res = await self.rt.engine.run("lg")
        self.assertEqual(res["status"], "err")
        self.assertIn("нет номера 3", res["message"])


class FlowTests(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    async def test_if_else_with_compare(self):
        for val, want in ((5, "много"), (1, "мало")):
            nodes = [node("e", "event.manual@1"), node("c", "data.compare_number@1", a=val, op=">", b=3), node("i", "logic.if@1"),
                     node("t", "action.notify@1", title="много"), node("f", "action.notify@1", title="мало")]
            w = [wire("e", "exec", "i", "exec_in"), wire("c", "result", "i", "condition"), wire("i", "then", "t", "exec_in"),
                 wire("i", "else", "f", "exec_in")]
            self.add(make_cmd("if%d" % val, nodes, w))
            res = await self.rt.engine.run("if%d" % val)
            self.assertEqual(res["status"], "ok", res)
            self.assertEqual(self.env.lines("notify.log")[-1], "-a Serpantinum -- " + want)

    def loop_cmd(self, name, with_break_at=None, items=("a", "b", "c", "d")):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=list(items)), node("n", "action.notify@1"),
                 node("done", "action.notify@1", title="конец"), node("inc", "logic.increment@1", name="n", by=1)]
        w = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "inc", "exec_in"), wire("inc", "exec_out", "n", "exec_in"),
             wire("f", "item", "n", "title"), wire("f", "completed", "done", "exec_in")]
        if with_break_at is not None:
            nodes += [node("cmp", "data.compare_number@1", b=with_break_at, op="=="), node("i", "logic.if@1"), node("br", "logic.break@1")]
            w = [x for x in w if x != wire("inc", "exec_out", "n", "exec_in")]
            w += [wire("inc", "exec_out", "i", "exec_in"), wire("inc", "value", "cmp", "a"), wire("cmp", "result", "i", "condition"),
                  wire("i", "then", "br", "exec_in"), wire("i", "else", "n", "exec_in")]
        return make_cmd(name, nodes, w, variables=[{"name": "n", "type": "int"}])

    async def test_increment_counts_per_run_and_resets(self):
        self.add(self.loop_cmd("cnt"))
        for _ in range(2):                                    # variables are scoped per run: the second run starts at 0 again
            res = await self.rt.engine.run("cnt")
            self.assertEqual(res["status"], "ok", res)
            incs = [s["out"]["value"] for s in res["steps"] if s["type"] == "logic.increment@1"]
            self.assertEqual(incs, [1, 2, 3, 4])

    async def test_break_leaves_loop_and_runs_completed(self):
        self.add(self.loop_cmd("brk", with_break_at=3))
        res = await self.rt.engine.run("brk")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- a", "-a Serpantinum -- b", "-a Serpantinum -- конец"])

    async def test_break_only_stops_the_inner_loop(self):
        nodes = [node("e", "event.manual@1"), node("o", "logic.foreach@1", list=["x", "y"]), node("i", "logic.foreach@1", list=[1, 2, 3]),
                 node("br", "logic.break@1"), node("n", "action.notify@1")]
        w = [wire("e", "exec", "o", "exec_in"), wire("o", "body", "i", "exec_in"), wire("i", "body", "br", "exec_in"),
             wire("i", "completed", "n", "exec_in"), wire("o", "item", "n", "title")]
        self.add(make_cmd("nest", nodes, w))
        res = await self.rt.engine.run("nest")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- x", "-a Serpantinum -- y"])

    async def test_increment_float_and_persist(self):
        nodes = [node("e", "event.manual@1"), node("a", "logic.increment@1", name="p", by=2.5)]
        self.add(make_cmd("incf", nodes, [wire("e", "exec", "a", "exec_in")], variables=[{"name": "p", "type": "float", "scope": "persist"}]))
        await self.rt.engine.run("incf")
        res = await self.rt.engine.run("incf")
        self.assertEqual(res["steps"][-1]["out"]["value"], 5.0)


class AskTests(C.Base):
    async def run_ask(self, cmd, *answers):
        ui = ScriptedUi(*answers)
        self.runtime(ui=ui)
        self.add(cmd)
        res = await self.rt.engine.run(cmd["id"])
        self.assertEqual(res["status"], "ok", res)
        return ui, [l.replace("-a Serpantinum -- ", "") for l in self.env.lines("notify.log")]

    async def test_choice_answer(self):
        ui, notes = await self.run_ask(ask_cmd("c1", options=["A", "B"], title="Что?"), {"index": 1})
        self.assertEqual(notes, ["ok"])
        kind, payload, timeout = ui.requests[0]
        self.assertEqual((kind, payload["mode"], payload["options"], payload["title"]), ("ask", "choice", ["A", "B"], "Что?"))
        self.assertEqual(timeout, 120)

    async def test_choice_text_number_confirm_outputs(self):
        for mode, props, answer, expect in (
                ("choice", {"options": ["A", "B"]}, {"index": 1}, ("B", 0.0, 1, False)),
                ("text", {}, {"value": "привет"}, ("привет", 0.0, -1, False)),
                ("number", {}, {"value": "2,5"}, ("2.5", 2.5, -1, False)),
                ("confirm", {}, {"answer": True}, ("да", 0.0, -1, True))):
            cmd = ask_cmd("m-" + mode, mode=mode, **props)
            cmd["nodes"] = [n for n in cmd["nodes"] if n["id"] != "ok"]
            cmd["wires"] = [x for x in cmd["wires"] if x["to"][0] != "ok"]
            ui = ScriptedUi(answer)
            self.runtime(ui=ui)
            self.add(cmd)
            res = await self.rt.engine.run(cmd["id"])
            self.assertEqual(res["status"], "ok", res)
            out = next(s for s in res["steps"] if s["type"] == "logic.ask@1")["out"]
            self.assertEqual((out["text"], out["number"], out["index"], out["yes"]), expect)

    async def test_cancel_and_timeout_paths(self):
        _, notes = await self.run_ask(ask_cmd("c2", options=["A"]), {"cancel": True})
        self.assertEqual(notes, ["cancel"])
        self.env.write_fake("notify.log", "")
        _, notes = await self.run_ask(ask_cmd("c3", options=["A"]), None)
        self.assertEqual(notes, ["timeout"])

    async def test_bad_answers_stop_with_russian_errors(self):
        for cmd, ans, text in ((ask_cmd("b1", mode="number"), {"value": "abc"}, "не похож на число"),
                               (ask_cmd("b2", options=["A"]), {"index": 9}, "неизвестный вариант")):
            self.runtime(ui=ScriptedUi(ans))
            self.add(cmd)
            res = await self.rt.engine.run(cmd["id"])
            self.assertEqual(res["status"], "err")
            self.assertIn(text, res["message"])

    async def test_dry_run_does_not_ask(self):
        ui = ScriptedUi({"index": 0})
        self.runtime(ui=ui)
        cmd = ask_cmd("dry", options=["A", "B"], default="B")
        self.add(cmd)
        res = await self.rt.engine.run("dry", dry_run=True)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(ui.requests, [])

    async def test_cancelling_the_run_while_waiting_for_an_answer(self):
        class Hang:
            async def request(self, kind, payload, timeout=3.0):
                await asyncio.sleep(30)
        self.runtime(ui=Hang())
        self.add(ask_cmd("hang", options=["A"]))
        t = asyncio.ensure_future(self.rt.engine.run("hang"))
        await asyncio.sleep(0.1)
        rid = next(iter(self.rt.engine.active))
        self.assertTrue(self.rt.engine.cancel(rid))
        res = await t
        self.assertEqual(res["status"], "cancelled")


class WaitEventTests(C.Base):
    def wait_cmd(self, name="w", **props):
        nodes = [node("e", "event.manual@1"), node("w", "logic.wait_event@1", **props),
                 node("ok", "action.notify@1", title="пришло"), node("to", "action.notify@1", title="время вышло")]
        w = [wire("e", "exec", "w", "exec_in"), wire("w", "exec_out", "ok", "exec_in"), wire("w", "timed_out", "to", "exec_in"),
             wire("w", "detail", "ok", "body")]
        return make_cmd(name, nodes, w)

    async def asyncSetUp(self):
        self.runtime()
        self.eng = self.rt.engine

    async def start(self, cmd):
        self.add(cmd)
        t = asyncio.ensure_future(self.eng.run(cmd["id"]))
        for _ in range(50):
            await asyncio.sleep(0.01)
            if self.eng.waiters.items:
                break
        self.assertTrue(self.eng.waiters.items, "the run should be suspended")
        return t

    async def test_event_resumes_the_run(self):
        t = await self.start(self.wait_cmd(event="window.open", match="fox", timeout=30))
        self.assertEqual(self.eng.deliver_event({"type": "window.open", "data": {"class": "kitty", "title": "x"}}), 0)
        self.assertFalse(t.done())
        self.assertEqual(self.eng.deliver_event({"type": "window.open", "data": {"class": "firefox", "title": "x"}}), 1)
        res = await asyncio.wait_for(t, 5)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- пришло class=firefox, title=x"])
        self.assertEqual(self.eng.waiters.items, [])

    async def test_timeout_pin(self):
        res = await asyncio.wait_for(self.eng.run(self.add(self.wait_cmd(event="workspace", timeout=0.1))["id"]), 5)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- время вышло"])
        self.assertEqual(self.eng.waiters.items, [])

    async def test_cancel_removes_the_waiter(self):
        t = await self.start(self.wait_cmd(event="workspace", timeout=30))
        self.eng.cancel(next(iter(self.eng.active)))
        res = await t
        self.assertEqual(res["status"], "cancelled")
        self.assertEqual(self.eng.waiters.items, [])

    async def test_wrong_event_type_is_ignored(self):
        t = await self.start(self.wait_cmd(event="workspace", timeout=30))
        self.eng.deliver_event({"type": "window.open", "data": {}})
        self.assertFalse(t.done())
        self.eng.deliver_event({"type": "workspace", "data": {"workspace": "2"}})
        self.assertEqual((await asyncio.wait_for(t, 5))["status"], "ok")

    async def test_dry_run_does_not_wait(self):
        self.add(self.wait_cmd(event="workspace", timeout=30))
        res = await asyncio.wait_for(self.eng.run("w", dry_run=True), 5)
        self.assertEqual(res["status"], "ok")


class WaitViaTriggerManager(C.Base):
    """`cmd emit` goes through TriggerManager.on_event: the waiting run must wake up, and the source runs only while someone waits."""

    async def test_emit_wakes_waiter_and_source_follows_the_wait(self):
        self.runtime()
        src = FakeSource("hyprland", ("window.open", "window.close", "workspace", "monitor.added", "monitor.removed"))
        mgr = TR.TriggerManager(self.rt.engine, self.clock, sources={"hyprland": src}, refresh_delay=0.01)
        await mgr.start()
        self.assertEqual(src.started, 0)
        cmd = WaitEventTests.wait_cmd(self, "wm", event="window.open", timeout=30)
        self.add(cmd)
        t = asyncio.ensure_future(self.rt.engine.run("wm"))
        await asyncio.sleep(0.2)
        self.assertEqual((src.started, src.stopped), (1, 0))             # started because of the wait
        await mgr.on_event({"type": "window.open", "data": {"class": "kitty", "title": "t"}})
        res = await asyncio.wait_for(t, 5)
        self.assertEqual(res["status"], "ok", res)
        await asyncio.sleep(0.2)
        self.assertEqual(src.stopped, 1)                                 # nobody waits any more
        await mgr.stop()


class ProtocolAsk(DaemonCase):
    def ask_run(self, mode="choice", **props):
        cmd = ask_cmd("pa", mode=mode, **props)
        self.add(cmd)
        return cmd

    async def serve(self, ui, answer):
        def serve():
            ev = next(e for e in ui.events() if e.get("ev") == "ui.request")
            if answer is not None:
                ui.sock.sendall((json.dumps({"id": 7, "method": "ui_response", "params": dict(answer, id=ev["id"])}) + "\n").encode())
            return ev
        return asyncio.ensure_future(asyncio.to_thread(serve))

    async def test_ask_roundtrip_through_ui_response(self):
        self.ask_run(options=["A", "B"], title="Выбор")
        ui, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(ui, "subscribe", topics=["ui"])
        t = await self.serve(ui, {"index": 0})
        res = await self.call(runner, "run", ref="pa")
        ev = await asyncio.wait_for(t, 10)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual((ev["kind"], ev["payload"]["title"], ev["payload"]["options"]), ("ask", "Выбор", ["A", "B"]))
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- ok"])

    async def test_ask_cancel_from_the_shell(self):
        self.ask_run(options=["A"])
        ui, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(ui, "subscribe", topics=["ui"])
        t = await self.serve(ui, {"cancel": True})
        await self.call(runner, "run", ref="pa")
        await asyncio.wait_for(t, 10)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- cancel"])

    async def test_timeout_tells_the_shell_to_close_the_dialog(self):
        self.ask_run(options=["A"], timeout=1)
        ui, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(ui, "subscribe", topics=["ui"])

        def collect():
            out = []
            for e in ui.events():
                out.append(e)
                if e.get("ev") == "ui.cancel":
                    return out
        t = asyncio.ensure_future(asyncio.to_thread(collect))
        await self.call(runner, "run", ref="pa")
        evs = await asyncio.wait_for(t, 10)
        self.assertEqual([e["ev"] for e in evs], ["ui.request", "ui.cancel"])
        self.assertEqual(evs[0]["id"], evs[1]["id"])
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- timeout"])

    async def test_no_shell_connected_takes_the_timeout_path(self):
        self.ask_run(options=["A"])
        runner = self.new_client()
        await self.call(runner, "reload")
        await self.call(runner, "run", ref="pa")
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- timeout"])


class ValidationTests(unittest.TestCase):
    def test_break_outside_a_loop(self):
        cmd = make_cmd("v", [node("e", "event.manual@1"), node("b", "logic.break@1")], [wire("e", "exec", "b", "exec_in")])
        self.assertIn("break_outside_loop", codes(cmd))
        msg = validate(cmd, SCH)["errors"][0]["message"]
        self.assertIn("вне цикла", msg)

    def test_choice_without_options(self):
        cmd = make_cmd("v", [node("e", "event.manual@1"), node("a", "logic.ask@1", mode="choice")], [wire("e", "exec", "a", "exec_in")])
        self.assertIn("choice_no_options", codes(cmd))

    def test_increment_needs_a_number_variable(self):
        cmd = make_cmd("v", [node("e", "event.manual@1"), node("a", "logic.increment@1", name="s")], [wire("e", "exec", "a", "exec_in")],
                       variables=[{"name": "s", "type": "text"}])
        self.assertIn("var_not_number", codes(cmd))

    def test_type_mismatch_offers_the_converter(self):
        nodes = [node("e", "event.manual@1"), node("r", "data.range@1", count=3), node("n", "action.notify@1"), node("l", "data.list_length@1")]
        cmd = make_cmd("v", nodes, [wire("e", "exec", "n", "exec_in"), wire("r", "list", "l", "list"), wire("l", "length", "n", "title")])
        rep = validate(cmd, SCH)
        self.assertIn("type_mismatch", [i["code"] for i in rep["errors"]])
        err = next(i for i in rep["errors"] if i["code"] == "type_mismatch")
        self.assertEqual(err["fix"]["node_type"], "convert.to_text@1")
        self.assertIn("Вставить", err["fix"]["label"])

    def test_missing_required_pin_and_unreachable_node(self):
        nodes = [node("e", "event.manual@1"), node("i", "logic.if@1"), node("n", "action.notify@1", title="x"), node("lone", "action.notify@1", title="y")]
        cmd = make_cmd("v", nodes, [wire("e", "exec", "i", "exec_in"), wire("i", "then", "n", "exec_in")])
        self.assertIn("missing_input", codes(cmd))
        self.assertIn("unreachable", codes(cmd, "warnings"))

    def loop(self, size_nodes, body_extra=(), wires_extra=()):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1"), node("n", "action.notify@1", title="t")] + list(size_nodes) + list(body_extra)
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in")] + list(wires_extra)
        return make_cmd("v", nodes, wires)

    def test_long_loop_without_pause_warns(self):
        cmd = self.loop([node("r", "data.range@1", count=500)], wires_extra=[wire("r", "list", "f", "list")])
        self.assertIn("loop_no_delay", codes(cmd, "warnings"))
        self.assertIn("без паузы", next(i for i in validate(cmd, SCH)["warnings"] if i["code"] == "loop_no_delay")["message"])

    def test_loop_with_a_delay_or_a_short_list_is_quiet(self):
        cmd = self.loop([node("r", "data.range@1", count=500), node("d", "logic.delay@1", seconds=1)],
                        wires_extra=[wire("r", "list", "f", "list"), wire("n", "exec_out", "d", "exec_in")])
        self.assertNotIn("loop_no_delay", codes(cmd, "warnings"))
        short = self.loop([node("r", "data.range@1", count=5)], wires_extra=[wire("r", "list", "f", "list")])
        self.assertNotIn("loop_no_delay", codes(short, "warnings"))

    def test_wait_longer_than_the_run_limit_warns(self):
        cmd = make_cmd("v", [node("e", "event.manual@1"), node("w", "logic.wait_event@1", timeout=5000)], [wire("e", "exec", "w", "exec_in")],
                       policy={"timeout_s": 60})
        self.assertIn("wait_too_long", codes(cmd, "warnings"))

    def test_wait_event_needs_trigger_capabilities_but_ask_and_show_result_do_not(self):
        self.assertEqual(SCH.nodes["logic.ask"].capabilities, [])
        self.assertEqual(SCH.nodes["ui.show_result"].capabilities, [])
        self.assertEqual(SCH.nodes["logic.wait_event"].capabilities, ["trigger.windows", "trigger.session"])

    def test_examples_validate_cleanly(self):
        self.assertGreaterEqual(len(EXAMPLES), 6)
        used = set()
        for f in EXAMPLES:
            cmd = json.load(open(f, encoding="utf-8"))
            rep = validate(cmd, SCH)
            self.assertEqual((rep["errors"], rep["warnings"]), ([], []), f)
            used |= {n["type"].split("@")[0] for n in cmd["nodes"]}
        self.assertTrue({"logic.ask", "logic.if", "logic.foreach", "logic.wait_event", "logic.break"} <= used)


if __name__ == "__main__":
    unittest.main()
