"""Stage 4: trigger framework and batch A sources, all against fakes (fake clock, fake sources, recorded Hyprland and
logind lines, temp dirs). No real Hyprland, D-Bus, systemd or network."""
import asyncio
import contextlib
import io
import json
import os
import unittest
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

import common as C
from common import node, wire, make_cmd, approve_all
from xcmd import sources as S, solar, triggers as TR
from xcmd.clock import FakeClock
from xcmd.daemon import Daemon
from xcmd.protocol import Client
from xcmd.schema import load_schema

UTC = ZoneInfo("UTC")


def ts(y, mo, d, h=0, mi=0, s=0, tz=UTC):
    return datetime(y, mo, d, h, mi, s, tzinfo=tz).timestamp()


def event_cmd(name, etype, props=None, cid=None, extra_nodes=()):
    nodes = [node("e", etype, **(props or {})), node("n", "action.notify@1", title=name)] + list(extra_nodes)
    return make_cmd(name, nodes, [wire("e", "exec", "n", "exec_in")], id=cid or name.lower())


class FakeSource(S.Source):
    def __init__(self, name, types):
        super().__init__()
        self.name, self.types = name, types
        self.started = self.stopped = 0

    async def start(self, emit):
        self.emit, self.state = emit, "running"
        self.started += 1

    async def stop(self):
        self.state = "idle"
        self.stopped += 1


class DyingSource(FakeSource):
    async def start(self, emit):
        self.emit = emit
        self.state = "running"
        self.task = asyncio.ensure_future(self._guard())

    async def run(self):
        raise RuntimeError("socket gone")


# ------------------------------------------------------------------------------------------------ pure functions
class SolarTests(unittest.TestCase):
    def near(self, dt, h, m, tol=6):
        got = dt.hour * 60 + dt.minute
        self.assertLessEqual(abs(got - (h * 60 + m)), tol, str(dt))

    def test_moscow_summer_solstice(self):
        r, s = solar.sun_times(55.7558, 37.6173, date(2026, 6, 21))      # 03:45 / 21:19 MSK = 00:45 / 18:19 UTC
        self.near(r, 0, 45)
        self.near(s, 18, 19)

    def test_greenwich_march_equinox(self):
        r, s = solar.sun_times(51.4769, 0.0, date(2026, 3, 20))
        self.near(r, 6, 3)
        self.near(s, 18, 12)

    def test_polar_day_and_night(self):
        self.assertIsNone(solar.sun_times(80, 0, date(2026, 6, 21)))
        self.assertIsNone(solar.sun_times(80, 0, date(2026, 12, 21)))

    def test_next_event_with_offset_is_strictly_later(self):
        now = ts(2026, 6, 21, 12)
        sunset = solar.next_sun_event(now, "sunset", 0, 55.7558, 37.6173)
        early = solar.next_sun_event(now, "sunset", -15, 55.7558, 37.6173)
        self.assertAlmostEqual(sunset - early, 900, delta=1)
        self.assertGreater(early, now)
        self.assertIsNone(solar.next_sun_event(now, "sunset", 0, 80, 0))


class NextTimeTests(unittest.TestCase):
    def test_daily_and_weekdays(self):
        now = ts(2026, 10, 9, 9)                                   # Friday 09:00
        self.assertEqual(S.next_time_at(now, "08:00", "daily", UTC), ts(2026, 10, 10, 8))
        self.assertEqual(S.next_time_at(now, "08:00", "weekdays", UTC), ts(2026, 10, 12, 8))   # Monday
        self.assertEqual(S.next_time_at(now, "08:00", "weekends", UTC), ts(2026, 10, 10, 8))
        self.assertEqual(S.next_time_at(now, "08:00", "wed", UTC), ts(2026, 10, 14, 8))
        self.assertEqual(S.next_time_at(now, "09:00", "daily", UTC), ts(2026, 10, 10, 9))      # strictly after now

    def test_timezone_is_respected(self):
        msk = ZoneInfo("Europe/Moscow")
        now = ts(2026, 10, 6, 4, 0)                                # 07:00 MSK
        self.assertEqual(S.next_time_at(now, "08:00", "daily", msk), ts(2026, 10, 6, 8, tz=msk))

    def test_dst_gap_lands_after_the_transition(self):
        ny = ZoneInfo("America/New_York")
        now = ts(2026, 3, 8, 1, 0, tz=ny)                          # 02:30 does not exist on 2026-03-08
        got = S.next_time_at(now, "02:30", "daily", ny)
        self.assertGreater(got, now)
        self.assertLess(got - now, 3 * 3600)

    def test_dst_overlap_fires_once_per_day(self):
        ny = ZoneInfo("America/New_York")
        first = S.next_time_at(ts(2026, 11, 1, 0, 0, tz=ny), "01:30", "daily", ny)
        again = S.next_time_at(first, "01:30", "daily", ny)
        self.assertGreater(again - first, 20 * 3600)


# ----------------------------------------------------------------------------------------------- time source
class TimeSourceTests(unittest.IsolatedAsyncioTestCase):
    def make(self, start, location=lambda: (55.7558, 37.6173)):
        self.clock = FakeClock(start)
        self.events = []
        src = S.TimeSource(self.clock, tz=UTC, location=location)

        async def emit(ev):
            self.events.append(ev)
        src.emit = emit
        return src

    def sub(self, emits, key="c:e", **params):
        return S.Sub(key, "c", "e", emits, "time", params)

    async def test_time_at_fires_once_in_time(self):
        src = self.make(ts(2026, 10, 6, 7, 59))
        src.configure([self.sub("time.at", at="08:00", days="daily", missed="skip")])
        self.assertEqual(await src.tick(), 0)
        self.clock.advance(61)
        self.assertEqual(await src.tick(), 1)
        self.assertEqual(self.events[0]["data"]["time"], "08:00")
        self.assertEqual(self.events[0]["data"]["weekday"], "tue")
        self.assertEqual(self.events[0]["key"], "c:e")
        self.clock.advance(30)
        self.assertEqual(await src.tick(), 0)                      # not twice

    async def test_missed_run_after_suspend_policy(self):
        for policy, expect in (("skip", 0), ("run_once", 1)):
            src = self.make(ts(2026, 10, 6, 7, 59))
            src.configure([self.sub("time.at", at="08:00", days="daily", missed=policy)])
            await src.tick()
            self.clock.advance(3 * 3600)                           # the machine slept past 08:00
            self.assertEqual(await src.tick(), expect, policy)
            if expect:
                self.assertTrue(self.events[-1]["data"]["missed"])
            self.assertGreater(src.next["c:e"], self.clock.now())  # rescheduled for tomorrow either way

    async def test_interval(self):
        src = self.make(ts(2026, 10, 6, 8))
        src.configure([self.sub("time.every", minutes=30)])
        self.clock.advance(29 * 60)
        self.assertEqual(await src.tick(), 0)
        self.clock.advance(61)
        self.assertEqual(await src.tick(), 1)
        fired = 0
        for _ in range(62):                                         # the real loop ticks at least every 30 s
            self.clock.advance(30)
            fired += await src.tick()
        self.assertEqual(fired, 1)

    async def test_sun_with_and_without_coordinates(self):
        src = self.make(ts(2026, 6, 21, 12))
        src.configure([self.sub("sun", kind="sunset", offset=-10)])
        due = src.next["c:e"]
        self.assertAlmostEqual(due, solar.next_sun_event(self.clock.now(), "sunset", -10, 55.7558, 37.6173), delta=1)
        self.clock.t = due + 5
        self.assertEqual(await src.tick(), 1)
        none = self.make(ts(2026, 6, 21, 12), location=lambda: None)
        none.configure([self.sub("sun", kind="sunset", offset=0)])
        self.assertIn("координаты", none.errors["c:e"])
        self.assertEqual(await none.tick(), 0)
        none.location = lambda: (55.0, 37.0)                        # coordinates appear later
        self.clock.advance(10)
        await none.tick()
        self.assertNotIn("c:e", none.errors)

    async def test_reconfigure_keeps_schedule_of_unchanged_subs(self):
        src = self.make(ts(2026, 10, 6, 7, 0))
        a = self.sub("time.every", minutes=30)
        src.configure([a])
        nxt = src.next["c:e"]
        self.clock.advance(60)
        src.configure([self.sub("time.every", minutes=30)])
        self.assertEqual(src.next["c:e"], nxt)
        src.configure([self.sub("time.every", minutes=10)])
        self.assertNotEqual(src.next["c:e"], nxt)

    async def test_sleep_is_capped_for_suspend_detection(self):
        src = self.make(ts(2026, 10, 6, 7, 0))
        src.configure([self.sub("time.at", at="23:00", days="daily")])
        self.assertLessEqual(src.sleep_for(), S.MAX_NAP_S)


# ------------------------------------------------------------------------------------- hyprland / logind parsers
HYPR_LINES = [
    "workspacev2>>2,2", "workspace>>2",
    "openwindow>>80c8d8f0,2,firefox,Mozilla Firefox — привет, мир",
    "windowtitlev2>>80c8d8f0,Новая вкладка", "activewindow>>firefox,Новая вкладка",
    "monitoraddedv2>>1,HDMI-A-1,Dell Inc. DELL U2720Q", "monitoradded>>HDMI-A-1",
    "monitorremoved>>HDMI-A-1", "closewindow>>80c8d8f0", "garbage line without separator",
]


class HyprParserTests(unittest.TestCase):
    def parse_all(self):
        windows, out = {}, []
        for line in HYPR_LINES:
            out += S.parse_hypr_line(line, windows)
        return out, windows

    def test_events_and_dedup_of_v1_variants(self):
        out, windows = self.parse_all()
        self.assertEqual([t for t, _ in out], ["workspace", "window.open", "monitor.added", "monitor.removed", "window.close"])
        self.assertEqual(windows, {})

    def test_open_keeps_commas_in_title_and_close_knows_class(self):
        out, _ = self.parse_all()
        opened, closed = out[1][1], out[4][1]
        self.assertEqual((opened["class"], opened["title"], opened["workspace"]),
                         ("firefox", "Mozilla Firefox — привет, мир", "2"))
        self.assertEqual((closed["class"], closed["title"]), ("firefox", "Новая вкладка"))     # last known title

    def test_monitor_and_workspace_data(self):
        out, _ = self.parse_all()
        self.assertEqual(out[0][1], {"id": "2", "workspace": "2"})
        self.assertEqual(out[2][1]["monitor"], "HDMI-A-1")
        self.assertEqual(out[3][1], {"monitor": "HDMI-A-1"})


class HyprSourceTests(unittest.IsolatedAsyncioTestCase):
    async def test_reads_stream_and_reconnects(self):
        events, calls = [], []

        async def emit(ev):
            events.append(ev)

        def reader_with(lines):
            r = asyncio.StreamReader()
            r.feed_data("".join(l + "\n" for l in lines).encode())
            r.feed_eof()
            return r

        async def opener():
            calls.append(1)
            if len(calls) == 1:
                raise ConnectionError("нет сокета")
            if len(calls) == 2:
                return reader_with(HYPR_LINES[:3])
            r = asyncio.StreamReader()                              # third connection stays open (no EOF)
            r.feed_data(b"workspacev2>>5,5\n")
            return r

        async def snapshot():
            return {}
        src = S.HyprlandSource(opener=opener, snapshot=snapshot, retry=(0.01,))
        await src.start(emit)
        await asyncio.sleep(0.2)
        await src.stop()
        self.assertGreaterEqual(len(calls), 3)
        types = [e["type"] for e in events]
        self.assertIn("window.open", types)
        self.assertEqual(types.count("workspace"), 2)
        self.assertTrue(all(e["src"] == "hyprland" for e in events))

    async def test_missing_socket_is_waiting_not_failed(self):
        async def opener():
            raise ConnectionError("сокет Hyprland не найден")
        src = S.HyprlandSource(opener=opener, retry=(0.01,))
        await src.start(lambda ev: None)
        await asyncio.sleep(0.05)
        self.assertEqual(src.state, "waiting")
        self.assertIn("Hyprland", src.error)
        await src.stop()


LOGIND_LINES = [
    '{"type":"signal","endian":"l","flags":1,"version":1,"cookie":9,"path":"/org/freedesktop/login1/session/_32",'
    '"interface":"org.freedesktop.login1.Session","member":"Lock"}',
    '{"type":"signal","path":"/org/freedesktop/login1/session/_32","member":"Unlock"}',
    '{"type":"signal","path":"/org/freedesktop/login1","member":"PrepareForSleep","payload":{"type":"b","data":[true]}}',
    '{"type":"signal","path":"/org/freedesktop/login1","member":"PrepareForSleep","payload":{"type":"b","data":[false]}}',
    '{"type":"method_call","member":"Lock"}', 'not json',
]


class LogindTests(unittest.IsolatedAsyncioTestCase):
    def test_parser(self):
        out = [e for l in LOGIND_LINES for e in S.parse_logind_line(l)]
        self.assertEqual([t for t, _ in out], ["session.lock", "session.unlock", "session.sleep", "session.resume"])

    async def test_source_emits_and_failure_is_contained(self):
        events = []

        async def emit(ev):
            events.append(ev["type"])
        r = asyncio.StreamReader()
        r.feed_data("".join(l + "\n" for l in LOGIND_LINES).encode())
        r.feed_eof()

        async def spawn():
            return r, None
        src = S.LogindSource(spawn=spawn)
        await src.start(emit)
        await asyncio.sleep(0.1)
        self.assertEqual(events, ["session.lock", "session.unlock", "session.sleep", "session.resume"])
        self.assertEqual(src.state, "failed")                       # EOF = busctl died: only this source is marked
        self.assertIn("busctl", src.error)
        await src.stop()


class LoginAndIdleTests(C.Base):
    async def test_login_fires_once_per_session(self):
        events = []
        marker = os.path.join(self.env.root, "login.marker")

        async def emit(ev):
            events.append(ev["type"])
        env = {"HYPRLAND_INSTANCE_SIGNATURE": "abc"}
        for _ in range(2):
            src = S.LoginSource(env_fn=lambda: env, marker=marker)
            await src.start(emit)
            await asyncio.sleep(0.05)
            await src.stop()
        self.assertEqual(events, ["session.login"])
        env["HYPRLAND_INSTANCE_SIGNATURE"] = "def"                  # a new session fires again
        src = S.LoginSource(env_fn=lambda: env, marker=marker)
        await src.start(emit)
        await asyncio.sleep(0.05)
        await src.stop()
        self.assertEqual(events, ["session.login", "session.login"])

    async def test_idle_source_publishes_requested_minutes(self):
        f = os.path.join(self.env.root, "idle.json")
        src = S.ExternalSource(request_file=f)
        src.configure([S.Sub("a", "c", "e", "idle.start", "idle", {"minutes": 10}),
                       S.Sub("b", "c", "f", "idle.stop", "idle", {"minutes": 5}),
                       S.Sub("c", "c", "g", "idle.stop", "idle", {"minutes": 10})])
        with open(f) as fh:
            self.assertEqual(json.load(fh), {"minutes": [5, 10]})
        await src.stop()
        self.assertFalse(os.path.exists(f))


# --------------------------------------------------------------------------------------------- trigger manager
class ManagerCase(C.Base):
    def setUp(self):
        super().setUp()
        self.runtime()
        self.src = FakeSource("hyprland", ("window.open", "window.close", "workspace", "monitor.added", "monitor.removed"))
        self.time = FakeSource("time", ("time.at",))
        self.mgr = TR.TriggerManager(self.rt.engine, self.clock, sources={"hyprland": self.src, "time": self.time})

    async def wait(self, tasks):
        return [await t for t in tasks]

    async def fire(self, etype, **data):
        return await self.wait(await self.mgr.on_event({"type": etype, "data": data, "ts": self.clock.now()}))


class ManagerTests(ManagerCase):
    async def test_sources_start_and_stop_lazily(self):
        await self.mgr.start()
        self.assertEqual((self.src.started, self.time.started), (0, 0))        # nobody listens: nothing runs
        cmd = self.add(event_cmd("Fox", "event.app_opened@1", {"class_filter": "fox"}))
        await self.mgr.refresh()
        self.assertEqual((self.src.started, self.time.started), (1, 0))
        await self.mgr.refresh()
        self.assertEqual(self.src.started, 1)                                  # not restarted by a refresh
        self.rt.store.set_flag(cmd, enabled=False)
        await self.mgr.refresh()
        self.assertEqual(self.src.stopped, 1)
        self.assertEqual(self.mgr.status()["active"], [])

    async def test_unapproved_invalid_disabled_and_imported_are_not_subscribed(self):
        self.add(event_cmd("Unapproved", "event.app_opened@1"), approve=False)
        self.add(event_cmd("Disabled", "event.app_opened@1", cid="dis", ) | {"enabled": False})
        self.add(event_cmd("Imported", "event.app_opened@1", cid="imp") | {"imported": True})
        self.add(make_cmd("Manual", [node("e", "event.manual@1")], [], id="man"))
        broken = event_cmd("Broken", "event.app_opened@1", cid="brk")
        broken["wires"] = [wire("e", "exec", "n", "nope")]
        self.add(broken)
        await self.mgr.start()
        self.assertEqual(self.mgr.status()["subscriptions"], [])

    async def test_filters_substring_regex_and_workspace(self):
        self.add(event_cmd("Fox", "event.app_opened@1", {"class_filter": "FOX"}, cid="fox"))
        self.add(event_cmd("Re", "event.app_opened@1", {"class_filter": "re:^steam(_app_\\d+)?$"}, cid="re"))
        self.add(event_cmd("Ws5", "event.workspace@1", {"workspace_filter": "5"}, cid="ws5"))
        self.add(event_cmd("Mon", "event.monitor_added@1", {"monitor_filter": "HDMI"}, cid="mon"))
        await self.mgr.start()
        r = await self.fire("window.open", **{"class": "firefox", "title": "x"})
        self.assertEqual([x["name"] for x in r], ["Fox"])
        r = await self.fire("window.open", **{"class": "steam_app_730", "title": "x"})
        self.assertEqual([x["name"] for x in r], ["Re"])
        r = await self.fire("window.open", **{"class": "kitty", "title": "x"})
        self.assertEqual(r, [])
        self.assertEqual([x["name"] for x in await self.fire("workspace", workspace="5", id="5")], ["Ws5"])
        self.assertEqual(await self.fire("workspace", workspace="6", id="6"), [])
        self.assertEqual([x["name"] for x in await self.fire("monitor.added", monitor="HDMI-A-1")], ["Mon"])
        self.assertEqual(await self.fire("monitor.added", monitor="DP-1"), [])

    async def test_run_log_has_the_triggering_event_and_outputs_reach_the_graph(self):
        nodes = [node("e", "event.app_opened@1"), node("n", "action.notify@1")]
        cmd = make_cmd("Out", nodes, [wire("e", "exec", "n", "exec_in"), wire("e", "class", "n", "title")], id="out")
        self.add(cmd)
        await self.mgr.start()
        r = await self.fire("window.open", **{"class": "kitty", "title": "t", "workspace": "1"})
        self.assertEqual(r[0]["status"], "ok")
        self.assertIn("kitty", self.env.read("notify.log"))                 # the class output fed the notification title
        last = self.rt.log.tail(1)[0]
        self.assertEqual(last["trigger"], "window.open")
        self.assertEqual(last["event"]["data"]["class"], "kitty")

    async def test_several_event_nodes_in_one_command(self):
        nodes = [node("e1", "event.app_opened@1", class_filter="a"), node("e2", "event.workspace@1"),
                 node("n", "action.notify@1", title="x")]
        cmd = make_cmd("Two", nodes, [wire("e1", "exec", "n", "exec_in"), wire("e2", "exec", "n", "exec_in")], id="two")
        self.add(cmd)
        await self.mgr.start()
        self.assertEqual(len(self.mgr.status()["subscriptions"]), 2)
        self.assertEqual(len(await self.fire("window.open", **{"class": "a", "title": ""})), 1)
        self.assertEqual(len(await self.fire("workspace", workspace="3", id="3")), 1)

    async def test_dedup_of_identical_bursts(self):
        self.add(event_cmd("Fox", "event.app_opened@1", cid="fox"))
        await self.mgr.start()
        first = await self.fire("window.open", **{"class": "fox", "title": "t"})
        self.clock.advance(0.05)
        again = await self.fire("window.open", **{"class": "fox", "title": "t"})
        self.clock.advance(0.5)
        later = await self.fire("window.open", **{"class": "fox", "title": "t"})
        self.assertEqual((len(first), len(again), len(later)), (1, 0, 1))

    async def test_loop_guard_pauses_after_five_runs_a_minute(self):
        self.add(event_cmd("Loop", "event.monitor_added@1", cid="loop"))
        await self.mgr.start()
        statuses = []
        for i in range(7):
            self.clock.advance(2)
            r = await self.fire("monitor.added", monitor="M%d" % i)
            statuses.append(r[0]["status"] if r else None)
        self.assertEqual(statuses[:5], ["ok"] * 5)
        self.assertEqual(statuses[5], "skipped")
        self.assertTrue(self.rt.state.is_paused("loop"))
        self.assertIn("приостановлена", self.env.read("notify.log"))
        self.assertEqual(self.rt.log.tail(1)[0]["reason"], "paused_cmd")

    async def test_global_pause_skips(self):
        self.add(event_cmd("Fox", "event.app_opened@1", cid="fox"))
        await self.mgr.start()
        self.rt.state.set_paused_all(True)
        r = await self.fire("window.open", **{"class": "x", "title": ""})
        self.assertEqual(r[0]["reason"], "paused_all")

    async def test_time_events_are_targeted_by_key(self):
        self.add(event_cmd("A", "event.time_at@1", {"at": "08:00"}, cid="a"))
        self.add(event_cmd("B", "event.time_at@1", {"at": "09:00"}, cid="b"))
        await self.mgr.start()
        ev = {"type": "time.at", "data": {"time": "08:00"}, "key": "a:e"}
        r = await self.wait(await self.mgr.on_event(ev))
        self.assertEqual([x["name"] for x in r], ["A"])

    async def test_dead_source_is_isolated(self):
        dead = DyingSource("hyprland", ("window.open",))
        mgr = TR.TriggerManager(self.rt.engine, self.clock, sources={"hyprland": dead, "time": self.time})
        self.add(event_cmd("Fox", "event.app_opened@1", cid="fox"))
        self.add(event_cmd("T", "event.time_at@1", {"at": "08:00"}, cid="t"))
        await mgr.start()
        await asyncio.sleep(0.05)
        st = mgr.status()
        self.assertEqual(st["sources"]["hyprland"]["state"], "failed")
        self.assertIn("socket gone", st["sources"]["hyprland"]["error"])
        self.assertEqual(st["sources"]["time"]["state"], "running")
        r = await self.wait(await mgr.on_event({"type": "time.at", "data": {}, "key": "t:e"}))
        self.assertEqual(r[0]["status"], "ok")

    async def test_source_changes_are_logged(self):
        dead = DyingSource("hyprland", ("window.open",))
        mgr = TR.TriggerManager(self.rt.engine, self.clock, sources={"hyprland": dead, "time": self.time})
        self.add(event_cmd("Fox", "event.app_opened@1", cid="fox"))
        with self.assertLogs("xcmd", level="INFO") as cap:
            await mgr.start()
            await asyncio.sleep(0.05)
            await mgr.on_event({"type": "window.open", "data": {"class": "x", "title": ""}})
        text = "\n".join(cap.output)
        self.assertIn("start source hyprland", text)
        self.assertIn("socket gone", text)
        self.assertIn("event window.open -> command fox", text)

    async def test_event_topic_for_cmd_events(self):
        q = self.rt.engine.events.subscribe(["event"])
        await self.mgr.start()
        await self.fire("workspace", workspace="1", id="1")
        msg = q.get_nowait()
        self.assertEqual((msg["ev"], msg["type"], msg["data"]["workspace"]), ("event", "workspace", "1"))

    async def test_status_shape(self):
        self.add(event_cmd("Fox", "event.app_opened@1", {"class_filter": "x"}, cid="fox"))
        await self.mgr.start()
        st = self.mgr.status()
        self.assertEqual(st["subscriptions"][0]["event"], "window.open")
        self.assertEqual(st["subscriptions"][0]["params"]["class_filter"], "x")
        self.assertEqual(st["active"], ["hyprland"])


class ValidationTests(unittest.TestCase):
    def test_every_trigger_node_makes_a_valid_command_with_its_capability(self):
        from xcmd.validate import validate
        sch = load_schema()
        for nd in sch.nodes.values():
            if nd.flow != "event" or nd.id == "event.manual":
                continue
            cmd = make_cmd(nd.id, [node("e", nd.type_string), node("n", "action.notify@1", title="x")],
                           [wire("e", "exec", "n", "exec_in")], id="t")
            rep = validate(cmd, sch)
            self.assertTrue(rep["ok"], (nd.id, rep["errors"]))
            self.assertTrue(set(nd.capabilities) <= set(rep["capabilities"]), nd.id)

    def test_bad_literals_are_rejected(self):
        from xcmd.validate import validate
        sch = load_schema()
        for props in ({"at": "25:00"}, {"days": "someday"}, {"missed": "x"}):
            cmd = make_cmd("t", [node("e", "event.time_at@1", **props), node("n", "action.notify@1", title="x")],
                           [wire("e", "exec", "n", "exec_in")], id="t")
            self.assertFalse(validate(cmd, sch)["ok"], props)


# --------------------------------------------------------------------------------------------- daemon end to end
class DaemonTriggerTests(C.Base):
    async def asyncSetUp(self):
        self.runtime()
        self.src = FakeSource("hyprland", ("window.open", "window.close", "workspace", "monitor.added", "monitor.removed"))
        self.d = Daemon(rt=self.rt, socket_path=self.env.sock, reload_every=0.05, sources={"hyprland": self.src})
        await self.d.start()
        self.addAsyncCleanup(self.d.stop)
        self.c = Client(self.env.sock, timeout=10)
        self.c.connect()
        self.addCleanup(self.c.close)

    async def call(self, method, **params):
        return await asyncio.to_thread(self.c.call, method, params)

    async def test_emit_runs_automation_and_saving_refreshes_subscriptions(self):
        doc = approve_all(event_cmd("Fox", "event.app_opened@1", {"class_filter": "fox"}, cid="fox"), self.rt.sch)
        await self.call("save", command=doc)
        await self.call("enable", ref="fox")
        await self.call("approve", ref="fox")
        for _ in range(40):
            if self.src.started:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(self.src.started, 1)                       # save -> dirty -> lazy source start
        res = await self.call("emit", type="window.open", data={"class": "firefox", "title": "t"})
        self.assertEqual(res["started"], 1)
        for _ in range(40):
            if "Fox" in self.env.read("notify.log"):
                break
            await asyncio.sleep(0.05)
        self.assertIn("Fox", self.env.read("notify.log"))
        st = await self.call("status")
        self.assertTrue(st["triggers"]["running"])
        self.assertEqual(st["triggers"]["subscriptions"][0]["command"], "fox")
        await self.call("disable", ref="fox")
        for _ in range(40):
            if self.src.stopped:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(self.src.stopped, 1)

    async def test_events_topic_streams_to_clients(self):
        await self.call("subscribe", topics=["event"])
        await self.call("emit", type="workspace", data={"workspace": "7", "id": "7"})
        msg = await asyncio.to_thread(next, self.c.events())
        self.assertEqual((msg["ev"], msg["type"]), ("event", "workspace"))

    async def test_emit_without_triggers_is_an_error(self):
        from xcmd.api import Api, ApiError
        api = Api(self.rt.engine, self.rt.store, self.rt.state, self.rt.sch, self.rt.log)
        with self.assertRaises(ApiError):
            await api.call("emit", {"type": "workspace"})


class CliTests(C.Base):
    def run_cli(self, *argv):
        from xcmd import cli
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(["--local", *argv])
        return rc, out.getvalue(), err.getvalue()

    def test_emit_without_daemon_is_a_dry_run(self):
        doc = approve_all(event_cmd("Fox", "event.app_opened@1", {"class_filter": "fox"}, cid="fox"), load_schema())
        self.env.write_cmd(doc)
        rc, out, _ = self.run_cli("emit", "window.open", json.dumps({"class": "firefox", "title": "t"}))
        self.assertEqual(rc, 0)
        self.assertIn("репетиция", out)
        self.assertIn("Fox", out)
        self.assertEqual(self.env.read("notify.log"), "")           # nothing was really executed
        rc, out, _ = self.run_cli("emit", "window.open", json.dumps({"class": "kitty"}))
        self.assertIn("ни одна", out)

    def test_status_and_bad_json(self):
        rc, out, _ = self.run_cli("status")
        self.assertEqual(rc, 0)
        rc, _, err = self.run_cli("emit", "window.open", "{oops")
        self.assertEqual(rc, 1)
        self.assertIn("JSON", err)

    def test_events_needs_the_daemon(self):
        rc, _, err = self.run_cli("events")
        self.assertEqual(rc, 1)
        self.assertIn("Демон не запущен", err)


if __name__ == "__main__":
    unittest.main()
