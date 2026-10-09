"""Stage 9c triggers: colour / phone from the clipboard, Bluetooth devices, VPN changes, Wi-Fi disconnected.
Parsers run on recorded samples; sources run against stub binaries on PATH (wl-paste, dbus-monitor, busctl, nmcli) and a temp
events file. Nothing touches the real desktop, D-Bus, VPN or network."""
import asyncio
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd
from test_sources_b import SourceBase
from xcmd import sources_b as B, sources_c as X, triggers as TR


class ColorPhoneParsers(unittest.TestCase):
    def test_colors_are_normalised(self):
        for text, hexv, rgb in (("#3b82f6", "#3B82F6", "rgb(59, 130, 246)"), ("  #FFF \n", "#FFFFFF", "rgb(255, 255, 255)"),
                                ("#0a0", "#00AA00", "rgb(0, 170, 0)"), ("rgb(1,2,3)", "#010203", "rgb(1, 2, 3)"),
                                ("RGB(255 0 128)", "#FF0080", "rgb(255, 0, 128)"), ("hsl(0, 100%, 50%)", "#FF0000", "rgb(255, 0, 0)"),
                                ("hsl(120deg 100% 25%)", "#008000", "rgb(0, 128, 0)"), ("hsl(200, 0%, 50%)", "#808080", "rgb(128, 128, 128)")):
            self.assertEqual(B.parse_color(text), {"hex": hexv, "rgb": rgb}, text)

    def test_not_colors(self):
        for bad in ("", "red", "#12", "#12345", "#gggggg", "color: #fff", "rgb(300, 0, 0)", "rgb(1,2)", "hsl(0, 120%, 50%)", "#fff #000",
                    "https://a.b/#fff", "x" * 200):
            self.assertIsNone(B.parse_color(bad), bad)

    def test_phones(self):
        for text, digits, e164 in (("+7 (999) 123-45-67", "79991234567", "+79991234567"), ("8 999 123 45 67", "89991234567", "+79991234567"),
                                   ("9991234567", "9991234567", "+79991234567"), ("+1 (415) 555-0132", "14155550132", "+14155550132"),
                                   ("+49 30 123456", "4930123456", "+4930123456"), ("123-4567", "1234567", "+1234567"),
                                   ("89991234567", "89991234567", "+79991234567")):
            self.assertEqual(B.parse_phone(text), {"digits": digits, "e164": e164}, text)

    def test_not_phones(self):
        for bad in ("", "12345", "1234567", "2024-01-05", "05.01.2024", "192.168.100.200", "call +7 999 123 45 67", "+", "1" * 16, "+7 999 123 45 67 89 01 23 45",
                    "hello", "12 / 34", "(((((((("):
            self.assertIsNone(B.parse_phone(bad), bad)

    def test_sensitive_fields_are_hidden_in_public_events(self):
        ev = {"type": "clipboard.color", "data": {"hex": "#112233", "rgb": "rgb(17, 34, 51)"}}
        self.assertEqual(B.public_event(ev)["data"], {"hex": "‹7›", "rgb": "‹15›"})
        ev = {"type": "clipboard.phone", "data": {"digits": "79991234567", "e164": "+79991234567"}}
        self.assertEqual(B.public_event(ev)["data"], {"digits": "‹11›", "e164": "‹12›"})


class ClipboardKinds(SourceBase):
    def setUp(self):
        super().setUp()
        self.stub("wl-paste", 'FEED="$FAKE_DIR/clip.feed"\nwhile true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done\n')

    async def test_kinds_fire_and_content_is_never_logged(self):
        src = await self.go(B.ClipboardSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        self.feed("clip", "just text\0#7F1D1D\0+7 (999) 555-12-34\0https://example.org/x\0hsl(10, 50%, 50%)\0")
        self.assertTrue(await self.until(lambda: len(self.events) == 4))
        self.assertEqual(self.types(), ["clipboard.color", "clipboard.phone", "clipboard.link", "clipboard.color"])
        self.assertEqual(self.events[0]["data"], {"hex": "#7F1D1D", "rgb": "rgb(127, 29, 29)"})
        self.assertEqual(self.events[1]["data"], {"digits": "79995551234", "e164": "+79995551234"})
        self.feed("clip", "hsl(10, 50%, 50%)\0")                           # the same colour again: debounced
        await asyncio.sleep(0.4)
        self.assertEqual(len(self.events), 4)
        log = self.logtext()
        for secret in ("7F1D1D", "7f1d1d", "5551234", "555-12-34", "just text"):
            self.assertNotIn(secret, log)
        self.assertIn("clipboard color", log)
        self.assertIn("clipboard phone", log)

    async def test_own_copy_does_not_fire_colours(self):
        src = await self.go(B.ClipboardSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        B.mark_own_copy()
        self.feed("clip", "#abcdef\0")
        self.assertTrue(await self.until(lambda: src.ignored_own == 1))
        self.assertEqual(self.events, [])
        B.OWN_COPY["until"] = 0

    def test_filters_and_capabilities(self):
        sch = C.xbuild.build().sch
        for nid in ("event.clipboard.color", "event.clipboard.phone"):
            self.assertEqual(sch.nodes[nid].capabilities, ["trigger.clipboard"])
        sub = TR.Sub("c:e", "c", "e", "clipboard.color", "clipboard", {})
        self.assertTrue(TR.matches(sub, {"type": "clipboard.color", "data": {"hex": "#000000", "rgb": ""}}))

    async def test_event_runs_the_command_and_its_values_stay_out_of_the_run_log(self):
        self.runtime()
        cmd = make_cmd("col", [node("e", "event.clipboard.color@1"), node("s", "ui.show_result@1", title="Цвет")],
                       [wire("e", "exec", "s", "exec_in"), wire("e", "hex", "s", "value")])
        self.add(cmd)
        tm = TR.TriggerManager(self.rt.engine, sources={"clipboard": B.ClipboardSource()})
        await tm.refresh()
        self.assertEqual([s.emits for s in tm.subs], ["clipboard.color"])
        tasks = await tm.on_event({"type": "clipboard.color", "data": {"hex": "#445566", "rgb": "rgb(68, 85, 102)"}, "src": "clipboard"})
        res = await asyncio.gather(*tasks)
        self.assertEqual(res[0]["status"], "ok", res)
        self.assertNotIn("445566", json.dumps(res[0]))
        self.assertNotIn("445566", json.dumps(tm.recent))
        await tm.stop()


DBUS_SAMPLE = """signal time=1.5 sender=:1.5 -> destination=(null destination) serial=10 path=/org/bluez/hci0/dev_C0_DA_5E_75_7E_FE; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.bluez.Device1"
   array [
      dict entry(
         string "Connected"
         variant             boolean true
      )
   ]
   array [
   ]
signal time=2.5 sender=:1.5 -> destination=(null destination) serial=11 path=/org/bluez/hci0/dev_C0_DA_5E_75_7E_FE; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.bluez.Device1"
   array [
      dict entry(
         string "RSSI"
         variant             int16 -60
      )
      dict entry(
         string "Connected"
         variant             boolean false
      )
   ]
signal time=3.5 sender=:1.5 -> destination=(null destination) serial=12 path=/org/bluez/hci0; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.bluez.Adapter1"
   array [
      dict entry(
         string "Connected"
         variant             boolean true
      )
   ]
signal time=4.5 sender=:1.5 -> destination=(null destination) serial=13 path=/org/bluez/hci0/dev_11_22_33_44_55_66; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged
   string "org.bluez.MediaControl1"
   array [
      dict entry(
         string "Connected"
         variant             boolean true
      )
   ]
"""


class BluetoothTests(SourceBase):
    def test_parser_only_reports_device_connected_changes(self):
        p = X.BluetoothParser()
        hits = [h for h in (p.feed(l) for l in DBUS_SAMPLE.splitlines()) if h]
        self.assertEqual(hits, [("C0:DA:5E:75:7E:FE", True), ("C0:DA:5E:75:7E:FE", False)])

    def test_kinds(self):
        self.assertEqual([X.bt_kind(i) for i in ("audio-headphones", "audio-card", "input-keyboard", "input-mouse", "input-gaming", "phone", "", None)],
                         ["audio", "audio", "input", "input", "input", "other", "other", "other"])

    async def run_source(self):
        self.stub("dbus-monitor", 'FEED="$FAKE_DIR/dbus.feed"\nwhile true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done\n')
        self.stub("busctl", 'case "$*" in\n *Alias) echo \'{"type":"s","data":"HUAWEI FreeBuds"}\';;\n *Icon) echo "{\\"type\\":\\"s\\",\\"data\\":\\"$(cat "$FAKE_DIR/icon")\\"}";;\n *) exit 1;;\nesac\n')
        self.env.write_fake("icon", "audio-headphones")
        src = await self.go(X.BluetoothSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        return src

    async def test_source_fires_with_name_kind_and_connected_and_logs_no_identity(self):
        await self.run_source()
        self.feed("dbus", DBUS_SAMPLE)
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual([e["type"] for e in self.events], ["bluetooth.device"] * 2)
        self.assertEqual(self.events[0]["data"], {"name": "HUAWEI FreeBuds", "mac": "C0:DA:5E:75:7E:FE", "kind": "audio", "connected": True})
        self.assertFalse(self.events[1]["data"]["connected"])
        log = self.logtext()
        self.assertNotIn("HUAWEI", log)
        self.assertNotIn("C0:DA", log)
        self.assertIn("bluetooth device", log)

    async def test_repeated_state_is_not_repeated(self):
        await self.run_source()
        one = DBUS_SAMPLE.split("signal time=2.5")[0]
        self.feed("dbus", one)
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.feed("dbus", one)
        await asyncio.sleep(0.4)
        self.assertEqual(len(self.events), 1)

    def test_filters(self):
        d = {"name": "HUAWEI FreeBuds", "mac": "C0:DA:5E:75:7E:FE", "kind": "audio", "connected": True}
        s = lambda **p: TR.Sub("c:e", "c", "e", "bluetooth.device", "bluetooth", p)
        ev = {"type": "bluetooth.device", "data": d}
        self.assertTrue(TR.matches(s(change="connected", name_filter="freebuds"), ev))
        self.assertTrue(TR.matches(s(change="any", name_filter="c0:da"), ev))
        self.assertTrue(TR.matches(s(change="any", name_filter="re:^HUAWEI"), ev))
        self.assertFalse(TR.matches(s(change="disconnected"), ev))
        self.assertFalse(TR.matches(s(change="connected", name_filter="sony"), ev))

    def test_node_is_read_only_with_its_own_right(self):
        sch = C.xbuild.build().sch
        nd = sch.nodes["event.bluetooth.device"]
        self.assertEqual(nd.capabilities, ["trigger.bluetooth"])
        self.assertFalse(nd.side_effects or nd.changes_state)
        self.assertEqual([p.id for p in nd.outputs], ["exec", "name", "kind", "connected"])


def ev_line(name, **kw):
    return json.dumps(dict({"ts": 1, "event": name}, **kw), ensure_ascii=False) + "\n"


class VpnEventTests(SourceBase):
    async def test_events_become_vpn_changed_without_replaying_history(self):
        p = os.path.join(self.env.root, "events.jsonl")
        with open(p, "w") as f:
            f.write(ev_line("vpn.connected", node="Old", cc="NL"))
        src = X.VpnSource(path=p)
        src.poll_s = 0.05
        await self.go(src)
        await asyncio.sleep(0.2)
        self.assertEqual(self.events, [])
        with open(p, "a") as f:
            f.write(ev_line("vpn.connected", node="Berlin", cc="DE") + json.dumps({"type": "server.down", "data": {"id": "x"}}) + "\n"
                    + ev_line("vpn.subscription_updated", count=3) + ev_line("vpn.node_changed", node="Paris", cc="FR")
                    + ev_line("vpn.disconnected") + ev_line("vpn.failed", reason="happ_active") + "garbage\n")
        self.assertTrue(await self.until(lambda: len(self.events) == 4))
        self.assertEqual([e["data"]["state"] for e in self.events], ["connected", "connected", "disconnected", "failed"])
        self.assertEqual([e["data"]["node"] for e in self.events], ["Berlin", "Paris", "Paris", ""])
        self.assertEqual(self.events[3]["data"]["reason"], "happ_active")
        self.assertTrue(self.events[0]["data"]["connected"] and not self.events[2]["data"]["connected"])
        log = self.logtext()
        self.assertNotIn("Berlin", log)
        self.assertNotIn("Paris", log)

    def test_default_path_is_the_shared_event_bus(self):
        old = {k: os.environ.pop(k, None) for k in ("XCMD_VPN_EVENTS", "XVPN_EVENTS")}
        self.addCleanup(lambda: [os.environ.__setitem__(k, v) for k, v in old.items() if v])
        os.environ["XDG_STATE_HOME"] = "/x/state"
        self.addCleanup(os.environ.pop, "XDG_STATE_HOME", None)
        self.assertEqual(X.vpn_events_file(), "/x/state/serpantinum/events.jsonl")

    def test_state_filter(self):
        s = lambda f: TR.Sub("c:e", "c", "e", "vpn.changed", "vpn", {"state_filter": f})
        ev = {"type": "vpn.changed", "data": {"state": "failed"}}
        self.assertTrue(TR.matches(s("any"), ev) and TR.matches(s("failed"), ev))
        self.assertFalse(TR.matches(s("connected"), ev))


class WifiDisconnectTests(SourceBase):
    async def test_disconnect_fires_with_the_old_network_only_when_really_gone(self):
        self.stub("nmcli", 'case "$1" in\n monitor) FEED="$FAKE_DIR/ev"; while true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done;;\n'
                           ' -t) cat "$FAKE_DIR/devs.txt";;\n -g) cat "$FAKE_DIR/ssid";;\nesac\n')
        self.env.write_fake("devs.txt", "wlan0:wifi:connected:HomeConn\n")
        self.env.write_fake("ssid", "HomeNet\n")
        src = B.WifiSource()
        src.debounce = 0.05
        await self.go(src)
        self.assertTrue(await self.until(lambda: src.state == "running" and src.current == "HomeNet"))
        self.env.write_fake("devs.txt", "wlan0:wifi:disconnected:--\n")
        self.env.write_fake("ev", "wlan0: disconnected\n")
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual((self.events[0]["type"], self.events[0]["data"]), ("wifi.disconnected", {"ssid": "HomeNet"}))
        self.env.write_fake("devs.txt", "wlan0:wifi:connected:Other\n")
        self.env.write_fake("ssid", "OtherNet\n")
        self.env.write_fake("ev", "wlan0: connected\n")
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual(self.types(), ["wifi.disconnected", "wifi.connected"])
        self.assertNotIn("HomeNet", self.logtext())

    def test_filter_applies_to_both(self):
        s = TR.Sub("c:e", "c", "e", "wifi.disconnected", "wifi", {"ssid_filter": "home"})
        self.assertTrue(TR.matches(s, {"type": "wifi.disconnected", "data": {"ssid": "HomeNet"}}))
        self.assertFalse(TR.matches(s, {"type": "wifi.disconnected", "data": {"ssid": "Cafe"}}))
