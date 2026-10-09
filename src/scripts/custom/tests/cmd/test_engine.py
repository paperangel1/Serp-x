import asyncio
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from xcmd import clock as xclock


def hello(name="hello", title="Привет"):
    nodes, wires = notify_chain(title)
    return make_cmd(name, nodes, wires)


class EngineBasics(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    async def test_hello_runs_notify_and_logs(self):
        self.add(hello())
        res = await self.rt.engine.run("hello")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Привет"])
        entry = self.rt.log.tail(1)[0]
        self.assertEqual((entry["status"], entry["name"], entry["trigger"]), ("ok", "hello", "manual"))
        self.assertEqual([s["type"] for s in entry["steps"]], ["event.manual@1", "action.notify@1"])
        self.assertTrue(all(s["status"] == "ok" for s in entry["steps"]))

    async def test_variable_delay_and_pure_data(self):
        nodes = [node("e", "event.manual@1"), node("s", "logic.set_var@1", name="g", value="Здравствуйте"),
                 node("d", "logic.delay@1", seconds=0.2), node("n", "action.notify@1", body="после паузы"),
                 node("v", "data.get_var@1", name="g")]
        wires = [wire("e", "exec", "s", "exec_in"), wire("s", "exec_out", "d", "exec_in"), wire("d", "exec_out", "n", "exec_in"),
                 wire("v", "value", "n", "title")]
        self.add(make_cmd("delayed", nodes, wires, variables=[{"name": "g", "type": "text", "initial": "Привет"}]))
        res = await self.rt.engine.run("delayed")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.clock.sleeps, [0.2])
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Здравствуйте после паузы"])

    async def test_foreach_runs_body_per_item_then_completed(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=["a", "b", "c"]),
                 node("n", "action.notify@1"), node("c", "convert.to_text@1"), node("z", "action.notify@1", title="конец")]
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "item", "n", "title"),
                 wire("f", "index", "c", "value"), wire("c", "text", "n", "body"), wire("f", "completed", "z", "exec_in")]
        self.add(make_cmd("loop", nodes, wires))
        res = await self.rt.engine.run("loop")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- a 0", "-a Serpantinum -- b 1", "-a Serpantinum -- c 2",
                                                        "-a Serpantinum -- конец"])

    async def test_pure_memo_is_invalidated_between_iterations(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=[1, 2]),
                 node("s", "logic.set_var@1", name="n"), node("g", "data.get_var@1", name="n"),
                 node("t", "convert.to_text@1"), node("m", "action.notify@1")]
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "s", "exec_in"), wire("f", "item", "s", "value"),
                 wire("s", "exec_out", "m", "exec_in"), wire("g", "value", "t", "value"), wire("t", "text", "m", "title")]
        self.add(make_cmd("memo", nodes, wires, variables=[{"name": "n", "type": "int"}]))
        res = await self.rt.engine.run("memo")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- 1", "-a Serpantinum -- 2"])

    async def test_if_picks_the_branch(self):
        for text, expect in (("yes", "then"), ("", "else")):
            self.env.write_fake("notify.log", "")
            nodes = [node("e", "event.manual@1"), node("i", "logic.if@1"), node("a", "action.notify@1", title="then"),
                     node("b", "action.notify@1", title="else")]
            wires = [wire("e", "exec", "i", "exec_in"), wire("i", "then", "a", "exec_in"), wire("i", "else", "b", "exec_in")]
            nodes[1]["props"]["condition"] = bool(text)
            self.add(make_cmd("branch", nodes, wires))
            await self.rt.engine.run("branch")
            self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- " + expect])

    async def test_event_argument_flows_into_the_graph(self):
        nodes = [node("e", "event.manual@1"), node("n", "action.notify@1")]
        wires = [wire("e", "exec", "n", "exec_in"), wire("e", "arg", "n", "title")]
        self.add(make_cmd("arg", nodes, wires))
        res = await self.rt.engine.run("arg", args="из командной строки")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- из командной строки"])

    async def test_dry_run_has_no_side_effects(self):
        self.add(hello())
        res = await self.rt.engine.run("hello", dry_run=True)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.env.lines("notify.log"), [])
        self.assertTrue(any(s.get("dry_run") for s in res["steps"]))
        self.assertTrue(res["dry_run"])

    async def test_invalid_command_is_not_run(self):
        self.add(make_cmd("bad", [node("n", "action.notify@1", title="x")], []))
        res = await self.rt.engine.run("bad")
        self.assertEqual((res["status"], res["reason"]), ("invalid", "validation"))
        self.assertEqual(self.env.lines("notify.log"), [])
        self.assertEqual(res["errors"][0]["code"], "no_event")

    async def test_unknown_command(self):
        res = await self.rt.engine.run("nope")
        self.assertEqual((res["status"], res["reason"]), ("error", "not_found"))

    async def test_capabilities_must_be_approved(self):
        self.add(hello("unapproved"), approve=False)
        res = await self.rt.engine.run("unapproved")
        self.assertEqual((res["status"], res["reason"]), ("denied", "capabilities"))
        self.assertEqual(res["missing"], ["notify.show"])
        self.assertEqual(self.env.lines("notify.log"), [])
        dry = await self.rt.engine.run("unapproved", dry_run=True)
        self.assertEqual(dry["status"], "ok")           # a rehearsal does nothing, so it needs no approval
        ok = await self.rt.api.call("approve", {"ref": "unapproved"})
        self.assertEqual(ok["approved_capabilities"], ["notify.show"])
        res = await self.rt.engine.run("unapproved")
        self.assertEqual(res["status"], "ok", res)

    async def test_failed_tool_makes_the_run_fail(self):
        self.env.write_fake("notify.rc", "3")
        nodes, wires = notify_chain("a", "b")
        self.add(make_cmd("failing", nodes, wires))
        res = await self.rt.engine.run("failing")
        self.assertEqual((res["status"], res["reason"]), ("err", "node_error"))
        self.assertEqual(res["failed_node"], "n0")
        self.assertIn("notify-send", res["message"])
        self.assertEqual(len(self.env.lines("notify.log")), 1)          # the second node never ran

    async def test_on_error_continue_keeps_going(self):
        self.env.write_fake("notify.rc", "3")
        nodes = [node("e", "event.manual@1"), node("n", "action.notify@1", title="a", on_error="continue"),
                 node("d", "logic.delay@1", seconds=0.1)]
        wires = [wire("e", "exec", "n", "exec_in"), wire("n", "exec_out", "d", "exec_in")]
        self.add(make_cmd("cont", nodes, wires))
        res = await self.rt.engine.run("cont")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual([s["status"] for s in res["steps"]], ["ok", "err", "ok"])
        self.assertEqual(self.clock.sleeps, [0.1])

    async def test_to_int_failure_is_a_clear_error(self):
        nodes = [node("e", "event.manual@1"), node("c", "convert.to_int@1", text="abc"), node("d", "logic.delay@1")]
        wires = [wire("e", "exec", "d", "exec_in"), wire("c", "value", "d", "seconds")]
        self.add(make_cmd("conv", nodes, wires))
        res = await self.rt.engine.run("conv")
        self.assertEqual(res["status"], "err")
        self.assertIn("Не удалось превратить «abc» в число", res["message"])
        self.assertEqual(res["failed_node"], "c")

    async def test_int_literal_into_float_pin_is_coerced(self):
        nodes = [node("e", "event.manual@1"), node("d", "logic.delay@1", seconds=2)]
        self.add(make_cmd("coerce", nodes, [wire("e", "exec", "d", "exec_in")]))
        await self.rt.engine.run("coerce")
        self.assertEqual(self.clock.sleeps, [2.0])
        self.assertIsInstance(self.clock.sleeps[0], float)

    async def test_step_limit_stops_runaway_runs(self):
        self.rt.engine.max_steps = 3
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=list(range(10))), node("n", "action.notify@1", title="x")]
        self.add(make_cmd("many", nodes, [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in")]))
        res = await self.rt.engine.run("many")
        self.assertEqual((res["status"], res["reason"]), ("err", "max_steps"))

    async def test_trace_events_and_pin_history(self):
        q = self.rt.engine.events.subscribe(["trace", "run"])
        self.add(hello())
        res = await self.rt.engine.run("hello")
        evs = []
        while not q.empty():
            evs.append(q.get_nowait())
        kinds = [e["ev"] for e in evs]
        self.assertEqual(kinds[0], "run.start")
        self.assertEqual(kinds[-1], "run.end")
        self.assertEqual([e["node"] for e in evs if e["ev"] == "enter"], ["e", "n0"])
        self.assertIn("exit", kinds)
        wire_ev = [e for e in evs if e["ev"] == "wire" and e.get("exec")]
        self.assertEqual(wire_ev[0]["from"], ["e", "exec"])
        self.assertEqual(wire_ev[0]["to"], ["n0", "exec_in"])
        exit_n = next(e for e in evs if e["ev"] == "exit" and e["node"] == "n0")
        self.assertEqual(exit_n["pins"]["title"], "Привет")
        self.assertEqual(self.rt.engine.pin_values(res["run"])["e.arg"], [""])

    async def test_secret_and_clipboard_values_are_not_logged(self):
        nodes = [node("e", "event.manual@1"), node("c", "action.clipboard_set@1", text="пароль123")]
        self.add(make_cmd("clip", nodes, [wire("e", "exec", "c", "exec_in")]))
        res = await self.rt.engine.run("clip")
        logged = json.dumps(self.rt.log.tail(1), ensure_ascii=False)
        self.assertNotIn("пароль123", logged)
        self.assertIn("9 символов", logged)
        self.assertEqual(res["status"], "ok", res)

    async def test_long_values_are_truncated_in_the_log(self):
        nodes, wires = notify_chain("x" * 500)
        self.add(make_cmd("long", nodes, wires))
        await self.rt.engine.run("long")
        step = self.rt.log.tail(1)[0]["steps"][1]
        self.assertLessEqual(len(step["in"]["title"]), 200)
        self.assertTrue(step["in"]["title"].endswith("…"))

    async def test_run_log_prune_drops_old_entries(self):
        self.add(hello())
        await self.rt.engine.run("hello")
        self.clock.advance(31 * 86400)
        self.rt.log.prune()
        self.assertEqual(self.rt.log.read(), [])


class EngineDanger(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="echo привет; echo err >&2"),
                 node("n", "action.notify@1")]
        wires = [wire("e", "exec", "s", "exec_in"), wire("s", "exec_out", "n", "exec_in"), wire("s", "stdout", "n", "title")]
        self.add(make_cmd("shell", nodes, wires))

    async def test_needs_confirmation_and_none_means_cancelled(self):
        res = await self.rt.engine.run("shell")
        self.assertEqual(res["status"], "err")
        self.assertIn("нужно подтверждение", res["message"])
        self.assertEqual(self.env.lines("notify.log"), [])

    async def test_cli_yes_confirms_and_output_flows(self):
        res = await self.rt.engine.run("shell", auto_confirm=True)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- привет"])
        self.assertEqual(res["steps"][1]["out"]["exit_code"], 0)

    async def test_ui_answer_decides(self):
        ui = FakeUi = C.FakeUi(answer={"answer": True})
        self.rt.engine.ui = ui
        res = await self.rt.engine.run("shell")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(ui.requests[0][0], "confirm")
        self.assertIn("echo привет", ui.requests[0][1]["text"])
        self.rt.engine.ui = C.FakeUi(answer={"answer": False})
        res = await self.rt.engine.run("shell")
        self.assertEqual(res["status"], "err")

    async def test_dry_run_never_asks_or_runs(self):
        ui = C.FakeUi(answer=None)
        self.rt.engine.ui = ui
        res = await self.rt.engine.run("shell", dry_run=True)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(ui.requests, [])

    async def test_nonzero_exit_fails_with_stderr(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="echo oops >&2; exit 3")]
        self.add(make_cmd("fail", nodes, [wire("e", "exec", "s", "exec_in")]))
        res = await self.rt.engine.run("fail", auto_confirm=True)
        self.assertEqual(res["status"], "err")
        self.assertIn("код выхода 3", res["message"])
        self.assertIn("oops", res["message"])

    async def test_shell_timeout(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="sleep 5", timeout=1)]
        self.add(make_cmd("slow", nodes, [wire("e", "exec", "s", "exec_in")]))
        res = await self.rt.engine.run("slow", auto_confirm=True)
        self.assertEqual(res["status"], "err")
        self.assertIn("не уложилась", res["message"])
        self.assertLess(res["dur"], 4)

    async def test_shell_gets_a_trimmed_environment(self):
        os.environ["SECRET_TOKEN"] = "hunter2"
        self.addCleanup(os.environ.pop, "SECRET_TOKEN", None)
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command='echo "[$SECRET_TOKEN]"'),
                 node("n", "action.notify@1")]
        wires = [wire("e", "exec", "s", "exec_in"), wire("s", "exec_out", "n", "exec_in"), wire("s", "stdout", "n", "title")]
        self.add(make_cmd("env", nodes, wires))
        await self.rt.engine.run("env", auto_confirm=True)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- []"])


class EngineShowResult(C.Base):
    async def test_show_result_goes_to_ui_or_falls_back_to_notification(self):
        ui = C.FakeUi(answer={"shown": True})
        self.runtime(ui=ui)
        nodes = [node("e", "event.manual@1"), node("u", "ui.show_result@1", title="Итог", value=42)]
        self.add(make_cmd("show", nodes, [wire("e", "exec", "u", "exec_in")]))
        res = await self.rt.engine.run("show")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(ui.requests, [("show", {"title": "Итог", "text": "42"})])
        self.assertEqual(self.env.lines("notify.log"), [])
        ui.answer = None
        await self.rt.engine.run("show")
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Итог 42"])


class EngineAsync(C.Base):
    use_fake_clock = False

    async def asyncSetUp(self):
        self.runtime()

    def delay_cmd(self, name, seconds=5, **extra):
        nodes = [node("e", "event.manual@1"), node("d", "logic.delay@1", seconds=seconds), node("n", "action.notify@1", title=name)]
        return make_cmd(name, nodes, [wire("e", "exec", "d", "exec_in"), wire("d", "exec_out", "n", "exec_in")], **extra)

    async def wait_active(self, n=1):
        for _ in range(200):
            if len(self.rt.engine.active) >= n:
                return
            await asyncio.sleep(0.01)
        self.fail("run did not start")

    async def test_cancel_stops_a_waiting_run(self):
        self.add(self.delay_cmd("waiter"))
        t = asyncio.ensure_future(self.rt.engine.run("waiter"))
        await self.wait_active()
        rid = next(iter(self.rt.engine.active))
        self.assertTrue(self.rt.engine.cancel(rid))
        res = await t
        self.assertEqual((res["status"], res["reason"]), ("cancelled", "cancelled"))
        self.assertEqual(self.env.lines("notify.log"), [])
        self.assertFalse(self.rt.engine.cancel("nope"))

    async def test_run_timeout(self):
        self.add(self.delay_cmd("slowpoke", policy={"timeout_s": 0.2}))
        res = await self.rt.engine.run("slowpoke")
        self.assertEqual((res["status"], res["reason"]), ("err", "timeout"))
        self.assertLess(res["dur"], 2)

    async def test_reentrancy_skip(self):
        self.add(self.delay_cmd("once"))
        t = asyncio.ensure_future(self.rt.engine.run("once"))
        await self.wait_active()
        second = await self.rt.engine.run("once")
        self.assertEqual((second["status"], second["reason"]), ("skipped", "reentrancy"))
        await self.rt.engine.cancel_all()
        await t

    async def test_reentrancy_restart_cancels_the_first(self):
        self.add(self.delay_cmd("again", seconds=0.3, policy={"reentrancy": "restart"}))
        first = asyncio.ensure_future(self.rt.engine.run("again"))
        await self.wait_active()
        second = asyncio.ensure_future(self.rt.engine.run("again"))
        r1, r2 = await asyncio.gather(first, second)
        self.assertEqual(r1["status"], "cancelled")
        self.assertEqual(r2["status"], "ok", r2)

    async def test_reentrancy_queue_runs_one_after_another(self):
        self.add(self.delay_cmd("queued", seconds=0.2, policy={"reentrancy": "queue"}))
        a = asyncio.ensure_future(self.rt.engine.run("queued"))
        await self.wait_active()
        b = asyncio.ensure_future(self.rt.engine.run("queued"))
        ra, rb = await asyncio.gather(a, b)
        self.assertEqual((ra["status"], rb["status"]), ("ok", "ok"))
        self.assertGreaterEqual(rb["end"] - ra["end"], 0.15)

    async def test_reentrancy_parallel_limit(self):
        self.add(self.delay_cmd("par", seconds=0.3, policy={"reentrancy": "parallel", "parallel": 2}))
        tasks = [asyncio.ensure_future(self.rt.engine.run("par")) for _ in range(3)]
        res = await asyncio.gather(*tasks)
        self.assertEqual(sorted(r["status"] for r in res), ["ok", "ok", "skipped"])

    async def test_status_lists_active_runs(self):
        self.add(self.delay_cmd("busy"))
        t = asyncio.ensure_future(self.rt.engine.run("busy"))
        await self.wait_active()
        st = self.rt.engine.status()
        self.assertEqual(st["active"][0]["name"], "busy")
        await self.rt.engine.cancel_all()
        await t
        self.assertEqual(self.rt.engine.status()["active"], [])


class EngineEvents(C.Base):
    async def asyncSetUp(self):
        extra = os.path.join(self.env.root, "extra-nodes")
        os.makedirs(extra)
        with open(os.path.join(extra, "test.json"), "w", encoding="utf-8") as f:
            json.dump({"nodes": [{
                "id": "event.test_ping", "version": 1, "category": "event", "flow": "event",
                "name": {"ru": "Тест", "en": "Test"}, "description": {"ru": "т", "en": "t"}, "example": {"ru": "т", "en": "t"},
                "inputs": [], "outputs": [{"id": "exec", "type": "exec"},
                                          {"id": "text", "type": "text", "label": {"ru": "Текст", "en": "Text"}, "default": ""}],
                "source": {"emits": "test.ping"}, "executor": {"kind": "builtin", "ref": "event"},
                "capabilities": [], "changes_state": False}]}, f)
        os.environ["XCMD_EXTRA_NODES"] = extra
        self.addCleanup(os.environ.pop, "XCMD_EXTRA_NODES", None)
        self.runtime()

    async def test_dispatch_event_starts_listening_automations_with_event_data(self):
        nodes = [node("e", "event.test_ping@1"), node("n", "action.notify@1")]
        wires = [wire("e", "exec", "n", "exec_in"), wire("e", "text", "n", "title")]
        self.add(make_cmd("auto", nodes, wires))
        self.add(hello("manual-only"))
        tasks = self.rt.engine.dispatch_event({"type": "test.ping", "data": {"text": "ping!"}})
        self.assertEqual(len(tasks), 1)
        res = (await asyncio.gather(*tasks))[0]
        self.assertEqual((res["status"], res["trigger"]), ("ok", "test.ping"))
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- ping!"])
        self.assertEqual(self.rt.engine.dispatch_event({"type": "other"}), [])

    async def test_disabled_automations_ignore_events(self):
        nodes = [node("e", "event.test_ping@1"), node("n", "action.notify@1", title="x")]
        self.add(make_cmd("off", nodes, [wire("e", "exec", "n", "exec_in")], enabled=False))
        res = (await asyncio.gather(*self.rt.engine.dispatch_event({"type": "test.ping"})))[0]
        self.assertEqual((res["status"], res["reason"]), ("skipped", "disabled"))
        manual = nodes + []
        self.assertEqual(self.env.lines("notify.log"), [])


if __name__ == "__main__":
    unittest.main()
