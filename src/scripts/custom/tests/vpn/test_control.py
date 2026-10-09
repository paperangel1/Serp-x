import json
import os
import socket
import threading
import unittest
from unittest import mock

from common import LINKS, Env, FakeSocks, b64_body, free_port, mode
from xvpn import control, links, metrics, paths, subscription, system

_real_tcp_probe = metrics.tcp_probe


def seed(e, port):
    """Nodes on disk + settings pointing socksPort at the fake proxy; units 'installed'."""
    r = links.parse_subscription_text(b64_body())
    paths.write_json(e.state / "nodes.json", {"version": 1, "updated": 1, "kind": "links", "nodes": r["nodes"], "rules": []})
    paths.write_json(e.state / "meta.json", {"updated": 1, "count": 6, "kind": "links"})
    e.write_settings({"socksPort": port, "pingMethod": "tcp"})
    e.install_units()
    return r["nodes"]


class Base(unittest.TestCase):
    def setUp(self):
        self.e = Env().__enter__()
        self.socks = FakeSocks()
        self.nodes = seed(self.e, self.socks.port)
        self.patches = [mock.patch.object(control, "_sleep", lambda s: None), mock.patch.object(control.metrics, "tcp_probe", lambda h, p, t=3: (12, None))]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.socks.close()
        self.e.__exit__()


class Connect(Base):
    def test_connect_success_writes_config_and_runtime(self):
        r = control.connect()
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["state"], "on")
        self.assertEqual(mode(self.e.state / "config.json"), 0o600)
        cfg = json.loads((self.e.state / "config.json").read_text())
        self.assertEqual(cfg["outbounds"][0]["tag"], "proxy")
        rt = json.loads((self.e.state / "runtime.json").read_text())
        self.assertEqual(set(rt), {"killSwitch", "blockIPv6", "bypassIps"})
        self.assertIn("start serp-xray.service", self.e.calls())
        st = control.status()
        self.assertEqual(st["state"], "on")
        self.assertEqual(st["node"]["cc"], "NL")
        self.assertGreater(st["rxBytes"], 0)
        events = (self.e.td / "events.jsonl").read_text()
        self.assertIn("vpn.connected", events)

    def test_happ_active_refuses_and_never_touches_happ(self):
        self.e.set_unit("happd.service", "active")
        self.e.happ(core=True)
        r = control.connect()
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "happ_active")
        self.assertEqual(self.e.calls(), [])                       # nothing was started, nothing stopped
        st = control.status()
        self.assertEqual(st["state"], "failed")
        self.assertTrue(st["happActive"])

    def test_happ_tunnel_interface_also_blocks(self):
        (self.e.sysnet / "happ-xray").mkdir()
        self.e.happ(route=True)
        self.assertEqual(control.connect()["error"], "happ_active")

    def test_service_not_installed(self):
        (self.e.etc / "etc/systemd/system/serp-xray.service").unlink()
        self.assertEqual(control.connect()["error"], "service_missing")
        self.assertIn("service_missing", control.status()["degraded"])

    def test_no_nodes(self):
        (self.e.state / "nodes.json").unlink()
        self.assertEqual(control.connect()["error"], "no_nodes")

    def test_invalid_config_is_not_started(self):
        self.e.xray(ok=False)
        r = control.connect()
        self.assertEqual(r["error"], "config_invalid")
        self.assertEqual(self.e.calls(), [])
        self.assertFalse((self.e.state / "config.json").exists())

    def test_start_failure(self):
        (self.e.stub / "fail-start").write_text("1")
        self.assertEqual(control.connect()["error"], "start_failed")

    def test_dead_tunnel_is_stopped_again(self):
        self.socks.close()                                          # proxy answers nothing -> no connectivity
        r = control.connect()
        self.assertEqual(r["error"], "no_connectivity")
        self.assertIn("stop serp-xray.service", self.e.calls())
        self.assertEqual(control.status()["state"], "failed")

    def test_disconnect(self):
        control.connect()
        r = control.disconnect()
        self.assertEqual(r["state"], "off")
        self.assertEqual(control.status()["state"], "off")
        self.assertIn("vpn.disconnected", (self.e.td / "events.jsonl").read_text())

    def test_toggle(self):
        self.assertTrue(control.toggle()["ok"])
        self.assertEqual(control.toggle()["state"], "off")


class Switch(Base):
    def test_switch_when_off_only_remembers(self):
        nid = self.nodes[2]["id"]
        r = control.switch(nid)
        self.assertEqual((r["state"], r["selected"]), ("off", nid))
        self.assertEqual(self.e.calls(), [])

    def test_switch_when_on_restarts_with_new_outbound(self):
        control.connect()
        before = json.loads((self.e.state / "config.json").read_text())["outbounds"][0]
        nid = self.nodes[2]["id"]                                    # shadowsocks
        r = control.switch(nid)
        self.assertTrue(r["ok"])
        self.assertIn("restart serp-xray.service", self.e.calls())
        after = json.loads((self.e.state / "config.json").read_text())["outbounds"][0]
        self.assertNotEqual(before["protocol"], after["protocol"])
        self.assertEqual(after["protocol"], "shadowsocks")
        self.assertIn("vpn.node_changed", (self.e.td / "events.jsonl").read_text())

    def test_unknown_node(self):
        with self.assertRaises(control.VpnError):
            control.switch("nope")

    def test_next_wraps_around(self):
        control.write_state(selected=self.nodes[-1]["id"])
        control.next_node()
        self.assertEqual(control.read_state()["selected"], self.nodes[0]["id"])


class Watchdog(Base):
    def test_idle_when_service_is_off(self):
        self.assertEqual(control.watchdog_tick(), "idle")

    def test_ok_resets_failures(self):
        control.connect()
        control.write_state(failures=1)
        self.assertEqual(control.watchdog_tick(probe=lambda: True), "ok")
        self.assertEqual(control.read_state()["failures"], 0)

    def test_disables_after_20_seconds_of_failures(self):
        control.connect()
        results = [control.watchdog_tick(probe=lambda: False) for _ in range(3)]    # ticks at t=0,10,20 s
        self.assertEqual(results, ["warn", "warn", "disabled"])
        self.assertIn("stop serp-xray.service", self.e.calls())
        self.assertEqual(control.status()["state"], "failed")
        self.assertEqual(control.status()["reason"], "no_connectivity")
        self.assertTrue(any("VPN отключён" in n for n in self.e.notified()))

    def test_recovery_before_the_limit_keeps_the_tunnel(self):
        control.connect()
        control.watchdog_tick(probe=lambda: False)
        control.watchdog_tick(probe=lambda: False)
        self.assertEqual(control.watchdog_tick(probe=lambda: True), "ok")
        self.assertNotIn("stop serp-xray.service", self.e.calls())

    def test_auto_disable_can_be_turned_off(self):
        control.connect()
        self.e.write_settings({"socksPort": self.socks.port, "autoDisable": False})
        for _ in range(6):
            self.assertEqual(control.watchdog_tick(probe=lambda: False), "warn")
        self.assertNotIn("stop serp-xray.service", self.e.calls())

    def test_custom_threshold(self):
        control.connect()
        self.e.write_settings({"socksPort": self.socks.port, "autoDisableSeconds": 40})
        self.assertEqual([control.watchdog_tick(probe=lambda: False) for _ in range(5)], ["warn"] * 4 + ["disabled"])

    def test_loop_exits_once_the_service_is_gone(self):
        control.watchdog_loop(max_ticks=10)
        self.assertFalse(control.watchdog_alive())


class Status(Base):
    def test_degraded_flags(self):
        st = control.status()
        self.assertIn("geo_missing", st["degraded"])                # ru-direct without lists
        self.e.write_settings({"socksPort": self.socks.port, "mode": "all"})
        self.assertNotIn("geo_missing", control.status()["degraded"])

    def test_status_has_no_secrets(self):
        blob = json.dumps(control.status())
        for s in ("pass-word-1", "legacy-pass", "trojan-pass", "hy2-auth", "A" * 43, "11111111-2222"):
            self.assertNotIn(s, blob)

    def test_transitional_states(self):
        control.write_state(state="starting", busyUntil=control._now() + 30)
        self.assertEqual(control.status()["state"], "starting")
        control.write_state(state="starting", busyUntil=control._now() - 1)
        self.assertEqual(control.status()["state"], "off")


class Metrics(Base):
    def test_ping_all_skips_udp_nodes_and_caches(self):
        res = control.ping_all()
        udp = [n for n in self.nodes if n["udp"]][0]
        self.assertEqual(res[udp["id"]]["state"], "na")
        self.assertEqual(res[self.nodes[0]["id"]]["ms"], 12)
        nodes = {n["id"]: n for n in control.status()["nodes"]}
        self.assertEqual(nodes[self.nodes[0]["id"]]["pingMs"], 12)

    def test_tcp_ping_real_socket(self):
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
        self.assertIsNotNone(_real_tcp_probe("127.0.0.1", s.getsockname()[1])[0])
        s.close()
        self.assertIsNone(_real_tcp_probe("127.0.0.1", free_port(), timeout=0.5)[0])

    def test_probe_requires_a_real_http_reply(self):
        self.assertTrue(metrics.probe_via_socks(self.socks.port, timeout=2))
        bad = FakeSocks(reply=b"garbage")
        try:
            self.assertFalse(metrics.probe_via_socks(bad.port, timeout=2))
        finally:
            bad.close()

    def test_throughput_through_proxy(self):
        fake = FakeSocks(reply=b"HTTP/1.1 200 OK\r\n\r\n", body_bytes=2_000_000)
        try:
            mbps = metrics.download_mbps(fake.port, "speed.test", "/x", seconds=1, port=80, use_tls=False)
            self.assertGreater(mbps, 1)
        finally:
            fake.close()

    def test_speedtest_requires_a_connection_and_caches(self):
        with self.assertRaises(control.VpnError):
            control.speedtest()
        control.connect()
        with mock.patch.object(control.metrics, "download_mbps", lambda port, **kw: 123.4):
            r = control.speedtest()
        self.assertEqual(r["mbps"], 123.4)
        cur = [n for n in control.status()["nodes"] if n["id"] == r["id"]][0]
        self.assertEqual(cur["speedMbps"], 123.4)


if __name__ == "__main__":
    unittest.main()
