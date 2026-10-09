"""Stage 7: trace stream schema, bounded trace ring, step/breakpoint gate, rehearsal (fake clock, fake answers, simulated
events, no side effects), secret redaction and the debug_* / trace protocol methods."""
import asyncio
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from test_protocol import DaemonCase
from xcmd import debug as D, runlog as RL

EV_KEYS = {"v", "seq", "ev", "run", "t"}


def loop_cmd(name="loop"):
    nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=["a", "b"]), node("n", "action.notify@1"),
             node("z", "action.notify@1", title="конец")]
    w = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "item", "n", "title"),
         wire("f", "completed", "z", "exec_in")]
    return make_cmd(name, nodes, w)


def branch_cmd(name="br"):
    nodes = [node("e", "event.manual@1"), node("i", "logic.if@1", condition=False), node("a", "action.notify@1", title="yes"),
             node("b", "action.notify@1", title="no")]
    w = [wire("e", "exec", "i", "exec_in"), wire("i", "then", "a", "exec_in"), wire("i", "else", "b", "exec_in")]
    return make_cmd(name, nodes, w)


def evs_of(rt, rid):
    return rt.engine.traces.get(rid)["events"]


class TraceSchema(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    async def test_every_event_has_the_common_fields_and_seq_grows(self):
        self.add(loop_cmd())
        res = await self.rt.engine.run("loop")
        evs = evs_of(self.rt, res["run"])
        self.assertTrue(all(EV_KEYS <= set(e) for e in evs), evs[:2])
        self.assertEqual([e["seq"] for e in evs], list(range(1, len(evs) + 1)))
        self.assertTrue(all(e["v"] == D.TRACE_VERSION for e in evs))

    async def test_loop_iteration_index_and_iter_marks(self):
        self.add(loop_cmd())
        res = await self.rt.engine.run("loop")
        evs = evs_of(self.rt, res["run"])
        self.assertEqual([(e["index"], e["total"]) for e in evs if e["ev"] == "iter"], [(0, 2), (1, 2)])
        body = [e for e in evs if e["ev"] == "enter" and e["node"] == "n"]
        self.assertEqual([e["iter"] for e in body], [[0], [1]])
        z = next(e for e in evs if e["ev"] == "enter" and e["node"] == "z")
        self.assertNotIn("iter", z)
        steps = [s for s in res["steps"] if s["node"] == "n"]
        self.assertEqual([s["iter"] for s in steps], [[0], [1]])

    async def test_exit_has_duration_exec_pin_and_wire(self):
        self.add(branch_cmd())
        res = await self.rt.engine.run("br")
        evs = evs_of(self.rt, res["run"])
        ex = next(e for e in evs if e["ev"] == "exit" and e["node"] == "i")
        self.assertEqual(ex["out_pin"], "else")
        self.assertIn("dur", ex)
        w = [e for e in evs if e["ev"] == "wire" and e.get("exec")]
        self.assertEqual(w[-1]["to"], ["b", "exec_in"])

    async def test_untaken_branch_is_reported_as_skip(self):
        self.add(branch_cmd())
        res = await self.rt.engine.run("br")
        sk = [e for e in evs_of(self.rt, res["run"]) if e["ev"] == "skip"]
        self.assertEqual([(e["node"], e["via"]) for e in sk], [("a", ["i", "then"])])

    async def test_error_event_has_message_node_and_inputs(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="exit 3")]
        self.add(make_cmd("bad", nodes, [wire("e", "exec", "s", "exec_in")]), approve=True)
        res = await self.rt.engine.run("bad", auto_confirm=True)
        self.assertEqual(res["status"], "err")
        er = next(e for e in evs_of(self.rt, res["run"]) if e["ev"] == "error")
        self.assertEqual(er["node"], "s")
        self.assertIn("код выхода 3", er["error"])
        self.assertEqual(er["pins"]["command"], "exit 3")
        self.assertEqual(self.rt.engine.traces.get(res["run"])["failed_node"], "s")

    async def test_variable_changes_are_traced(self):
        nodes = [node("e", "event.manual@1"), node("s", "logic.set_var@1", name="g", value="x")]
        self.add(make_cmd("v", nodes, [wire("e", "exec", "s", "exec_in")], variables=[{"name": "g", "type": "text", "initial": ""}]))
        res = await self.rt.engine.run("v")
        v = [e for e in evs_of(self.rt, res["run"]) if e["ev"] == "var"]
        self.assertEqual([(e["name"], e["value"]) for e in v], [("g", "x")])

    async def test_golden_event_sequence(self):
        self.add(branch_cmd())
        res = await self.rt.engine.run("br")
        got = [(e["ev"], e.get("node") or "") for e in evs_of(self.rt, res["run"])]
        self.assertEqual(got, [("enter", "e"), ("exit", "e"), ("wire", ""), ("enter", "i"), ("exit", "i"), ("skip", "a"),
                               ("wire", ""), ("enter", "b"), ("exit", "b")])


class Redaction(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    def test_text_redaction(self):
        for raw in ("curl -H 'Authorization: Bearer abcdef123456' x", "API_KEY=sk-abcdefghijklmnop1234", "password: hunter22 ok",
                    "AIzaSyA1234567890abcdefghijkl"):
            out = RL.redact_text(raw)
            self.assertIn("***", out)
            for secret in ("abcdef123456", "sk-abcdefghijklmnop1234", "hunter22", "AIzaSyA1234567890abcdefghijkl"):
                self.assertNotIn(secret, out)
        self.assertEqual(RL.redact_text("просто текст"), "просто текст")

    async def test_trace_pins_wires_and_plan_hide_secrets(self):
        nodes = [node("e", "event.manual@1"), node("t", "convert.to_text@1", value="token=SUPERSECRET1234"),
                 node("n", "action.notify@1")]
        w = [wire("e", "exec", "n", "exec_in"), wire("t", "text", "n", "title")]
        self.add(make_cmd("sec", nodes, w))
        res = await self.rt.engine.run("sec", rehearse=True)
        blob = json.dumps(self.rt.engine.traces.get(res["run"]), ensure_ascii=False) + json.dumps(res, ensure_ascii=False)
        self.assertNotIn("SUPERSECRET1234", blob)
        self.assertIn("***", blob)

    async def test_shell_error_text_is_redacted_in_trace(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="echo password=hunter22xx >&2; exit 2")]
        self.add(make_cmd("sh", nodes, [wire("e", "exec", "s", "exec_in")]))
        res = await self.rt.engine.run("sh", auto_confirm=True)
        blob = json.dumps(self.rt.engine.traces.get(res["run"]), ensure_ascii=False)
        self.assertNotIn("hunter22xx", blob)


class Ring(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.rt.engine.traces.keep = 3
        self.add(branch_cmd())

    async def test_only_last_runs_are_kept_in_memory_and_on_disk(self):
        ids = []
        for _ in range(5):
            ids.append((await self.rt.engine.run("br"))["run"])
        tr = self.rt.engine.traces
        self.assertEqual([r["run"] for r in tr.list()], ids[-3:])
        files = sorted(os.listdir(tr.dir))
        self.assertEqual(files, sorted(i + ".json" for i in ids[-3:]))
        self.assertIsNone(tr.get(ids[0]))

    async def test_trace_is_readable_from_disk_after_restart(self):
        rid = (await self.rt.engine.run("br"))["run"]
        fresh = D.TraceStore(self.rt.engine.traces.dir)
        self.assertEqual(fresh.get(rid)["status"], "ok")
        self.assertIsNone(fresh.get("../../etc/passwd"))

    async def test_event_cap_marks_truncated(self):
        tr = self.rt.engine.traces
        tr.max_events = 4
        rid = (await self.rt.engine.run("br"))["run"]
        rec = tr.get(rid)
        self.assertEqual((len(rec["events"]), rec["truncated"]), (4, True))


class StepGate(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.eng = self.rt.engine
        self.q = self.eng.events.subscribe(["trace"])

    async def paused(self, n=1):
        """Wait until the run publishes its n-th pause and return it."""
        seen = 0
        while True:
            ev = await asyncio.wait_for(self.q.get(), 5)
            if ev["ev"] == "pause":
                seen += 1
                if seen == n:
                    return ev

    async def test_step_mode_pauses_before_each_node(self):
        self.add(branch_cmd())
        t = asyncio.ensure_future(self.eng.run("br", step=True))
        p = await self.paused()
        self.assertEqual((p["node"], p["reason"]), ("e", "step"))
        rid = p["run"]
        self.assertEqual(self.eng.debug_state(rid)["state"], "paused")
        self.eng.debug_step(rid)
        self.assertEqual((await self.paused()).get("node"), "i")
        self.eng.debug_step(rid)
        self.assertEqual((await self.paused()).get("node"), "b")
        self.eng.debug_continue(rid)
        res = await asyncio.wait_for(t, 5)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- no"])

    async def test_breakpoint_in_a_loop_hits_every_iteration_then_continue(self):
        self.add(loop_cmd())
        t = asyncio.ensure_future(self.eng.run("loop", breakpoints=["n"]))
        p1 = await self.paused()
        self.assertEqual((p1["node"], p1["reason"], p1["iter"]), ("n", "breakpoint", [0]))
        self.eng.debug_continue(p1["run"])
        p2 = await self.paused()
        self.assertEqual(p2["iter"], [1])
        self.eng.debug_breakpoints(p1["run"], [])
        self.eng.debug_continue(p1["run"])
        res = await asyncio.wait_for(t, 5)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(len(self.env.lines("notify.log")), 3)

    async def test_stop_while_paused_cancels_the_run(self):
        self.add(branch_cmd())
        t = asyncio.ensure_future(self.eng.run("br", step=True))
        p = await self.paused()
        self.eng.debug_stop(p["run"])
        res = await asyncio.wait_for(t, 5)
        self.assertEqual(res["status"], "cancelled")
        self.assertEqual(self.env.lines("notify.log"), [])

    async def test_run_without_gate_rejects_debug_calls(self):
        self.add(branch_cmd())
        t = asyncio.ensure_future(self.eng.run("br", step=False, debug=True))
        res = await t
        from xcmd.errors import EngineError
        with self.assertRaises(EngineError):
            self.eng.debug_step(res["run"])        # finished: not active any more

    async def test_paused_run_ignores_the_run_timeout(self):
        cmd = branch_cmd()
        cmd["policy"] = {"timeout_s": 1}
        self.add(cmd)
        t = asyncio.ensure_future(self.eng.run("br", step=True))
        p = await self.paused()
        await asyncio.sleep(1.2)
        self.eng.debug_continue(p["run"])
        self.assertEqual((await asyncio.wait_for(t, 5))["status"], "ok")


def rehearsal_cmd():
    nodes = [node("e", "event.manual@1"), node("d", "logic.delay@1", seconds=30), node("n", "action.notify@1", title="Привет"),
             node("c", "action.clipboard_set@1", text="секрет-в-буфере"), node("s", "action.shell@1", command="echo hi"),
             node("a", "logic.ask@1", mode="choice", options=["Да", "Нет"], title="Точно?"),
             node("y", "action.notify@1", title="да"), node("no", "action.notify@1", title="нет")]
    w = [wire("e", "exec", "d", "exec_in"), wire("d", "exec_out", "n", "exec_in"), wire("n", "exec_out", "c", "exec_in"),
         wire("c", "exec_out", "s", "exec_in"), wire("s", "exec_out", "a", "exec_in"),
         wire("a", "exec_out", "y", "exec_in")]
    return make_cmd("reh", nodes, w)


class Rehearsal(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.eng = self.rt.engine

    async def test_no_side_effects_and_plans_are_logged(self):
        self.add(rehearsal_cmd())
        res = await self.eng.run("reh", rehearse=True)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), [])
        self.assertEqual(self.env.read("clip.log"), "")
        by = {s["node"]: s for s in res["steps"]}
        self.assertIn("показал бы уведомление «Привет»", by["n"]["plan"])
        self.assertIn("записал бы в буфер обмена 15 симв.", by["c"]["plan"])
        self.assertNotIn("секрет-в-буфере", json.dumps(res, ensure_ascii=False))
        self.assertIn("echo hi", by["s"]["plan"])
        self.assertTrue(res["rehearse"] and res["dry_run"])

    async def test_delay_is_fast_forwarded_by_a_fake_clock(self):
        self.add(rehearsal_cmd())
        res = await self.eng.run("reh", rehearse=True)
        self.assertEqual(self.clock.sleeps, [])           # the engine's own clock never slept
        d = next(s for s in res["steps"] if s["node"] == "d")
        self.assertEqual((d["fast_forward"], d["dur"]), (30.0, 30.0))
        self.assertEqual(res["dur"], 30.0)

    async def test_state_changing_node_shows_would_be_undo(self):
        nodes = [node("e", "event.manual@1"), node("c", "action.clipboard_set@1", text="x", restore="end")]
        self.add(make_cmd("u", nodes, [wire("e", "exec", "c", "exec_in")]))
        res = await self.eng.run("u", rehearse=True)
        c = next(s for s in res["steps"] if s["node"] == "c")
        self.assertIn("вернул бы прежнее значение", c.get("would_undo", ""))
        self.assertEqual(res["undone"], 0)
        self.assertEqual(self.rt.undo.discard_stale(), [])

    async def test_ask_uses_the_fake_answer_and_never_opens_a_dialog(self):
        ui = C.FakeUi({"index": 0})
        self.eng.ui = ui
        self.add(rehearsal_cmd())
        res = await self.eng.run("reh", rehearse={"answers": {"a": {"index": 1}}})
        self.assertEqual(ui.requests, [])
        a = next(s for s in res["steps"] if s["node"] == "a")
        self.assertEqual(a["out"]["text"], "Нет")
        res2 = await self.eng.run("reh", rehearse={})
        self.assertEqual(next(s for s in res2["steps"] if s["node"] == "a")["out"]["text"], "Да")

    async def test_simulated_event_feeds_wait_event_else_times_out_instantly(self):
        nodes = [node("e", "event.manual@1"), node("w", "logic.wait_event@1", event="window.open", timeout=60),
                 node("ok", "action.notify@1", title="пришло"), node("to", "action.notify@1", title="время вышло")]
        w = [wire("e", "exec", "w", "exec_in"), wire("w", "exec_out", "ok", "exec_in"), wire("w", "timed_out", "to", "exec_in")]
        self.add(make_cmd("we", nodes, w))
        res = await self.eng.run("we", rehearse={"events": [{"type": "window.open", "data": {"class": "firefox"}}]})
        self.assertEqual([s["node"] for s in res["steps"]], ["e", "w", "ok"])
        self.assertIn("подставлено", next(s for s in res["steps"] if s["node"] == "w")["simulated"])
        res2 = await self.eng.run("we", rehearse=True)
        self.assertEqual([s["node"] for s in res2["steps"]], ["e", "w", "to"])
        self.assertEqual(res2["dur"], 60.0)

    async def test_start_event_injection(self):
        nodes = [node("t", "event.app_opened@1"), node("n", "action.notify@1", title="окно")]
        self.add(make_cmd("tw", nodes, [wire("t", "exec", "n", "exec_in")]))
        start = self.eng.start_for_event(self.rt.store.find("tw"), "window.open")
        self.assertEqual(start, "t")
        res = await self.eng.run("tw", trigger="window.open", event={"type": "window.open", "data": {"class": "x"}},
                                 start_node=start, rehearse=True)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(res["trigger"], "window.open")

    async def test_rehearsal_is_deterministic(self):
        self.add(rehearsal_cmd())

        async def once():
            res = await self.eng.run("reh", rehearse={"answer": {"index": 1}})
            evs = json.loads(json.dumps(self.eng.traces.get(res["run"])["events"]))
            for e in evs:
                e.pop("run")
            steps = [{k: v for k, v in s.items()} for s in res["steps"]]
            return evs, steps, res["dur"]
        a = await once()
        self.clock.advance(1234)
        b = await once()
        self.assertEqual(a, b)

    async def test_rehearsal_ignores_pause_reentrancy_and_loop_guard(self):
        cmd = rehearsal_cmd()
        cmd["policy"] = {"max_runs_per_min": 1}
        self.add(cmd)
        self.rt.state.set_paused_all(True)
        for _ in range(3):
            res = await self.eng.run("reh", trigger="x.y", rehearse=True)
            self.assertEqual(res["status"], "ok", res)

    async def test_trace_marks_run_as_rehearsal(self):
        self.add(rehearsal_cmd())
        res = await self.eng.run("reh", rehearse=True)
        rec = self.eng.traces.get(res["run"])
        self.assertTrue(rec["rehearse"])
        self.assertTrue(any(e.get("plan") for e in rec["events"] if e["ev"] == "exit"))


class ProtocolDebug(DaemonCase):
    async def test_run_step_trace_and_log_filter_over_the_socket(self):
        self.add(branch_cmd())
        c, c2 = self.new_client(), self.new_client()
        await self.call(c, "reload")
        await self.call(c, "subscribe", topics=["trace", "run"])
        run_task = asyncio.ensure_future(self.call(c2, "run", ref="br", step=True))
        pause = None
        while pause is None:
            ev = await asyncio.wait_for(asyncio.to_thread(c.events().__next__), 5)
            if ev.get("ev") == "pause":
                pause = ev
        rid = pause["run"]
        st = await self.call(c, "debug_state", run=rid)
        self.assertEqual((st["state"], st["node"]), ("paused", "e"))
        await self.call(c, "debug_breakpoints", run=rid, nodes=["b"])
        await self.call(c, "debug_continue", run=rid)
        # the breakpoint on b stops it again
        for _ in range(50):
            await asyncio.sleep(0.05)
            st = await self.call(c, "debug_state", run=rid)
            if st["state"] == "paused":
                break
        self.assertEqual(st["node"], "b")
        await self.call(c, "debug_stop", run=rid)
        res = await asyncio.wait_for(run_task, 5)
        self.assertEqual(res["status"], "cancelled")
        tr = await self.call(c, "trace", run=rid)
        self.assertEqual(tr["status"], "cancelled")
        self.assertTrue(any(e["ev"] == "pause" and e["node"] == "b" for e in tr["events"]))
        last = await self.call(c, "trace", ref="br")
        self.assertEqual(last["run"], rid)
        lst = await self.call(c, "traces", ref="br")
        self.assertEqual([r["run"] for r in lst["runs"]], [rid])
        log = await self.call(c, "log", ref="br")
        self.assertTrue(log["runs"][0]["trace"])
        self.assertNotIn("steps", log["runs"][0])

    async def test_errors_for_unknown_run_and_missing_trace(self):
        c = self.new_client()
        from xcmd.protocol import ClientError
        for method in ("debug_step", "debug_state"):
            with self.assertRaises(ClientError) as cm:
                await self.call(c, method, run="nope")
            self.assertEqual(cm.exception.code, "no_run")
        with self.assertRaises(ClientError) as cm:
            await self.call(c, "trace", run="1-1")
        self.assertEqual(cm.exception.code, "no_trace")

    async def test_rehearse_over_the_socket_with_event(self):
        nodes = [node("t", "event.app_opened@1"), node("n", "action.notify@1", title="окно")]
        self.add(make_cmd("tw", nodes, [wire("t", "exec", "n", "exec_in")]))
        c = self.new_client()
        await self.call(c, "reload")
        res = await self.call(c, "run", ref="tw", rehearse=True, event={"type": "window.open", "data": {"class": "x"}})
        self.assertEqual((res["status"], res["trigger"]), ("ok", "window.open"))
        self.assertEqual(self.env.lines("notify.log"), [])
        from xcmd.protocol import ClientError
        with self.assertRaises(ClientError) as cm:
            await self.call(c, "run", ref="tw", rehearse=True, event={"type": "sun"})
        self.assertEqual(cm.exception.code, "no_start")


if __name__ == "__main__":
    unittest.main()
