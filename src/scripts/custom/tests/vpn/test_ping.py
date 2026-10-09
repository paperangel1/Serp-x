"""Node ping: settings, the short-lived measurement instance (fake xray), methods, cache/force, teardown, logging.
Only fakes: a python stand-in for xray, a fake `ping`, a local 127.0.0.1 HTTP server. No real xray / network."""
import glob
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from common import VPN_DIR, Env, b64_body
from xvpn import cli, control, links, paths, ping, resolve

FAKE = Path(__file__).resolve().parent / "fake_xray.py"
HOSTS = ("nl", "de", "fi", "se", "us", "jp")


class Target:
    """Local HTTP server: /generate_204 -> 204, /ok -> 200 + body, /bad -> 500. Records the methods it saw."""

    def __init__(self):
        outer = self
        self.methods = []

        class H(http.server.BaseHTTPRequestHandler):
            def _do(self):
                outer.methods.append(self.command)
                code = {"/generate_204": 204, "/ok": 200, "/bad": 500}.get(self.path.split("?")[0], 404)
                body = b"hello" if code == 200 else b""
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if self.command == "GET":
                    self.wfile.write(body)
            do_GET = do_HEAD = _do

            def log_message(self, *a):
                pass
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def url(self, p="/generate_204"):
        return f"http://127.0.0.1:{self.port}{p}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:                                    # a zombie still answers kill(0)
        return Path(f"/proc/{pid}/stat").read_text().split(")")[1].split()[0] != "Z"
    except OSError:
        return False


class Base(unittest.TestCase):
    def setUp(self):
        self.e = Env().__enter__()
        self.logdir = tempfile.mkdtemp(prefix="xvpn-log-")
        keys = ("SERPANTINUM_LOG_DIR", "FAKE_XRAY_DIR", "FAKE_XRAY_TARGET", "FAKE_XRAY_BEHAVIOR", "FAKE_XRAY_MODE", "XVPN_PING", "XVPN_XRAY")
        self._old = {k: os.environ.get(k) for k in keys}
        os.environ["SERPANTINUM_LOG_DIR"] = self.logdir
        self.rec = self.e.td / "rec"
        self.rec.mkdir()
        self.t = Target()
        os.environ.update({"FAKE_XRAY_DIR": str(self.rec), "FAKE_XRAY_TARGET": f"127.0.0.1:{self.t.port}"})
        os.environ.pop("FAKE_XRAY_MODE", None)
        os.environ.pop("FAKE_XRAY_BEHAVIOR", None)
        p = self.e.stub / "xray"
        p.write_text(f'#!/usr/bin/env bash\nexec python3 "{FAKE}" "$@"\n')
        p.chmod(0o755)
        self.nodes = links.parse_subscription_text(b64_body())["nodes"]
        self.by = {n["name"].split()[-1]: n for n in self.nodes}
        paths.write_json(self.e.state / "nodes.json", {"version": 1, "updated": 1, "kind": "links", "nodes": self.nodes, "rules": []})
        self.set(pingUrl=self.t.url(), pingTimeout=2)
        self.e.install_units()

    def tearDown(self):
        self.t.close()
        for k, v in self._old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.e.__exit__()

    def set(self, **kw):
        cur = json.loads(self.e.settings.read_text())["vpn"]
        cur.update(kw)
        self.e.write_settings(cur)

    def beh(self, m):
        os.environ["FAKE_XRAY_BEHAVIOR"] = json.dumps(m)

    def hang_all(self):
        self.beh({h + "1.example.net": "hang" for h in HOSTS})

    def st(self, res, name):
        return res[self.by[name]["id"]]["state"]

    def logs(self):
        return "".join(Path(f).read_text() for f in glob.glob(self.logdir + "/*"))

    def assert_torn_down(self):
        pid, child = int((self.rec / "pid").read_text()), int((self.rec / "child.pid").read_text())
        self.assertFalse(alive(pid), "xray left running")
        self.assertFalse(alive(child), "group member left running")
        self.assertFalse(os.path.exists((self.rec / "cfgdir").read_text()), "temp dir left")


class Settings(unittest.TestCase):
    def load(self, vpn):
        with Env() as e:
            e.write_settings(vpn)
            return paths.load_settings()

    def test_defaults(self):
        s = self.load({})
        self.assertEqual((s["pingMethod"], s["pingUrl"], s["pingTimeout"], s["pingDisplay"]),
                         ("httpGet", "https://www.gstatic.com/generate_204", 3, "digits"))

    def test_valid_values_kept(self):
        s = self.load({"pingMethod": "icmp", "pingUrl": "https://cp.cloudflare.com/generate_204", "pingTimeout": 7, "pingDisplay": "barsDigits"})
        self.assertEqual((s["pingMethod"], s["pingUrl"], s["pingTimeout"], s["pingDisplay"]),
                         ("icmp", "https://cp.cloudflare.com/generate_204", 7, "barsDigits"))

    def test_invalid_values_fall_back(self):
        s = self.load({"pingMethod": "curl", "pingDisplay": "pie", "pingUrl": "ftp://x/y", "pingTimeout": "9"})
        self.assertEqual((s["pingMethod"], s["pingDisplay"], s["pingUrl"], s["pingTimeout"]),
                         ("httpGet", "digits", "https://www.gstatic.com/generate_204", 3))

    def test_timeout_clamped(self):
        for raw, want in ((0, 1), (99, 10), (4.0, 4), (True, 3), (-5, 1), (float("nan"), 3)):
            self.assertEqual(self.load({"pingTimeout": raw})["pingTimeout"], want, raw)

    def test_url_validation(self):
        v = paths.valid_ping_url
        self.assertEqual(v(" http://a.example/x?y=1 "), "http://a.example/x?y=1")
        self.assertEqual(v("https://captive.apple.com/hotspot-detect.html"), "https://captive.apple.com/hotspot-detect.html")
        for bad in ("", "javascript:alert(1)", "file:///etc/passwd", "ftp://a/b", "https://", "http://u:p@a.example/", "http://a b.example/",
                    "http://a.example/\nx", "https://" + "a" * 600 + ".example/", None, 5, "http://a.example:99999/"):
            self.assertIsNone(v(bad), bad)


class Http(Base):
    def run_http(self, **kw):
        self.set(**kw)
        return control.ping_all(force=True)

    def test_every_protocol_incl_udp_and_failure_classes(self):
        self.beh({"nl1.example.net": "ok", "de1.example.net": "delay:0.3", "fi1.example.net": "hang", "se1.example.net": "close"})
        t0 = time.monotonic()
        res = self.run_http()
        self.assertLess(time.monotonic() - t0, 6)
        self.assertEqual(self.st(res, "Нидерланды-1"), "ok")
        self.assertEqual(self.st(res, "Германия-1"), "ok")
        self.assertGreaterEqual(res[self.by["Германия-1"]["id"]]["ms"], 300)
        self.assertEqual(self.st(res, "Finland-1"), "timeout")
        self.assertEqual(self.st(res, "Sweden-1"), "error")
        self.assertEqual(self.st(res, "USA-1"), "ok")
        self.assertEqual(self.st(res, "Japan-1"), "ok")                  # hysteria2 (UDP) is measurable now
        self.assertEqual(set(self.t.methods), {"GET"})

    def test_head_method(self):
        res = self.run_http(pingMethod="httpHead")
        self.assertEqual(self.st(res, "Japan-1"), "ok")
        self.assertEqual(set(self.t.methods), {"HEAD"})

    def test_2xx_with_body_ok_and_non_2xx_error(self):
        self.assertEqual(self.st(self.run_http(pingUrl=self.t.url("/ok")), "USA-1"), "ok")
        res = self.run_http(pingUrl=self.t.url("/bad"))
        self.assertEqual({v["state"] for v in res.values()}, {"error"})
        self.assertIn("why_status=6", self.logs())

    def test_instance_config_shape_and_isolation(self):
        self.run_http()
        cfg = json.loads((self.rec / "config.json").read_text())
        ibs = cfg["inbounds"]
        self.assertEqual(len(ibs), 6)
        self.assertEqual(len({i["port"] for i in ibs}), 6)
        self.assertTrue(all(i["listen"] == "127.0.0.1" and i["protocol"] == "socks" and i["port"] > 1023 for i in ibs))
        creds = [(i["settings"]["accounts"][0]["user"], i["settings"]["accounts"][0]["pass"]) for i in ibs]
        self.assertEqual(len(set(creds)), 6)
        self.assertTrue(all(len(u) >= 8 and len(p) >= 16 for u, p in creds))
        self.assertEqual({i["settings"]["auth"] for i in ibs}, {"password"})
        self.assertNotIn("mark", json.dumps(cfg))
        self.assertEqual(len(cfg["outbounds"]), 6)
        self.assertEqual(cfg["dns"]["hosts"]["nl1.example.net"], "192.0.2.1")      # server names pinned from the resolve step
        self.assertFalse((self.rec / "badauth").exists())

    def test_fresh_credentials_each_run(self):
        self.run_http()
        a = json.loads((self.rec / "config.json").read_text())
        self.run_http()
        b = json.loads((self.rec / "config.json").read_text())
        self.assertNotEqual([i["settings"]["accounts"] for i in a["inbounds"]], [i["settings"]["accounts"] for i in b["inbounds"]])

    def test_teardown_after_timeouts(self):
        self.hang_all()
        res = self.run_http(pingTimeout=1)
        self.assertEqual({v["state"] for v in res.values()}, {"timeout"})
        self.assert_torn_down()

    def test_teardown_on_exception(self):
        class Boom(Exception):
            pass
        with mock.patch.object(ping, "ThreadPoolExecutor", side_effect=Boom):
            with self.assertRaises(Boom):
                self.run_http()
        self.assert_torn_down()
        self.assertEqual(control.read_state().get("pingBusyUntil"), 0)

    def test_core_exits_immediately(self):
        os.environ["FAKE_XRAY_MODE"] = "exit"
        res = self.run_http()
        self.assertEqual({v["state"] for v in res.values()}, {"error"})
        self.assertIn("why_core_exit=6", self.logs())
        self.assertFalse(os.path.exists((self.rec / "cfgdir").read_text()))

    def test_core_missing(self):
        os.environ["XVPN_XRAY"] = str(self.e.td / "nope")
        res = self.run_http()
        self.assertEqual({v["state"] for v in res.values()}, {"error"})
        self.assertIn("why_core_missing=6", self.logs())

    def test_unresolvable_server_is_error_others_measured(self):
        self.e.resolve_map({"nl1.example.net": ["192.0.2.1"], "us1.example.net": ["192.0.2.5"]})
        res = self.run_http()
        self.assertEqual(self.st(res, "Нидерланды-1"), "ok")
        self.assertEqual(self.st(res, "Германия-1"), "error")
        self.assertEqual(len(json.loads((self.rec / "config.json").read_text())["inbounds"]), 2)

    def test_sigterm_kills_instance_and_cleans_up(self):
        self.hang_all()
        self.set(pingTimeout=10)
        env = dict(os.environ, PYTHONPATH=str(VPN_DIR), PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.Popen([sys.executable, "-m", "xvpn", "ping", "--force"], cwd=VPN_DIR, env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if (self.rec / "cfgdir").exists() and (self.rec / "child.pid").exists():
                    break
                time.sleep(0.1)
            time.sleep(0.7)
            p.send_signal(signal.SIGTERM)
            p.wait(10)
        finally:
            if p.poll() is None:
                p.kill()
        self.assert_torn_down()

    def test_logs_have_no_secrets_hosts_or_urls(self):
        self.beh({"fi1.example.net": "hang"})
        self.set(pingUrl=self.t.url("/generate_204?token=SECRETTOKEN"))
        control.ping_all(force=True)
        cfg = json.loads((self.rec / "config.json").read_text())
        text = self.logs()
        self.assertIn("node measurement done", text)
        self.assertIn("method=httpGet", text)
        for i in cfg["inbounds"]:
            a = i["settings"]["accounts"][0]
            self.assertNotIn(a["user"], text)
            self.assertNotIn(a["pass"], text)
        for bad in ("example.net", "192.0.2.", "SECRETTOKEN", "127.0.0.1", str(self.t.port), "generate_204"):
            self.assertNotIn(bad, text)


class Methods(Base):
    def test_tcp_udp_is_na(self):
        self.set(pingMethod="tcp")
        with mock.patch.object(ping.metrics, "tcp_probe", lambda h, p, t=3: (12, None)):
            res = control.ping_all(force=True)
        self.assertEqual(self.st(res, "Japan-1"), "na")
        self.assertEqual(self.st(res, "USA-1"), "ok")
        self.assertEqual(res[self.by["USA-1"]["id"]]["ms"], 12)
        by = {n["id"]: n for n in control.status()["nodes"]}
        self.assertEqual(by[self.by["Japan-1"]["id"]]["pingState"], "na")
        self.assertFalse((self.rec / "pid").exists())

    def fake_ping(self):
        p = self.e.stub / "ping"
        p.write_text('#!/usr/bin/env bash\nip="${@: -1}"\nif [ "$ip" = 192.0.2.1 ]; then echo "64 bytes from $ip: icmp_seq=1 ttl=57 time=12.6 ms"; exit 0; fi\nexit 1\n')
        p.chmod(0o755)
        os.environ["XVPN_PING"] = str(p)

    def test_icmp(self):
        self.fake_ping()
        self.set(pingMethod="icmp")
        res = control.ping_all(force=True)
        self.assertEqual((self.st(res, "Нидерланды-1"), res[self.by["Нидерланды-1"]["id"]]["ms"]), ("ok", 13))
        self.assertEqual(self.st(res, "Германия-1"), "timeout")          # blocked / no reply
        self.assertEqual(self.st(res, "Japan-1"), "na")
        self.assertFalse((self.rec / "pid").exists())                    # no xray involved

    def test_icmp_without_binary_is_na(self):
        os.environ["XVPN_PING"] = ""
        self.set(pingMethod="icmp")
        with mock.patch.object(ping.shutil, "which", lambda n: None):
            res = control.ping_all(force=True)
        self.assertEqual(self.st(res, "USA-1"), "na")


class Cache(Base):
    def test_ttl_force_and_method_change(self):
        real = ping.measure
        calls = []
        with mock.patch.object(ping, "measure", lambda n, s: (calls.append((s["pingMethod"], len(n))), real(n, s))[1]):
            control.ping_all()
            self.assertEqual(calls, [("httpGet", 6)])
            control.ping_all()                                           # cached
            self.assertEqual(len(calls), 1)
            control.ping_all(force=True)                                 # force bypasses the cache
            self.assertEqual(len(calls), 2)
            self.set(pingMethod="httpHead")                              # other method: old numbers are not reused
            self.assertEqual({n["pingState"] for n in control.status()["nodes"]}, {"none"})
            control.ping_all()
            self.assertEqual(calls[-1], ("httpHead", 6))
            control.ping_all()
            self.assertEqual(len(calls), 3)
            self.set(pingUrl=self.t.url("/ok"))                          # other URL: measure again
            control.ping_all()
            self.assertEqual(len(calls), 4)

    def test_status_shows_measuring_then_result_and_settings(self):
        seen = {}
        real = ping.measure

        def spy(n, s):
            st = control.status()
            seen["m"], seen["states"] = st["measuring"], {x["pingState"] for x in st["nodes"]}
            return real(n, s)
        with mock.patch.object(ping, "measure", spy):
            control.ping_all()
        self.assertTrue(seen["m"])
        self.assertEqual(seen["states"], {"measuring"})
        st = control.status()
        self.assertFalse(st["measuring"])
        self.assertEqual({n["pingState"] for n in st["nodes"]}, {"ok"})
        self.assertEqual((st["ping"]["method"], st["ping"]["display"], st["ping"]["timeout"]), ("httpGet", "digits", 2))

    def test_concurrent_run_does_not_start_second_instance(self):
        import fcntl
        lk = open(paths.state_dir() / "ping.lock", "a")
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            with mock.patch.object(ping, "measure", side_effect=AssertionError("second instance")):
                res = control.ping_all(force=True)
        finally:
            lk.close()
        self.assertEqual({v["state"] for v in res.values()}, {"measuring"})

    def test_cli_ping_output(self):
        self.set(pingMethod="tcp")
        with mock.patch.object(ping.metrics, "tcp_probe", lambda h, p, t=3: (9, None)), mock.patch("builtins.print") as pr:
            cli.main(["ping", "--force"])
        out = json.loads(pr.call_args[0][0])
        self.assertIn("na", out["ping"].values())
        self.assertIn("na", out["states"].values())


class Doctor(Base):
    def test_row(self):
        rows = {r["key"]: r for r in cli.doctor()}
        self.assertEqual(rows["ping"]["level"], "ok")
        os.environ["XVPN_XRAY"] = str(self.e.td / "nope")
        self.assertNotEqual({r["key"]: r for r in cli.doctor()}["ping"]["level"], "ok")
        os.environ["XVPN_XRAY"] = str(self.e.stub / "xray")
        with mock.patch.object(ping.socket, "socket", side_effect=OSError):
            self.assertNotEqual({r["key"]: r for r in cli.doctor()}["ping"]["level"], "ok")


class AllNodesDirect(Base):
    def test_connect_routes_every_node_ip_direct(self):
        r = control.connect()
        self.assertTrue(r["ok"], r)
        cfg = json.loads((self.e.state / "config.json").read_text())
        want = ["192.0.2.%d" % i for i in range(1, 7)]
        rule = cfg["routing"]["rules"][1]
        self.assertEqual((rule["outboundTag"], sorted(rule["ip"])), ("direct", want))
        self.assertEqual(sorted(cfg["dns"]["hosts"].values()), want)
        self.assertEqual(sorted(json.loads((self.e.state / "runtime.json").read_text())["bypassIps"]), want)

    def test_literal_ip_nodes_and_unresolved_names(self):
        self.e.resolve_map({"x.example.net": ["192.0.2.50"]})
        net = resolve.all_nodes_net([{"address": "203.0.113.7"}, {"address": "x.example.net"}, {"address": "y.example.net"}])
        self.assertEqual(net, {"hosts": {"x.example.net": ["192.0.2.50"]}, "ips": ["203.0.113.7", "192.0.2.50"]})

    def test_probe_config_has_no_marks_and_routes_per_inbound(self):
        n = [self.by["Нидерланды-1"]]
        before = json.dumps(n[0]["outbound"])
        cfg = ping.build_probe_config(n, {"nl1.example.net": ["192.0.2.1"]}, [12345], [("u", "p")])
        self.assertNotIn("mark", json.dumps(cfg))
        self.assertEqual(cfg["routing"]["rules"], [{"type": "field", "inboundTag": ["in0"], "outboundTag": "out0"}])
        self.assertEqual(json.dumps(n[0]["outbound"]), before)           # the stored node is not modified


if __name__ == "__main__":
    unittest.main()
