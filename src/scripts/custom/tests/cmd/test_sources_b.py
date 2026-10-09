"""Stage 9b: trigger batch B (headphones, clipboard link, new file, servers, Wi-Fi, USB, notifications).
Parsers run on recorded samples; sources run against stub binaries on PATH (pactl, wl-paste, nmcli, udevadm, busctl),
a real inotify in a temp dir, and a temp events file. Nothing touches the real desktop, D-Bus or network."""
import asyncio
import glob
import json
import os
import stat
import time
import unittest

import common as C
from common import node, wire, make_cmd
from xcmd import sources_b as B, triggers as TR

SINKS_BT = """Sink #61
\tState: RUNNING
\tName: bluez_output.AA_BB_CC_DD_EE_FF.1
\tDescription: WH-1000XM4
\tProperties:
\t\tdevice.form_factor = "headphone"
\t\tdevice.bus = "bluetooth"
Sink #62
\tName: alsa_output.pci-0000_00_1f.3.analog-stereo
\tDescription: Built-in Audio Analog Stereo
\tProperties:
\t\tdevice.form_factor = "internal"
\tPorts:
\t\tanalog-output-speaker: Speakers (type: Speaker, priority: 10000, availability group: Legacy 1, available)
\t\tanalog-output-headphones: Headphones (type: Headphones, priority: 9900, availability group: Legacy 1, not available)
\tActive Port: analog-output-speaker
"""
SINKS_WIRED = SINKS_BT.replace("not available)", "available)").replace("Active Port: analog-output-speaker", "Active Port: analog-output-headphones")
SINKS_SPEAKER_BT = SINKS_BT.replace('"headphone"', '"speaker"')


def _rd(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


class ParserTests(unittest.TestCase):
    def test_headphones_bluetooth_wired_and_speakers(self):
        hp = B.headphones_of(B.parse_sinks(SINKS_BT))
        self.assertEqual(hp, {"bluez_output.AA_BB_CC_DD_EE_FF.1": {"name": "WH-1000XM4", "kind": "bluetooth"}})
        wired = B.headphones_of(B.parse_sinks(SINKS_WIRED))
        self.assertEqual(wired["alsa_output.pci-0000_00_1f.3.analog-stereo"]["kind"], "wired")
        self.assertEqual(len(wired), 2)
        self.assertEqual(B.headphones_of(B.parse_sinks(SINKS_SPEAKER_BT)), {})        # a Bluetooth speaker is not headphones
        self.assertEqual(B.headphones_of(B.parse_sinks("")), {})

    def test_clip_records(self):
        self.assertEqual(B.parse_clip_record(" https://www.youtube.com/watch?v=abc \n"), {"url": "https://www.youtube.com/watch?v=abc", "domain": "www.youtube.com"})
        for bad in ("hello", "see https://a.b/c", "ftp://x.y/z", "https://", "javascript:alert(1)", "https://a.b/ c", "https://a.b\nhttps://c.d"):
            self.assertIsNone(B.parse_clip_record(bad), bad)

    def test_clip_filters(self):
        d = {"url": "https://www.youtube.com/watch?v=1", "domain": "www.youtube.com"}
        self.assertTrue(B.clip_matches({"domains": "youtube.com, youtu.be"}, d))
        self.assertTrue(B.clip_matches({"domains": ""}, d))
        self.assertFalse(B.clip_matches({"domains": "youtu.be"}, d))
        self.assertFalse(B.clip_matches({"domains": "tube.com"}, d))                 # not a suffix of a label
        self.assertTrue(B.clip_matches({"regex": r"watch\?v="}, d))
        self.assertFalse(B.clip_matches({"regex": r"playlist"}, d))
        self.assertFalse(B.clip_matches({"regex": "("}, d))                          # a broken regex matches nothing

    def test_file_filters(self):
        for n in ("a.part", "b.crdownload", "c.TMP", ".hidden", "d.txt~", "e.download"):
            self.assertTrue(B.file_ignored(n), n)
        self.assertFalse(B.file_ignored("report.pdf"))
        self.assertTrue(B.file_wanted({"pattern": "pdf png"}, "A.PDF"))
        self.assertTrue(B.file_wanted({"pattern": "*.jpg, .png"}, "x.png"))
        self.assertFalse(B.file_wanted({"pattern": "pdf"}, "x.doc"))
        self.assertTrue(B.file_wanted({"pattern": ""}, "x"))

    def test_server_events(self):
        down = json.dumps({"ts": 1, "type": "server.down", "data": {"id": "s1", "name": "vps"}})
        up = json.dumps({"ts": 2, "type": "server.up", "data": {"id": "s1", "name": "vps"}})
        self.assertEqual(B.parse_server_event(down)[0], "server.unreachable")
        self.assertEqual(B.parse_server_event(down)[1]["server_name"], "vps")
        self.assertEqual(B.parse_server_event(up)[0], "server.recovered")
        for other in ('{"type":"server.command","data":{}}', "garbage", "[]", '{"type":"server.down"}'):
            self.assertIsNone(B.parse_server_event(other))

    def test_wifi_status(self):
        txt = "enp3s0:ethernet:connected:Проводное\nwlan0:wifi:connected:Home\\:Net\nlo:loopback:unmanaged:--\n"
        self.assertEqual(B.parse_wifi_status(txt), "Home:Net")
        self.assertEqual(B.parse_wifi_status("wlan0:wifi:disconnected:--\n"), "")

    def test_usb_udev(self):
        blk = "UDEV  [10.1] add      /devices/x/block/sdb/sdb1 (block)\nACTION=add\nSUBSYSTEM=block\nDEVTYPE=partition\nDEVNAME=/dev/sdb1\nID_BUS=usb\nID_FS_TYPE=vfat\nID_FS_LABEL=PHOTOS"
        act, sub, props = B.parse_udev_block(blk)
        self.assertEqual((act, sub, B.usb_event(props)), ("add", "block", ("PHOTOS", "/dev/sdb1", "storage")))
        hub = "UDEV  [1] add /d (usb)\nACTION=add\nSUBSYSTEM=usb\nDEVTYPE=usb_device\nID_USB_CLASS_FROM_DATABASE=Hub"
        self.assertIsNone(B.usb_event(B.parse_udev_block(hub)[2]))
        kb = "UDEV  [1] add /d (usb)\nACTION=add\nSUBSYSTEM=usb\nDEVTYPE=usb_device\nID_MODEL=Cool_Keyboard\nDEVNAME=/dev/bus/usb/001/005"
        self.assertEqual(B.usb_event(B.parse_udev_block(kb)[2])[0::2], ("Cool Keyboard", "other"))
        sata = "UDEV  [1] add /d (block)\nACTION=add\nSUBSYSTEM=block\nDEVTYPE=disk\nID_BUS=ata\nID_FS_TYPE=ext4"
        self.assertIsNone(B.usb_event(B.parse_udev_block(sata)[2]))

    def test_notify_line(self):
        line = json.dumps({"type": "method_call", "member": "Notify", "payload": {"type": "susssasa{sv}i",
                           "data": ["Telegram", 0, "", "Anna", "hi there", [], {}, -1]}})
        self.assertEqual(B.parse_notify_line(line), {"app": "Telegram", "replaces": 0, "title": "Anna", "body": "hi there"})
        self.assertIsNone(B.parse_notify_line('{"type":"method_return"}'))
        self.assertIsNone(B.parse_notify_line("nope"))

    def test_public_event_hides_text(self):
        ev = {"type": "clipboard.link", "data": {"url": "https://secret.example/token123", "domain": "secret.example"}}
        shown = B.public_event(ev)
        self.assertNotIn("token123", json.dumps(shown))
        self.assertEqual(shown["data"]["domain"], "secret.example")
        n = B.public_event({"type": "notification.received", "data": {"app": "A", "title": "T", "body": "B"}})
        self.assertEqual(n["data"]["app"], "A")
        self.assertNotIn('"T"', json.dumps(n))
        self.assertEqual(B.public_event({"type": "workspace", "data": {"id": "1"}})["data"], {"id": "1"})


class SourceBase(C.Base):
    def setUp(self):
        super().setUp()
        self.events = []
        self.srcs = []
        self.addAsyncCleanup(self._cleanup)

    async def _cleanup(self):
        for s in self.srcs:
            await s.stop()

    def stub(self, name, body):
        p = os.path.join(self.env.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)

    def feeder(self, name, args_case, extra=""):
        """stub that prints and removes $FAKE_DIR/<name>.feed every 50 ms (a controllable stream)."""
        self.stub(name, 'FEED="$FAKE_DIR/%s.feed"\n%s\nwhile true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done\n' % (name, extra))

    def feed(self, name, text):
        p = os.path.join(self.env.fake, name + ".feed.tmp")
        with open(p, "w") as f:
            f.write(text)
        os.replace(p, os.path.join(self.env.fake, name + ".feed"))

    async def emit(self, ev):
        self.events.append(ev)

    async def go(self, src):
        self.srcs.append(src)
        await src.start(self.emit)
        return src

    async def until(self, pred, timeout=6.0):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            if pred():
                return True
            await asyncio.sleep(0.03)
        return False

    def types(self):
        return [e["type"] for e in self.events]

    def logtext(self):
        out = ""
        for p in glob.glob(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], "*.log")):
            out += _rd(p)
        return out


class AudioTests(SourceBase):
    async def test_bluetooth_connect_disconnect_and_wired(self):
        self.stub("pactl", 'case "$1" in\n subscribe) FEED="$FAKE_DIR/ev"; while true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done;;\n'
                           ' list) cat "$FAKE_DIR/sinks.txt";;\nesac\n')
        self.env.write_fake("sinks.txt", "Sink #62\n\tName: a\n\tDescription: Speakers\n")
        src = B.AudioSource()
        src.debounce = 0.05
        await self.go(src)
        self.assertTrue(await self.until(lambda: src.state == "running" and src.known == {}))
        self.env.write_fake("sinks.txt", SINKS_BT)
        self.env.write_fake("ev", "Event 'new' on sink #61\nEvent 'change' on sink #61\n")
        self.assertTrue(await self.until(lambda: self.types() == ["audio.headphones_connected"]))
        self.assertEqual(self.events[0]["data"], {"name": "WH-1000XM4", "kind": "bluetooth"})
        self.env.write_fake("sinks.txt", "Sink #62\n\tName: a\n\tDescription: Speakers\n")
        self.env.write_fake("ev", "Event 'remove' on sink #61\n")
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual(self.types()[1], "audio.headphones_disconnected")
        self.env.write_fake("sinks.txt", SINKS_WIRED)                               # jack plugged: a port change, no new sink
        self.env.write_fake("ev", "Event 'change' on sink #62\n")
        self.assertTrue(await self.until(lambda: len(self.events) >= 3))
        await asyncio.sleep(0.3)
        self.assertEqual(self.types(), ["audio.headphones_connected", "audio.headphones_disconnected"] + ["audio.headphones_connected"] * (len(self.events) - 2))
        self.assertIn("wired", [e["data"]["kind"] for e in self.events[2:]])

    async def test_missing_tool_fails_with_hint(self):
        src = B.AudioSource()
        src.argv, src.tool = ("xcmd-no-such-tool",), "xcmd-no-such-tool"
        await self.go(src)
        self.assertTrue(await self.until(lambda: src.state == "failed"))
        self.assertIn("Не найдена программа", src.error)


class ClipboardTests(SourceBase):
    def setUp(self):
        super().setUp()
        self.stub("wl-paste", 'FEED="$FAKE_DIR/clip.feed"\nwhile true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done\n')

    async def test_only_links_fire_and_nothing_sensitive_is_logged(self):
        src = await self.go(B.ClipboardSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        self.feed("clip", "just some text\0password hunter2\0https://youtu.be/TOPSECRETID?t=1\0")
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual(self.events[0]["data"], {"url": "https://youtu.be/TOPSECRETID?t=1", "domain": "youtu.be"})
        self.feed("clip", "https://youtu.be/TOPSECRETID?t=1\0")                      # the same link again: debounced
        await asyncio.sleep(0.4)
        self.assertEqual(len(self.events), 1)
        log = self.logtext()
        self.assertIn("youtu.be", log)
        self.assertNotIn("TOPSECRETID", log)
        self.assertNotIn("hunter2", log)

    async def test_own_copy_is_ignored_for_a_short_window(self):
        src = await self.go(B.ClipboardSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        B.mark_own_copy()
        self.feed("clip", "https://example.org/own\0")
        self.assertTrue(await self.until(lambda: src.ignored_own == 1))
        self.assertEqual(self.events, [])
        B.OWN_COPY["until"] = 0
        self.feed("clip", "https://example.org/other\0")
        self.assertTrue(await self.until(lambda: len(self.events) == 1))

    async def test_clipboard_set_node_marks_own_copy(self):
        self.runtime()
        B.OWN_COPY["until"] = 0
        cmd = make_cmd("cb", [node("e", "event.manual@1"), node("a", "action.clipboard_set@1", text="x")], [wire("e", "exec", "a", "exec_in")])
        self.add(cmd)
        await self.rt.engine.run("cb")
        self.assertGreater(B.OWN_COPY["until"], time.monotonic())
        B.OWN_COPY["until"] = 0


class FolderTests(SourceBase):
    def sub(self, folder, **params):
        return TR.Sub("c:e", "c", "e", "folder.new_file", "folder", dict({"folder": folder}, **params))

    async def start(self, **params):
        d = os.path.join(self.env.root, "watched")
        os.makedirs(d, exist_ok=True)
        src = B.FolderSource()
        src.stable_s, src.poll_s = 0.4, 0.1
        src.configure([self.sub(d, **params)])
        await self.go(src)
        self.assertTrue(await self.until(lambda: src.state == "running" and src.watched))
        return d, src

    async def test_fires_when_stable_once_and_skips_partial_files(self):
        d, src = await self.start()
        with open(os.path.join(d, "movie.mp4.part"), "w") as f:
            f.write("x")
        with open(os.path.join(d, ".hidden"), "w") as f:
            f.write("x")
        f = open(os.path.join(d, "growing.zip"), "w")
        for _ in range(4):                                       # still being written: size keeps changing
            f.write("data" * 100)
            f.flush()
            await asyncio.sleep(0.2)
        self.assertEqual(self.events, [])
        f.close()
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual(self.events[0]["key"], "c:e")
        self.assertEqual(self.events[0]["data"], {"path": os.path.join(d, "growing.zip"), "name": "growing.zip", "kind": "archive"})
        os.rename(os.path.join(d, "movie.mp4.part"), os.path.join(d, "movie.mp4"))       # download finished
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual(self.events[1]["data"]["kind"], "video")
        await asyncio.sleep(0.8)
        self.assertEqual(len(self.events), 2)
        self.assertNotIn("growing", self.logtext())                                  # file names stay out of the log

    async def test_pattern_and_recursive(self):
        d, src = await self.start(pattern="pdf", recursive=True)
        os.makedirs(os.path.join(d, "sub"))
        await asyncio.sleep(0.3)                                  # the new subfolder gets its watch
        for rel in ("a.txt", "b.pdf", os.path.join("sub", "c.pdf")):
            with open(os.path.join(d, rel), "w") as f:
                f.write("x")
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual(sorted(e["data"]["name"] for e in self.events), ["b.pdf", "c.pdf"])

    async def test_not_recursive_ignores_subfolders_and_missing_folder_is_reported(self):
        d, src = await self.start()
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "sub", "x.txt"), "w") as f:
            f.write("x")
        await asyncio.sleep(1.0)
        self.assertEqual(self.events, [])
        src.configure([self.sub(os.path.join(self.env.root, "nope"))])
        self.assertIn("нет", list(src.info()["errors"].values())[0])


class ServersTests(SourceBase):
    async def test_tails_new_lines_only_and_survives_truncation(self):
        p = os.path.join(self.env.root, "events.jsonl")
        line = lambda t, n: json.dumps({"ts": 1, "type": t, "data": {"id": n, "name": n}}) + "\n"
        with open(p, "w") as f:
            f.write(line("server.down", "old"))
        src = B.ServersSource(path=p)
        src.poll_s = 0.05
        await self.go(src)
        await asyncio.sleep(0.2)
        self.assertEqual(self.events, [])                         # history is not replayed
        with open(p, "a") as f:
            f.write(line("server.down", "vps") + line("server.command", "vps") + line("server.up", "vps"))
        self.assertTrue(await self.until(lambda: len(self.events) == 2))
        self.assertEqual(self.types(), ["server.unreachable", "server.recovered"])
        with open(p, "w") as f:                                    # trimmed / recreated
            f.write(line("server.down", "n2"))
        self.assertTrue(await self.until(lambda: len(self.events) == 3))
        self.assertEqual(self.events[2]["data"]["server_name"], "n2")


class WifiUsbNotifyTests(SourceBase):
    async def test_wifi(self):
        self.stub("nmcli", 'case "$1" in\n monitor) FEED="$FAKE_DIR/ev"; while true; do [ -f "$FEED" ] && { cat "$FEED"; rm -f "$FEED"; }; sleep 0.05; done;;\n'
                           ' -t) cat "$FAKE_DIR/devs.txt";;\n -g) echo "$FAKE_SSID";;\nesac\n')
        self.env.write_fake("devs.txt", "wlan0:wifi:disconnected:--\n")
        src = B.WifiSource()
        src.debounce = 0.05
        await self.go(src)
        self.assertTrue(await self.until(lambda: src.state == "running" and src.current == ""))
        self.env.write_fake("devs.txt", "wlan0:wifi:connected:HomeConn\n")
        os.environ["FAKE_SSID"] = "HomeNet"
        self.addCleanup(os.environ.pop, "FAKE_SSID", None)
        self.env.write_fake("ev", "wlan0: connecting (getting IP configuration)\nwlan0: connected\n")
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual(self.events[0]["data"], {"ssid": "HomeNet"})
        self.assertNotIn("HomeNet", self.logtext())
        self.env.write_fake("ev", "wlan0: connected\n")              # no change: nothing
        await asyncio.sleep(0.4)
        self.assertEqual(len(self.events), 1)

    async def test_usb(self):
        self.feeder("udevadm", "")
        src = await self.go(B.UsbSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        blk = "UDEV  [10.1] add      /devices/x/block/sdb/sdb1 (block)\nACTION=add\nSUBSYSTEM=block\nDEVTYPE=partition\nDEVNAME=/dev/sdb1\nID_BUS=usb\nID_FS_TYPE=vfat\nID_FS_LABEL=PHOTOS\n\n"
        rem = "UDEV  [11] remove /devices/x (block)\nACTION=remove\nSUBSYSTEM=block\nID_BUS=usb\nID_FS_TYPE=vfat\n\n"
        self.feed("udevadm", rem + blk)
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual(self.events[0]["data"], {"label": "PHOTOS", "device": "/dev/sdb1", "kind": "storage"})

    async def test_notifications_logs_only_the_app(self):
        self.feeder("busctl", "")
        src = await self.go(B.NotificationsSource())
        self.assertTrue(await self.until(lambda: src.state == "running"))
        mk = lambda app, rep, title, body: json.dumps({"type": "method_call", "member": "Notify", "payload": {"type": "susssasa{sv}i", "data": [app, rep, "", title, body, [], {}, -1]}}) + "\n"
        self.feed("busctl", mk("Serpantinum", 0, "own", "own body") + mk("Telegram", 7, "update", "progress") + mk("Telegram", 0, "Anna", "SECRET-BODY-42"))
        self.assertTrue(await self.until(lambda: len(self.events) == 1))
        self.assertEqual(self.events[0]["data"], {"app": "Telegram", "title": "Anna", "body": "SECRET-BODY-42"})
        log = self.logtext()
        self.assertIn("Telegram", log)
        self.assertNotIn("SECRET-BODY-42", log)
        self.assertNotIn("Anna", log)


class ManagerBTests(C.Base):
    """Through the TriggerManager: filters, the redacted event topic and the stored run log."""
    use_fake_clock = True

    def setUp(self):
        super().setUp()
        self.runtime()
        from test_triggers import FakeSource
        self.srcs = {"notifications": FakeSource("notifications", ("notification.received",)),
                     "clipboard": FakeSource("clipboard", ("clipboard.link",)),
                     "servers": FakeSource("servers", ("server.unreachable", "server.recovered")),
                     "audio": FakeSource("audio", ("audio.headphones_connected", "audio.headphones_disconnected"))}
        self.mgr = TR.TriggerManager(self.rt.engine, self.clock, sources=self.srcs)

    def cmd(self, name, etype, props, out_pin):
        nodes = [node("e", etype, **props), node("n", "action.notify@1", title=name)]
        return make_cmd(name, nodes, [wire("e", "exec", "n", "exec_in"), wire("e", out_pin, "n", "body")], id=name.lower())

    async def fire(self, etype, **data):
        return [await t for t in await self.mgr.on_event({"type": etype, "data": data, "ts": self.clock.now()})]

    async def test_notification_filter_and_nothing_stored(self):
        self.add(self.cmd("Notif", "event.notification.received@1", {"app_filter": "telegram"}, "body"))
        q = self.rt.engine.events.subscribe(["event"])
        await self.mgr.start()
        self.assertEqual(await self.fire("notification.received", app="Firefox", title="t", body="b"), [])
        res = await self.fire("notification.received", app="Telegram", title="Anna", body="SECRET-BODY-42")
        self.assertEqual(res[0]["status"], "ok")
        self.assertEqual(self.mgr.status()["subscriptions"][0]["source"], "notifications")
        blob = json.dumps(self.mgr.status()) + json.dumps([q.get_nowait(), q.get_nowait()])
        self.assertNotIn("SECRET-BODY-42", blob)
        self.assertIn("Telegram", blob)
        for p in glob.glob(os.path.join(self.env.state, "*")) + glob.glob(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], "*.log")):
            if os.path.isfile(p):
                self.assertNotIn("SECRET-BODY-42", _rd(p), p)

    async def test_clipboard_domain_filter_and_run_log_has_no_url(self):
        self.add(self.cmd("Vid", "event.clipboard.link@1", {"domains": "youtube.com, youtu.be"}, "url"))
        await self.mgr.start()
        self.assertEqual(await self.fire("clipboard.link", url="https://example.org/a", domain="example.org"), [])
        res = await self.fire("clipboard.link", url="https://youtu.be/PRIVATEID", domain="youtu.be")
        self.assertEqual(res[0]["status"], "ok")
        for p in glob.glob(os.path.join(self.env.state, "**", "*"), recursive=True):
            if os.path.isfile(p):
                self.assertNotIn("PRIVATEID", _rd(p), p)

    async def test_sensitive_events_are_not_handed_to_wait_event(self):
        self.assertIn("clipboard.link", B.SENSITIVE)
        calls = []
        self.rt.engine.deliver_event = lambda ev: calls.append(ev)
        await self.mgr.start()
        await self.fire("clipboard.link", url="https://a.b/c", domain="a.b")
        await self.fire("audio.headphones_connected", name="X", kind="wired")
        self.assertEqual([e["type"] for e in calls], ["audio.headphones_connected"])

    async def test_headphones_server_filters(self):
        self.add(self.cmd("Hp", "event.audio.headphones_connected@1", {"kind_filter": "wired"}, "name"))
        self.add(self.cmd("Srv", "event.server.unreachable@1", {"server_filter": "vps"}, "server_name"))
        await self.mgr.start()
        self.assertEqual(await self.fire("audio.headphones_connected", name="BT", kind="bluetooth"), [])
        self.assertEqual(len(await self.fire("audio.headphones_connected", name="Jack", kind="wired")), 1)
        self.assertEqual(await self.fire("server.unreachable", server="s2", server_name="other", reason=""), [])
        self.assertEqual(len(await self.fire("server.unreachable", server="s1", server_name="VPS-1", reason="")), 1)


if __name__ == "__main__":
    unittest.main()
