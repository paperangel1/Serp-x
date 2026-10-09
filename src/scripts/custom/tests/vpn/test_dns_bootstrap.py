"""Server-name bootstrap: fake resolvers only (XVPN_RESOLVE_MAP / patched lookups), fake clock, fake journal."""
import json
import socket
import struct
import threading
import unittest
from unittest import mock

from common import Env, FakeSocks
from test_control import Base
from xvpn import cli, control, resolve


class Resolve(unittest.TestCase):
    def setUp(self):
        self.e = Env().__enter__()

    def tearDown(self):
        self.e.__exit__()

    def test_success_prefers_ipv4(self):
        self.e.resolve_map({"a.example": ["2001:db8::1", "192.0.2.5"]})
        b = resolve.bootstrap(["a.example"], timeout=1)
        self.assertEqual(b["hosts"], {"a.example": ["192.0.2.5", "2001:db8::1"]})
        self.assertEqual((b["direct"], b["failed"]), ([], []))

    def test_ipv6_only(self):
        self.e.resolve_map({"a.example": ["2001:db8::1"]})
        self.assertEqual(resolve.bootstrap(["a.example"], timeout=1)["hosts"], {"a.example": ["2001:db8::1"]})

    def test_system_failure_falls_back_to_direct_dns(self):
        self.e.resolve_map({"direct:a.example": ["192.0.2.7"]})
        b = resolve.bootstrap(["a.example"], timeout=1)
        self.assertEqual((b["hosts"], b["direct"]), ({"a.example": ["192.0.2.7"]}, ["a.example"]))

    def test_both_fail(self):
        self.e.resolve_map({})
        self.assertEqual(resolve.bootstrap(["a.example"], timeout=1)["failed"], ["a.example"])

    def test_timeout_is_bounded(self):
        import time
        self.e.resolve_map({"a.example": "timeout", "b.example": ["192.0.2.2"]})
        t0 = time.monotonic()
        b = resolve.bootstrap(["a.example", "b.example"], timeout=0.3)
        self.assertLess(time.monotonic() - t0, 3)
        self.assertEqual((list(b["hosts"]), b["failed"]), (["b.example"], ["a.example"]))

    def test_wire_parser_against_local_udp_server(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        srv.bind(("127.0.0.1", 0))

        def serve():
            q, addr = srv.recvfrom(512)
            qend = q.index(b"\x00", 12) + 5
            ans = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + bytes([192, 0, 2, 44])
            srv.sendto(q[:2] + b"\x81\x80" + q[4:6] + b"\x00\x01\x00\x00\x00\x00" + q[12:qend] + ans, addr)
        threading.Thread(target=serve, daemon=True).start()
        try:
            self.assertEqual(resolve._dns_query("a.example", 1, "127.0.0.1", 2, port=srv.getsockname()[1]), ["192.0.2.44"])
        finally:
            srv.close()

    def test_outbound_domains_cover_all_shapes(self):
        from common import LINKS
        from xvpn import links
        for l in LINKS:
            n = links.parse_link(l)
            self.assertEqual(resolve.outbound_domains([n["outbound"]]), [n["address"]])


class Flow(Base):
    def setUp(self):
        super().setUp()
        self.clock = [1000.0]
        self.fake = [mock.patch.object(control, "_now", lambda: self.clock[0]),
                     mock.patch.object(control, "_sleep", lambda s: self.clock.__setitem__(0, self.clock[0] + s))]
        for p in self.fake:
            p.start()

    def tearDown(self):
        for p in self.fake:
            p.stop()
        super().tearDown()

    def node_name(self):
        return control.selected_node()["name"]

    def test_server_dns_aborts_before_the_core(self):
        self.e.resolve_map({})
        r = control.connect()
        self.assertEqual(r["error"], "server_dns")
        self.assertEqual(self.e.calls(), [])
        self.assertFalse((self.e.state / "config.json").exists())
        st = control.status()
        self.assertEqual((st["state"], st["reason"], st["reasonNode"]), ("failed", "server_dns", self.node_name()))

    def test_config_gets_the_resolved_server(self):
        r = control.connect()
        self.assertTrue(r["ok"])
        cfg = json.loads((self.e.state / "config.json").read_text())
        self.assertEqual(sorted(cfg["dns"]["hosts"].values()), ["192.0.2.%d" % i for i in range(1, 7)])   # ALL nodes pinned
        self.assertIn("192.0.2.1", json.loads((self.e.state / "runtime.json").read_text())["bypassIps"])

    def test_early_success_is_fast(self):
        t0 = self.clock[0]
        calls = []
        with mock.patch.object(control.metrics, "probe_via_socks", lambda *a, **k: calls.append(1) or len(calls) >= 2):
            self.assertTrue(control.connect()["ok"])
        self.assertLess(self.clock[0] - t0, 4)
        self.assertEqual(len(calls), 2)

    def test_timeout_after_15_seconds_with_fake_clock(self):
        t0 = self.clock[0]
        with mock.patch.object(control.metrics, "probe_via_socks", lambda *a, **k: False):
            r = control.connect()
        self.assertEqual(r["error"], "no_connectivity")
        self.assertTrue(15 <= self.clock[0] - t0 < 17)
        self.assertIn("stop serp-xray.service", self.e.calls())

    def test_journal_classes(self):
        host = self.nodes[0]["address"]
        for text, want in ((f'[Error] app/dns: failed to retrieve response for {host}. > Post "https://1.1.1.1/dns-query": context deadline exceeded', "server_dns"),
                           ("[Warning] proxy/vless/outbound: dial tcp 192.0.2.1:443: i/o timeout", "proxy_unreachable"),
                           ("nothing useful", "no_connectivity")):
            self.e.journal(text)
            with mock.patch.object(control.metrics, "probe_via_socks", lambda *a, **k: False):
                self.assertEqual(control.connect()["error"], want)

    def test_phase_is_published_and_cleared(self):
        seen = []
        real = control.write_state

        def spy(**kw):
            if "phase" in kw:
                seen.append(kw["phase"])
            return real(**kw)
        with mock.patch.object(control, "write_state", spy):
            self.assertTrue(control.connect()["ok"])
        self.assertEqual(seen[:3], ["resolving", "starting", "checking"])
        self.assertEqual(control.status()["phase"], "")

    def test_ping_uses_resolved_addresses_and_skips_unresolvable(self):
        self.e.resolve_map({"nl1.example.net": ["192.0.2.1"]})
        self.e.write_settings({"pingMethod": "tcp"})
        res = control.ping_all(force=True)
        self.assertEqual(res[self.nodes[0]["id"]]["state"], "ok")
        self.assertEqual(res[self.nodes[1]["id"]]["state"], "error")

    def test_doctor_row(self):
        rows = {r["key"]: r for r in cli.doctor()}
        self.assertEqual(rows["server_dns"]["level"], "ok")
        self.e.resolve_map({})
        rows = {r["key"]: r for r in cli.doctor()}
        self.assertEqual(rows["server_dns"]["level"], "fail")
        self.assertIn("DNS сервера узла", rows["server_dns"]["text"])


if __name__ == "__main__":
    unittest.main()
