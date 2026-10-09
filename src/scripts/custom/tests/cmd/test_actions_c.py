"""Stage 9c: bar, close window, open link, timer, screenshot and VPN action nodes.
Every external tool is a fake binary on PATH (the `serpantinum` stub below answers the xcmd / xvpn IPC targets and the screenshot
tool, hyprctl / xdg-open / wl-paste come from tests/cmd/common.py or are stubbed here); nothing touches the real desktop, VPN or systemd."""
import glob
import json
import os
import stat

import common as C
from common import node, wire, make_cmd
from test_actions import ActBase

SERP = r'''#!/bin/sh
printf "%s\n" "$*" >> "$FAKE_DIR/ipc.log"
[ -f "$FAKE_DIR/ipc.fail" ] && exit 1
F="$FAKE_DIR"
if [ "$1" = screenshot ]; then
  [ -f "$F/shot.rc" ] && exit "$(cat "$F/shot.rc")"
  d="$XDG_PICTURES_DIR/Screenshots"; mkdir -p "$d"; n=$(ls "$d" | wc -l)
  printf png > "$d/Screenshot_$n.png"
  printf shot > "$F/clipboard.txt"; printf "image/png\n" > "$F/types.txt"
  exit 0
fi
[ "$1" = ipc ] && [ "$2" = call ] || exit 2
t="$3"; fn="$4"; v="$5"
case "$t" in
 xcmd) case "$fn" in
   getBar) cat "$F/bar" 2>/dev/null || echo shown;;
   setBar) case "$v" in show|shown) echo shown > "$F/bar";; hide|hidden) echo hidden > "$F/bar";;
            toggle) if [ "$(cat "$F/bar" 2>/dev/null)" = hidden ]; then echo shown; else echo hidden; fi > "$F/bar";; esac;;
   getDnd) cat "$F/ipc_Dnd" 2>/dev/null || echo false;;
   setDnd) echo "$v" > "$F/ipc_Dnd";;
   *) exit 2;; esac;;
 xvpn) st=$(cat "$F/vpn_state" 2>/dev/null || echo off)
   case "$fn" in
   status) if [ -f "$F/vpn_unknown" ]; then rm -f "$F/vpn_unknown"; st=unknown; fi
     p=$(cat "$F/vpn_pending" 2>/dev/null || echo 0)
     if [ "$p" -gt 0 ]; then echo $((p-1)) > "$F/vpn_pending"; st=starting; fi
     happ=false; [ -f "$F/happ" ] && happ=true
     printf '{"state":"%s","node":"%s","reason":"%s","happ":%s}\n' "$st" "$(cat "$F/vpn_node" 2>/dev/null || echo Nord)" "$(cat "$F/vpn_reason" 2>/dev/null)" "$happ";;
   connect) if [ -f "$F/happ" ]; then echo "err:happ"; exit 0; fi
     [ -n "$v" ] && echo "$v" > "$F/vpn_node"
     if [ -f "$F/vpn_fail" ]; then echo failed > "$F/vpn_state"; echo start_failed > "$F/vpn_reason"; else echo on > "$F/vpn_state"; fi; echo ok;;
   disconnect) echo off > "$F/vpn_state"; echo ok;;
   switchTo) if [ "$st" != on ]; then echo "err:VPN выключен"; exit 0; fi; echo "$v" > "$F/vpn_node"; echo ok;;
   *) exit 2;; esac;;
 *) exit 2;;
esac
'''


class CBase(ActBase):
    async def asyncSetUp(self):
        self.runtime()
        self.sh("serpantinum", SERP[len("#!/bin/sh\n"):])
        self.pics = os.path.join(self.env.root, "Pictures")
        os.environ["XDG_PICTURES_DIR"] = self.pics
        self.addCleanup(os.environ.pop, "XDG_PICTURES_DIR", None)
        self.sh("xdg-open", 'printf "%s\\n" "$*" >> "$FAKE_DIR/open.log"\n[ -f "$FAKE_DIR/open.fail" ] && exit 3\nexit 0\n')

    def logtext(self):
        out = ""
        for p in glob.glob(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], "*.log")):
            with open(p, encoding="utf-8", errors="replace") as f:
                out += f.read()
        return out


class BarTests(CBase):
    async def test_hide_and_restore(self):
        res = await self.go("bar", [node("a", "action.shell.bar@1", mode="hide", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        calls = [l for l in self.env.lines("ipc.log") if "Bar" in l]
        self.assertEqual(calls, ["ipc call xcmd getBar", "ipc call xcmd setBar hide", "ipc call xcmd setBar shown"])
        self.assertEqual(self.env.read("bar").strip(), "shown")

    async def test_toggle_is_passed_on_and_shell_down_is_a_clear_error(self):
        res = await self.go("bar2", [node("a", "action.shell.bar@1", mode="toggle", restore="off")])
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.env.read("bar").strip(), "hidden")
        self.env.write_fake("ipc.fail", "1")
        res = await self.go("bar3", [node("a", "action.shell.bar@1", mode="show")])
        self.assertEqual(res["status"], "err")
        self.assertIn("не отвечает", res["message"])


CLIENTS = [{"address": "0x1", "class": "Slack", "title": "general", "mapped": True, "focusHistoryID": 2},
           {"address": "0x2", "class": "slack", "title": "dm", "mapped": True, "focusHistoryID": 0},
           {"address": "0x3", "class": "firefox", "title": "Slack docs", "mapped": True, "focusHistoryID": 1},
           {"address": "0x4", "class": "Slack", "title": "ghost", "mapped": False, "focusHistoryID": 3}]


class WindowCloseTests(CBase):
    def hypr(self):
        return [l for l in self.env.lines("hypr.log") if " dispatch " in l]

    async def test_active_window(self):
        self.env.write_fake("activewindow.json", json.dumps({"address": "0xaa", "class": "kitty"}))
        res = await self.go("wc", [node("a", "action.window.close@1", mode="active")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.hypr(), ["hyprctl dispatch closewindow address:0xaa"])
        self.assertEqual(res["steps"][-1]["out"]["closed"], 1)

    async def test_no_active_window_is_an_error(self):
        res = await self.go("wc2", [node("a", "action.window.close@1", mode="active")])
        self.assertEqual(res["status"], "err")
        self.assertIn("нет активного окна", res["message"])

    async def test_match_closes_the_most_recent_or_all(self):
        self.env.write_fake("clients.json", json.dumps(CLIENTS))
        res = await self.go("wc3", [node("a", "action.window.close@1", mode="match", class_filter="slack")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.hypr(), ["hyprctl dispatch closewindow address:0x2"])           # most recently used, case-insensitive
        res = await self.go("wc4", [node("a", "action.window.close@1", mode="match", class_filter="slack", all=True)])
        self.assertEqual(self.hypr()[1:], ["hyprctl dispatch closewindow address:0x2", "hyprctl dispatch closewindow address:0x1"])   # the unmapped one is skipped
        res = await self.go("wc5", [node("a", "action.window.close@1", mode="match", class_filter="slack", title_filter="dm", all=True)])
        self.assertEqual(res["steps"][-1]["out"]["closed"], 1)

    async def test_match_without_any_filter_is_refused(self):
        res = await self.go("wc6", [node("a", "action.window.close@1", mode="match")])
        self.assertEqual(res["status"], "err")
        self.assertEqual(self.hypr(), [])


class OpenLinkTests(CBase):
    async def test_http_https_mailto_open(self):
        for u in ("https://example.org/a?b=1", "http://example.org", "mailto:me@example.org"):
            res = await self.go("ol", [node("a", "action.open_link@1", url=u)])
            self.assertEqual(res["status"], "ok", (u, res))
        self.assertEqual(self.env.lines("open.log"), ["https://example.org/a?b=1", "http://example.org", "mailto:me@example.org"])
        log = self.logtext()
        self.assertNotIn("example.org", log)
        self.assertNotIn("a?b=1", log)

    async def test_other_schemes_and_junk_are_rejected_without_calling_xdg_open(self):
        for u in ("file:///etc/passwd", "javascript:alert(1)", "ftp://x.y/z", "steam://run/1", "-c evil", "https://a.b/ c", "https://", "example.org", ""):
            res = await self.go("ol2", [node("a", "action.open_link@1", url=u)])
            self.assertEqual(res["status"], "err", u)
        self.assertEqual(self.env.lines("open.log"), [])

    async def test_open_failure_is_reported(self):
        self.env.write_fake("open.fail", "1")
        res = await self.go("ol3", [node("a", "action.open_link@1", url="https://example.org")])
        self.assertEqual(res["status"], "err")
        self.assertIn("xdg-open", res["message"])


class TimerTests(CBase):
    def timer_cmd(self, seconds=10, restore=False, **props):
        nodes = [node("e", "event.manual@1"), node("t", "action.timer@1", seconds=seconds, name="Фокус", **props),
                 node("a", "action.notify@1", title="сразу"), node("f", "action.notify@1", title="после")]
        wires = [wire("e", "exec", "t", "exec_in"), wire("t", "exec_out", "a", "exec_in"), wire("t", "finished", "f", "exec_in")]
        if restore:
            nodes.insert(1, node("d", "action.shell.dnd@1", enabled=True, restore="end"))
            wires[0] = wire("e", "exec", "d", "exec_in")
            wires.insert(1, wire("d", "exec_out", "t", "exec_in"))
        return make_cmd("tm", nodes, wires, policy={"timeout_s": 5000})

    async def test_main_chain_goes_on_at_once_and_finished_fires_after_the_countdown(self):
        self.add(self.timer_cmd(25 * 60, notify_start=True))
        res = await self.rt.engine.run("tm")
        self.assertEqual(res["status"], "ok", res)
        notes = self.env.lines("notify.log")
        self.assertEqual([n.split("--")[-1].strip() for n in notes], ["Фокус Запущен: 25 мин 00 с", "сразу", "Фокус Время вышло", "после"])
        self.assertIn(1500.0, self.clock.sleeps)
        order = [s["node"] for s in res["steps"]]
        self.assertEqual(order, ["e", "t", "a", "f"])

    async def test_restores_run_after_the_timer_and_not_before(self):
        seen = []

        def cb():
            seen.append(self.env.read("ipc_Dnd").strip())
        self.runtime(clock=C.CbClock(cb))
        self.env.write_fake("ipc_Dnd", "false")
        self.add(self.timer_cmd(60, restore=True))
        res = await self.rt.engine.run("tm")
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(seen, ["true"])                       # while the countdown runs do-not-disturb is still on
        self.assertEqual(self.env.read("ipc_Dnd").strip(), "false")

    async def test_notifications_can_be_switched_off(self):
        self.add(self.timer_cmd(5, notify_end=False))
        res = await self.rt.engine.run("tm")
        self.assertEqual([n.split("--")[-1].strip() for n in self.env.lines("notify.log")], ["сразу", "после"])

    async def test_dry_run_does_not_start_it(self):
        self.add(self.timer_cmd(5))
        res = await self.rt.engine.run("tm", dry_run=True)
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.env.lines("notify.log"), [])
        self.assertNotIn(5.0, self.clock.sleeps)

    async def test_cancel_stops_the_timer(self):
        import asyncio
        self.use_fake_clock = False
        self.runtime()
        self.add(self.timer_cmd(300, notify_end=True))
        task = asyncio.ensure_future(self.rt.engine.run("tm"))
        await asyncio.sleep(0.3)
        await self.rt.engine.cancel_all()
        res = await task
        self.assertEqual(res["status"], "cancelled")
        self.assertNotIn("после", self.env.read("notify.log"))

    async def test_a_failing_branch_fails_the_run(self):
        cmd = self.timer_cmd(5)
        cmd["nodes"][3] = node("f", "action.open_link@1", url="file:///x")
        self.add(cmd)
        res = await self.rt.engine.run("tm")
        self.assertEqual(res["status"], "err")
        self.assertEqual(res["failed_node"], "f")

    async def test_long_timer_gets_the_wait_too_long_warning(self):
        from xcmd.validate import validate
        cmd = self.timer_cmd(1500)
        cmd["policy"] = {"timeout_s": 600}
        rep = validate(cmd, self.rt.sch)
        self.assertIn("wait_too_long", [w["code"] for w in rep["warnings"]])


class ScreenshotTests(CBase):
    def shots(self):
        return sorted(glob.glob(os.path.join(self.pics, "Screenshots", "*.png")))

    async def test_full_screen_returns_the_file(self):
        res = await self.go("ss", [node("a", "action.screenshot@1", mode="full")])
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("screenshot --full", self.env.lines("ipc.log"))
        self.assertEqual(res["steps"][-1]["out"]["path"], self.shots()[0])
        self.assertEqual(self.env.read("clipboard.txt"), "shot")             # the shell's tool copies it

    async def test_active_window_uses_its_geometry(self):
        self.env.write_fake("activewindow.json", json.dumps({"address": "0x1", "at": [10, 20], "size": [800, 600]}))
        res = await self.go("ss2", [node("a", "action.screenshot@1", mode="window")])
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("screenshot --geometry 10,20 800x600", self.env.lines("ipc.log"))

    async def test_area_with_and_without_geometry(self):
        res = await self.go("ss3", [node("a", "action.screenshot@1", mode="area", geometry="100,100 800x600")])
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("screenshot --geometry 100,100 800x600", self.env.lines("ipc.log"))
        res = await self.go("ss4", [node("a", "action.screenshot@1", mode="area")])
        self.assertEqual(res["status"], "ok")
        self.assertEqual(res["steps"][-1]["out"]["path"], "")                  # the overlay: the user picks, we do not know the file
        self.assertEqual(self.env.lines("ipc.log")[-1], "screenshot")
        res = await self.go("ss5", [node("a", "action.screenshot@1", mode="area", geometry="rm -rf /")])
        self.assertEqual(res["status"], "err")

    async def test_copy_off_puts_the_previous_text_back(self):
        self.env.write_fake("clipboard.txt", "my old text")
        self.env.write_fake("types.txt", "text/plain\n")
        res = await self.go("ss6", [node("a", "action.screenshot@1", mode="full", copy=False)])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("clipboard.txt"), "my old text")

    async def test_tool_failure_and_no_active_window(self):
        self.env.write_fake("shot.rc", "3")
        res = await self.go("ss7", [node("a", "action.screenshot@1", mode="full")])
        self.assertEqual(res["status"], "err")
        res = await self.go("ss8", [node("a", "action.screenshot@1", mode="window")])
        self.assertEqual(res["status"], "err")
        self.assertIn("активного окна", res["message"])


class VpnTests(CBase):
    def calls(self):
        return [l.split(" ", 3)[3] for l in self.env.lines("ipc.log") if l.startswith("ipc call xvpn")]

    async def test_on_waits_until_really_on_and_reports(self):
        self.env.write_fake("vpn_pending", "2")
        res = await self.go("v1", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("vpn_state").strip(), "on")
        out = res["steps"][-1]["out"]
        self.assertEqual((out["connected"], out["node_name"]), (True, "Nord"))
        self.assertEqual([c for c in self.calls() if not c.startswith("status")], ["connect "])

    async def test_on_with_a_node_and_switch(self):
        res = await self.go("v2", [node("a", "action.vpn.set@1", mode="on", node="Berlin")])
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("connect Berlin", self.calls())
        res = await self.go("v3", [node("a", "action.vpn.set@1", mode="switch", node="Paris")])
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("switchTo Paris", self.calls())
        self.assertEqual(self.env.read("vpn_node").strip(), "Paris")

    async def test_switch_needs_a_node_and_a_running_vpn(self):
        res = await self.go("v4", [node("a", "action.vpn.set@1", mode="switch")])
        self.assertEqual(res["status"], "err")
        res = await self.go("v5", [node("a", "action.vpn.set@1", mode="switch", node="Paris")])      # VPN is off
        self.assertEqual(res["status"], "err")
        self.assertIn("VPN выключен", res["message"])
        self.assertNotIn("switchTo Paris", self.calls())

    async def test_off_toggle_and_idempotence(self):
        self.env.write_fake("vpn_state", "on")
        res = await self.go("v6", [node("a", "action.vpn.set@1", mode="toggle")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("vpn_state").strip(), "off")
        res = await self.go("v7", [node("a", "action.vpn.set@1", mode="off")])
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.calls().count("disconnect"), 1)                # already off: not asked again
        res = await self.go("v8", [node("a", "action.vpn.set@1", mode="toggle")])
        self.assertEqual(self.env.read("vpn_state").strip(), "on")

    async def test_refuses_while_happ_is_active_and_never_touches_anything(self):
        self.env.write_fake("happ", "1")
        res = await self.go("v9", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "err")
        self.assertIn("Happ", res["message"])
        self.assertIn("не включится", res["message"])
        self.assertNotIn("connect ", self.calls())                             # the shell is not even asked
        self.assertEqual(self.env.read("vpn_state"), "")
        self.assertEqual(self.env.read("systemctl.log"), "")                   # no systemctl from the daemon, ever
        self.assertIn("happ_active", self.logtext())

    async def test_failure_of_the_module_is_explained(self):
        self.env.write_fake("vpn_fail", "1")
        res = await self.go("v10", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "err")
        self.assertIn("не удалось запустить", res["message"].lower())

    async def test_empty_status_is_asked_again_then_gives_up_clearly(self):
        self.env.write_fake("vpn_unknown", "1")
        res = await self.go("v11", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "ok", res)
        self.sh("serpantinum", 'echo \'{"state":"unknown"}\'\n')
        res = await self.go("v12", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "err")
        self.assertIn("не ответил", res["message"])

    async def test_undo_turns_it_back_and_off_is_restored_to_on(self):
        res = await self.go("v13", [node("a", "action.vpn.set@1", mode="on", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.env.read("vpn_state").strip(), "off")
        self.env.write_fake("vpn_state", "on")
        res = await self.go("v14", [node("a", "action.vpn.set@1", mode="off", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.env.read("vpn_state").strip(), "on")

    async def test_undo_never_fails_the_rollback_when_happ_appeared(self):
        self.env.write_fake("vpn_state", "on")
        cmd = self.cmd("v15", [node("a", "action.vpn.set@1", mode="off", restore="end"), node("b", "action.shell.dnd@1", enabled=True)])
        self.add(cmd)
        # Happ shows up between the node and the rollback: the restore is skipped quietly
        import xcmd.vpnapi as V
        real = V.connect

        async def happ_connect(ctx, node=""):
            self.env.write_fake("happ", "1")
            return await real(ctx, node)
        V.connect = happ_connect
        self.addCleanup(setattr, V, "connect", real)
        res = await self.rt.engine.run("v15")
        self.assertNotEqual(res["status"], "rolled_back")
        self.assertEqual(self.env.read("vpn_state").strip(), "off")

    async def test_goes_only_through_the_xvpn_ipc_target_and_logs_no_node_names(self):
        res = await self.go("v16", [node("a", "action.vpn.set@1", mode="on", node="SecretNodeName")])
        self.assertEqual(res["status"], "ok", res)
        for line in self.env.lines("ipc.log"):
            self.assertTrue(line.startswith("ipc call xvpn ") or line.startswith("ipc call xcmd "), line)
        self.assertNotIn("SecretNodeName", self.logtext())
        self.assertEqual(self.env.read("systemctl.log"), "")

    async def test_shell_down_is_a_clear_error(self):
        self.env.write_fake("ipc.fail", "1")
        res = await self.go("v17", [node("a", "action.vpn.set@1", mode="on")])
        self.assertEqual(res["status"], "err")
        self.assertIn("xvpn", res["message"])


class GalleryNodeCommands(CBase):
    """The two annotated gallery commands of stage 9c really work end to end (stubbed tools, fake clock)."""

    def load(self, name):
        from xcmd import gallery
        from xcmd.util import read_json
        cmd = gallery.localize(read_json(gallery.find(name)), "ru")
        cmd["id"], cmd["enabled"] = name, True
        return cmd

    async def test_unknown_wifi_turns_the_vpn_on_and_leaving_turns_it_off(self):
        cmd = self.load("wifi-vpn")
        self.add(cmd)
        res = await self.rt.engine.run("wifi-vpn", trigger="wifi.connected", event={"type": "wifi.connected", "ts": 1, "data": {"ssid": "CafeFree"}}, start_node="n1")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("vpn_state").strip(), "on")
        res = await self.rt.engine.run("wifi-vpn", trigger="wifi.disconnected", event={"type": "wifi.disconnected", "ts": 2, "data": {"ssid": "CafeFree"}}, start_node="n7")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("vpn_state").strip(), "off")

    async def test_trusted_wifi_leaves_the_vpn_alone(self):
        cmd = self.load("wifi-vpn")
        self.add(cmd)
        res = await self.rt.engine.run("wifi-vpn", trigger="wifi.connected", event={"type": "wifi.connected", "ts": 1, "data": {"ssid": "дом"}}, start_node="n1")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.read("vpn_state"), "")
        self.assertEqual([c for c in self.env.lines("ipc.log") if "xvpn" in c], [])

    async def test_color_from_clipboard_shows_hex_and_rgb(self):
        ui = C.FakeUi(answer={"shown": True})
        self.runtime(ui=ui)
        self.add(self.load("color-clipboard"))
        res = await self.rt.engine.run("color-clipboard", trigger="clipboard.color",
                                       event={"type": "clipboard.color", "ts": 1, "data": {"hex": "#3B82F6", "rgb": "rgb(59, 130, 246)"}}, start_node="n1")
        self.assertEqual(res["status"], "ok", res)
        kind, payload = ui.requests[0]
        self.assertEqual(kind, "show")
        self.assertEqual(payload["text"], "HEX: #3B82F6\nRGB: rgb(59, 130, 246)")
        self.assertNotIn("3B82F6", json.dumps(res))               # the run log keeps only the length
