import asyncio
import json
import os
import socket
import stat
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from xcmd.daemon import Daemon
from xcmd.protocol import Client, ClientError, ProtocolError, Server


def hello(name="hello"):
    nodes, wires = notify_chain("Привет")
    return make_cmd(name, nodes, wires)


class DaemonCase(C.Base):
    reload_every = 2.0

    async def asyncSetUp(self):
        self.runtime()
        self.d = Daemon(rt=self.rt, socket_path=self.env.sock, reload_every=self.reload_every)
        await self.d.start()
        self.addAsyncCleanup(self.d.stop)
        self.clients = []

    def new_client(self):
        c = Client(self.env.sock, timeout=10)
        c.connect()
        self.clients.append(c)
        self.addCleanup(c.close)
        return c

    async def call(self, c, method, **params):
        return await asyncio.to_thread(c.call, method, params)


class ProtocolTests(DaemonCase):
    async def test_socket_is_private(self):
        self.assertEqual(stat.S_IMODE(os.stat(self.env.sock).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.env.sock)).st_mode), 0o700)

    async def test_list_get_validate_run_log(self):
        self.add(hello())
        c = self.new_client()
        await self.call(c, "reload")
        lst = await self.call(c, "list")
        self.assertEqual([x["name"] for x in lst["commands"]], ["hello"])
        self.assertTrue(lst["commands"][0]["approved"])
        self.assertEqual((await self.call(c, "get", ref="hello"))["name"], "hello")
        self.assertTrue((await self.call(c, "validate", ref="hello"))["ok"])
        bad = await self.call(c, "validate", command={"name": "x", "nodes": [], "wires": []})
        self.assertIn("no_event", [i["code"] for i in bad["errors"]])
        res = await self.call(c, "run", ref="hello")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Привет"])
        log = await self.call(c, "log", n=5)
        self.assertEqual(log["runs"][-1]["name"], "hello")
        st = await self.call(c, "status")
        self.assertEqual((st["commands"], st["active"]), (1, []))

    async def test_errors_are_structured(self):
        c = self.new_client()
        with self.assertRaises(ClientError) as cm:
            await self.call(c, "nope")
        self.assertEqual(cm.exception.code, "unknown_method")
        with self.assertRaises(ClientError) as cm:
            await self.call(c, "get", ref="missing")
        self.assertEqual(cm.exception.code, "not_found")
        with self.assertRaises(ClientError) as cm:
            await self.call(c, "get")
        self.assertEqual(cm.exception.code, "bad_params")
        c.sock.sendall(b"this is not json\n")
        msg = await asyncio.to_thread(c._line)
        self.assertEqual(msg["error"]["code"], "bad_request")

    async def test_enable_disable_approve_pause_resume_save_import(self):
        self.add(hello(), approve=False)
        c = self.new_client()
        await self.call(c, "reload")
        self.assertFalse((await self.call(c, "list"))["commands"][0]["approved"])
        res = await self.call(c, "approve", ref="hello")
        self.assertEqual(res["approved_capabilities"], ["notify.show"])
        self.assertFalse((await self.call(c, "disable", ref="hello"))["enabled"])
        self.assertTrue((await self.call(c, "enable", ref="hello"))["enabled"])
        self.assertEqual((await self.call(c, "pause"))["paused_all"], True)
        self.assertEqual((await self.call(c, "resume"))["paused_all"], False)
        cmd = hello("fresh")
        saved = await self.call(c, "save", command=cmd)
        self.assertTrue(saved["report"]["ok"])
        self.assertTrue(os.path.exists(os.path.join(self.env.cmds, "fresh.cmd.json")))
        pkg = os.path.join(self.env.root, "pkg.scmd")
        with open(pkg, "w", encoding="utf-8") as f:
            json.dump(hello("shared"), f)
        imp = await self.call(c, "import", path=pkg)
        self.assertEqual((imp["command"], imp["enabled"]), ("shared", False))

    async def test_second_server_on_a_live_socket_is_refused_and_stale_files_are_replaced(self):
        other = Server(self.rt.api, self.rt.engine, self.d.ui, self.env.sock)
        with self.assertRaises(ProtocolError) as cm:
            await other.start()
        self.assertEqual(cm.exception.code, "already_running")
        await self.d.stop()
        s = socket.socket(socket.AF_UNIX)
        s.bind(self.env.sock)                    # a stale socket file nobody listens on
        s.close()
        d2 = Daemon(rt=self.rt, socket_path=self.env.sock)
        await d2.start()
        self.addAsyncCleanup(d2.stop)
        self.assertEqual((await self.call(self.new_client(), "status"))["commands"], 0)

    async def test_subscribers_receive_trace_and_run_events(self):
        self.add(hello())
        sub, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(sub, "subscribe", topics=["trace", "run"])

        def collect():
            out = []
            for ev in sub.events():
                out.append(ev)
                if ev.get("ev") == "run.end":
                    return out

        t = asyncio.ensure_future(asyncio.to_thread(collect))
        res = await self.call(runner, "run", ref="hello")
        evs = await asyncio.wait_for(t, 10)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(evs[0]["ev"], "run.start")
        self.assertEqual([e["node"] for e in evs if e["ev"] == "enter"], ["e", "n0"])
        pins = await self.call(runner, "pin_values", run=res["run"])
        self.assertIn("e.arg", pins)

    async def test_ui_requests_go_to_the_shell_and_answers_come_back(self):
        nodes = [node("e", "event.manual@1"), node("u", "ui.show_result@1", title="Итог", value="ответ")]
        self.add(make_cmd("show", nodes, [wire("e", "exec", "u", "exec_in")]))
        ui, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(ui, "subscribe", topics=["ui"])

        def serve():
            ev = next(e for e in ui.events() if e.get("ev") == "ui.request")
            ui.sock.sendall((json.dumps({"id": 99, "method": "ui_response", "params": {"id": ev["id"], "shown": True}}) + "\n").encode())
            return ev

        t = asyncio.ensure_future(asyncio.to_thread(serve))
        res = await self.call(runner, "run", ref="show")
        ev = await asyncio.wait_for(t, 10)
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual((ev["kind"], ev["payload"]), ("show", {"title": "Итог", "text": "ответ"}))
        self.assertEqual(self.env.lines("notify.log"), [])                   # shown in the shell, no fallback

    async def test_without_a_shell_connected_show_falls_back_to_a_notification(self):
        nodes = [node("e", "event.manual@1"), node("u", "ui.show_result@1", title="Итог", value="ответ")]
        self.add(make_cmd("show2", nodes, [wire("e", "exec", "u", "exec_in")]))
        c = self.new_client()
        await self.call(c, "reload")
        res = await self.call(c, "run", ref="show2")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Итог ответ"])

    async def test_confirmation_is_asked_in_the_shell(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="echo ok")]
        self.add(make_cmd("danger", nodes, [wire("e", "exec", "s", "exec_in")]))
        ui, runner = self.new_client(), self.new_client()
        await self.call(runner, "reload")
        await self.call(ui, "subscribe", topics=["ui"])

        def serve(answer):
            ev = next(e for e in ui.events() if e.get("ev") == "ui.request")
            ui.sock.sendall((json.dumps({"id": 98, "method": "ui_response", "params": {"id": ev["id"], "answer": answer}}) + "\n").encode())
            return ev["kind"]

        for answer, status in ((True, "ok"), (False, "err")):
            t = asyncio.ensure_future(asyncio.to_thread(serve, answer))
            res = await self.call(runner, "run", ref="danger")
            self.assertEqual(await asyncio.wait_for(t, 10), "confirm")
            self.assertEqual(res["status"], status, res)

    async def test_cancel_over_the_socket(self):
        self.use_fake_clock = False
        nodes = [node("e", "event.manual@1"), node("d", "logic.delay@1", seconds=5)]
        self.add(make_cmd("long", nodes, [wire("e", "exec", "d", "exec_in")]))
        a, b = self.new_client(), self.new_client()
        await self.call(a, "reload")
        self.rt.engine.clock = __import__("xcmd.clock", fromlist=["x"]).RealClock()
        t = asyncio.ensure_future(self.call(a, "run", ref="long"))
        for _ in range(200):
            if self.rt.engine.active:
                break
            await asyncio.sleep(0.01)
        rid = next(iter(self.rt.engine.active))
        self.assertTrue((await self.call(b, "cancel", run=rid))["cancelled"])
        self.assertEqual((await asyncio.wait_for(t, 10))["status"], "cancelled")


class ReloadTests(DaemonCase):
    reload_every = 0.05

    async def test_new_files_are_picked_up_without_a_restart(self):
        c = self.new_client()
        self.assertEqual((await self.call(c, "list"))["commands"], [])
        self.env.write_cmd(hello("late"))
        for _ in range(100):
            if (await self.call(c, "list"))["commands"]:
                break
            await asyncio.sleep(0.05)
        self.assertEqual([x["name"] for x in (await self.call(c, "list"))["commands"]], ["late"])


if __name__ == "__main__":
    unittest.main()
