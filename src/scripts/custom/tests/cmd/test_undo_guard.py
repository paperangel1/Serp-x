import asyncio
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd
from xcmd import clock as xclock
from xcmd.daemon import Daemon
from xcmd.state import State, UndoStore


def clip_cmd(name, restore="end", after=None, **extra):
    nodes = [node("e", "event.manual@1"), node("c", "action.clipboard_set@1", text="новое", restore=restore)]
    wires = [wire("e", "exec", "c", "exec_in")]
    for i, n in enumerate(after or []):
        nodes.append(n)
        prev = "c" if i == 0 else after[i - 1]["id"]
        wires.append(wire(prev, "exec_out", n["id"], "exec_in"))
    return make_cmd(name, nodes, wires, **extra)


class UndoTests(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.env.write_fake("clipboard.txt", "прежнее")

    def clipboard(self):
        return self.env.read("clipboard.txt")

    async def test_restore_end_puts_the_old_value_back(self):
        self.add(clip_cmd("clip"))
        res = await self.rt.engine.run("clip")
        self.assertEqual((res["status"], res["undone"]), ("ok", 1))
        self.assertEqual(self.clipboard(), "прежнее")
        self.assertTrue(res["steps"][-1].get("rollback"))

    async def test_default_is_off_so_the_new_value_stays(self):
        cmd = clip_cmd("clip2")
        del cmd["nodes"][1]["props"]["restore"]
        self.add(cmd)
        res = await self.rt.engine.run("clip2")
        self.assertEqual((res["status"], res["undone"]), ("ok", 0))
        self.assertEqual(self.clipboard(), "новое")

    async def test_failure_after_the_change_rolls_back(self):
        self.env.write_fake("notify.rc", "3")
        self.add(clip_cmd("clipfail", after=[node("n", "action.notify@1", title="x")]))
        res = await self.rt.engine.run("clipfail")
        self.assertEqual((res["status"], res["reason"], res["undone"]), ("rolled_back", "node_error", 1))
        self.assertEqual(self.clipboard(), "прежнее")

    async def test_empty_clipboard_is_restored_as_empty(self):
        os.remove(os.path.join(self.env.fake, "clipboard.txt"))
        self.add(clip_cmd("clipempty"))
        await self.rt.engine.run("clipempty")
        self.assertFalse(os.path.exists(os.path.join(self.env.fake, "clipboard.txt")))

    async def test_undo_stack_is_persisted_while_the_run_is_active(self):
        seen = {}
        undo = UndoStore(self.env.state)

        def look():
            seen["files"] = os.listdir(undo.dir) if os.path.isdir(undo.dir) else []
            if seen["files"]:
                with open(os.path.join(undo.dir, seen["files"][0]), encoding="utf-8") as f:
                    seen["data"] = json.load(f)

        self.rt = self.runtime(clock=C.CbClock(look))
        self.add(clip_cmd("persist", after=[node("d", "logic.delay@1", seconds=1)]))
        res = await self.rt.engine.run("persist")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(len(seen["files"]), 1)
        self.assertEqual(seen["data"]["entries"][0]["value"], {"text": "прежнее"})
        self.assertFalse(os.path.isdir(undo.dir) and os.listdir(undo.dir))      # removed when the run ended

    async def test_stale_stacks_are_discarded_on_daemon_start_and_logged(self):
        UndoStore(self.env.state).save("old-run", "some-cmd", [{"node": "c", "mode": "end", "value": {"text": "x"}}])
        d = Daemon(rt=self.rt, socket_path=self.env.sock)
        await d.start()
        await d.stop()
        entry = [e for e in self.rt.log.read() if e.get("ev") == "undo_discarded"][0]
        self.assertEqual((entry["run"], entry["cmd"], entry["entries"]), ("old-run", "some-cmd", 1))
        self.assertEqual(UndoStore(self.env.state).discard_stale(), [])
        self.assertEqual(self.clipboard(), "прежнее")                           # never replayed blindly


class UndoCancelTests(C.Base):
    use_fake_clock = False

    async def test_cancel_rolls_back_too(self):
        self.runtime()
        self.env.write_fake("clipboard.txt", "прежнее")
        self.add(clip_cmd("clipcancel", after=[node("d", "logic.delay@1", seconds=5)]))
        t = asyncio.ensure_future(self.rt.engine.run("clipcancel"))
        for _ in range(200):
            if self.env.read("clipboard.txt") == "новое":
                break
            await asyncio.sleep(0.01)
        self.rt.engine.cancel(next(iter(self.rt.engine.active)))
        res = await t
        self.assertEqual((res["status"], res["undone"]), ("rolled_back", 1))
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")

    async def test_daemon_stop_rolls_back_active_runs(self):
        self.runtime()
        self.env.write_fake("clipboard.txt", "прежнее")
        self.add(clip_cmd("clipstop", after=[node("d", "logic.delay@1", seconds=5)]))
        d = Daemon(rt=self.rt, socket_path=self.env.sock)
        await d.start()
        t = asyncio.ensure_future(self.rt.engine.run("clipstop"))
        for _ in range(200):
            if self.env.read("clipboard.txt") == "новое":
                break
            await asyncio.sleep(0.01)
        await d.stop()
        res = await t
        self.assertEqual(res["status"], "rolled_back")
        self.assertEqual(self.env.read("clipboard.txt"), "прежнее")


class IpcNodeTests(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    def dnd_cmd(self, restore="end"):
        nodes = [node("e", "event.manual@1"), node("d", "action.shell.dnd@1", enabled=True, restore=restore),
                 node("t", "logic.delay@1", seconds=1)]
        return make_cmd("dnd", nodes, [wire("e", "exec", "d", "exec_in"), wire("d", "exec_out", "t", "exec_in")])

    async def test_ipc_node_sets_and_restores_through_the_xcmd_target(self):
        seen = []
        self.rt = self.runtime(clock=C.CbClock(lambda: seen.append(self.env.read("ipc_Dnd").strip())))
        self.add(self.dnd_cmd())
        res = await self.rt.engine.run("dnd")
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(seen, ["true"])                          # while the delay ran, do-not-disturb was on
        self.assertEqual(self.env.read("ipc_Dnd").strip(), "false")   # restored to what getDnd reported before
        calls = self.env.lines("ipc.log")
        self.assertEqual(calls[0], "ipc call xcmd getDnd")
        self.assertIn("ipc call xcmd setDnd true", calls)

    async def test_missing_target_gives_a_clear_error(self):
        self.env.write_fake("ipc.fail", "1")
        self.add(self.dnd_cmd(restore="off"))
        res = await self.rt.engine.run("dnd")
        self.assertEqual(res["status"], "err")
        self.assertIn("«xcmd»", res["message"])

    async def test_capture_failure_stops_before_changing_anything(self):
        self.env.write_fake("ipc.fail", "1")
        self.add(self.dnd_cmd())
        res = await self.rt.engine.run("dnd")
        self.assertEqual(res["status"], "err")
        self.assertIn("запомнить прежнее значение", res["message"])
        self.assertNotIn("ipc call xcmd setDnd true", self.env.lines("ipc.log"))


class GuardTests(C.Base):
    async def asyncSetUp(self):
        extra = os.path.join(self.env.root, "extra-nodes")
        os.makedirs(extra)
        with open(os.path.join(extra, "t.json"), "w", encoding="utf-8") as f:
            json.dump({"nodes": [{
                "id": "event.test_ping", "version": 1, "category": "event", "flow": "event",
                "name": {"ru": "Тест", "en": "Test"}, "description": {"ru": "т", "en": "t"}, "example": {"ru": "т", "en": "t"},
                "inputs": [], "outputs": [{"id": "exec", "type": "exec"}], "source": {"emits": "test.ping"},
                "executor": {"kind": "builtin", "ref": "event"}, "capabilities": [], "changes_state": False}]}, f)
        os.environ["XCMD_EXTRA_NODES"] = extra
        self.addCleanup(os.environ.pop, "XCMD_EXTRA_NODES", None)
        self.runtime()

    def auto(self, name="auto", **extra):
        nodes = [node("e", "event.test_ping@1"), node("m", "event.manual@1"), node("n", "action.notify@1", title=name)]
        return make_cmd(name, nodes, [wire("e", "exec", "n", "exec_in"), wire("m", "exec", "n", "exec_in")], **extra)

    async def fire(self, name):
        cmd = self.rt.store.find(name)
        return await self.rt.engine.run(cmd, trigger="test.ping", start_node="e")

    async def test_sixth_trigger_in_a_minute_pauses_the_command_and_notifies(self):
        self.add(self.auto())
        results = [await self.fire("auto") for _ in range(5)]
        self.assertEqual([r["status"] for r in results], ["ok"] * 5)
        sixth = await self.fire("auto")
        self.assertEqual((sixth["status"], sixth["reason"]), ("skipped", "loop_guard"))
        self.assertTrue(self.rt.state.is_paused("auto"))
        self.assertIn("приостановлена", self.env.lines("notify.log")[-1])
        seventh = await self.fire("auto")
        self.assertEqual((seventh["status"], seventh["reason"]), ("skipped", "paused_cmd"))
        manual = await self.rt.engine.run("auto")                 # manual runs are never blocked by the pause
        self.assertEqual(manual["status"], "ok", manual)

    async def test_window_slides_and_resume_clears_the_pause(self):
        self.add(self.auto(policy={"max_runs_per_min": 2}))
        await self.fire("auto")
        await self.fire("auto")
        self.clock.advance(61)
        self.assertEqual((await self.fire("auto"))["status"], "ok")          # old hits expired
        await self.fire("auto")
        self.assertEqual((await self.fire("auto"))["reason"], "loop_guard")
        await self.rt.api.call("resume", {"ref": "auto"})
        self.assertFalse(self.rt.state.is_paused("auto"))
        self.assertEqual((await self.fire("auto"))["status"], "ok")

    async def test_global_pause_skips_automations_but_not_manual_runs(self):
        nodes = [node("e", "event.manual@1"), node("t", "event.test_ping@1"), node("n", "action.notify@1", title="x")]
        self.add(make_cmd("both", nodes, [wire("e", "exec", "n", "exec_in")]))
        await self.rt.api.call("pause", {})
        auto = await self.rt.engine.run(self.rt.store.find("both"), trigger="test.ping", start_node="t")
        self.assertEqual((auto["status"], auto["reason"]), ("skipped", "paused_all"))
        manual = await self.rt.engine.run("both")
        self.assertEqual(manual["status"], "ok", manual)
        self.assertTrue(State(self.env.state).paused_all)                     # persisted
        await self.rt.api.call("resume", {})
        self.assertFalse(State(self.env.state).paused_all)

    async def test_manual_runs_are_not_counted(self):
        self.add(hello_cmd())
        for _ in range(8):
            res = await self.rt.engine.run("hello")
            self.assertEqual(res["status"], "ok", res)
        self.assertFalse(self.rt.state.is_paused("hello"))

    async def test_pause_one_command_persists(self):
        self.add(self.auto())
        await self.rt.api.call("pause", {"ref": "auto"})
        self.assertEqual((await self.fire("auto"))["reason"], "paused_cmd")
        self.assertIn("auto", State(self.env.state).paused_cmds())


def hello_cmd():
    nodes = [node("e", "event.manual@1"), node("n", "action.notify@1", title="h")]
    return make_cmd("hello", nodes, [wire("e", "exec", "n", "exec_in")])


if __name__ == "__main__":
    unittest.main()
