"""Regression tests for the field defects: Happ detection, informational entries, default node,
TCP measurement while disconnected, polkit 'unreadable', deterministic helper render."""
import json
import os
import socket
import stat
import subprocess
import sys
import time
import unittest
from unittest import mock

from common import FAKE_UUID, Env, free_port
from xvpn import cli, control, install, links, metrics, paths, subscription, system


def vless(name, host="nl1.example.net", port=443, uuid=FAKE_UUID):
    return links.parse_link(f"vless://{uuid}@{host}:{port}?type=tcp&security=tls&sni={host}#{name}")


def ss(name, host="198.51.100.7", port=8388):
    import base64
    cred = base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:pw").decode().rstrip("=")
    return links.parse_link(f"ss://{cred}@{host}:{port}#{name}")


class HappState(unittest.TestCase):
    def setUp(self):
        self.e = Env().__enter__()

    def tearDown(self):
        self.e.__exit__()

    def test_daemon_only_is_not_a_conflict(self):
        self.e.set_unit("happd.service", "active")
        hs = system.happ_state()
        self.assertEqual(hs, {"daemon": True, "core": False, "iface": False, "defaultRoute": False})
        self.assertFalse(system.happ_conflict(hs))
        self.assertFalse(system.happ_active())

    def test_core_running_conflicts(self):
        self.e.set_unit("happd.service", "active")
        self.e.happ(core=True)
        self.assertTrue(system.happ_conflict())

    def test_iface_without_default_route_is_not_a_conflict(self):
        (self.e.sysnet / "happ-xray").mkdir()
        hs = system.happ_state()
        self.assertTrue(hs["iface"])
        self.assertFalse(hs["defaultRoute"])
        self.assertFalse(system.happ_conflict(hs))

    def test_iface_with_default_route_conflicts(self):
        (self.e.sysnet / "happ-xray").mkdir()
        self.e.happ(route=True)
        hs = system.happ_state()
        self.assertTrue(hs["defaultRoute"])
        self.assertTrue(system.happ_conflict(hs))

    def test_all_on(self):
        self.e.set_unit("happd.service", "active")
        (self.e.sysnet / "happ-xray").mkdir()
        self.e.happ(core=True, route=True)
        hs = system.happ_state()
        self.assertTrue(all(hs.values()))

    def test_failed_reason_clears_when_happ_is_switched_off(self):
        control.write_state(state="failed", reason="happ_active")
        self.e.happ(core=True)
        self.assertEqual(control.status()["state"], "failed")
        self.e.happ(core=False)
        st = control.status()
        self.assertEqual((st["state"], st["reason"]), ("off", ""))
        self.assertFalse(st["happ"]["conflict"])

    def test_status_exposes_happ_dict(self):
        self.e.set_unit("happd.service", "active")
        st = control.status()
        self.assertTrue(st["happ"]["daemon"])
        self.assertFalse(st["happActive"])
        self.assertNotIn("happ_active", st["degraded"])


class Placeholders(unittest.TestCase):
    def test_real_world_names(self):
        info = [ss("Осталось дней: 26522", "0.0.0.0", 1), ss("Осталось дней: 26522", "198.51.100.9", 8388),
                vless("Traffic left 10 GB"), vless("Поддержка t.me/x"), vless("dummy", "127.0.0.1", 443),
                vless("zero", uuid="00000000-0000-0000-0000-000000000000")]
        real = [vless("[CDN] Yandex | Только LTE сети!"), vless("🌀 АВТО-ВЫБОР | WIFI", "a1.example.net"),
                vless("🇳🇱 Нидерланды-1", "b1.example.net"), vless("Frankfurt traffic-saver-free"[:0] + "🇩🇪 Германия", "c1.example.net")]
        got_real, got_info = links.split_placeholders(info + real)
        self.assertEqual(len(got_real), 4)
        self.assertEqual(len(got_info), 6)

    def test_parse_text_moves_them_into_info(self):
        body = "\n".join([
            "ss://" + __import__("base64").urlsafe_b64encode(b"aes-128-gcm:x").decode().rstrip("=") + "@198.51.100.9:8388#" + "%D0%9E%D1%81%D1%82%D0%B0%D0%BB%D0%BE%D1%81%D1%8C%20%D0%B4%D0%BD%D0%B5%D0%B9%3A%2026522",
            f"vless://{FAKE_UUID}@nl1.example.net:443?type=tcp&security=tls#NL"])
        r = links.parse_subscription_text(body)
        self.assertEqual([n["name"] for n in r["nodes"]], ["NL"])
        self.assertEqual(r["info"], ["Осталось дней: 26522"])

    def test_tags(self):
        self.assertIn("lte", links.node_tags(vless("[CDN] Yandex | Только LTE сети!")))
        self.assertIn("auto", links.node_tags(vless("🌀 АВТО-ВЫБОР | WIFI")))
        self.assertNotIn("lte", links.node_tags(vless("🇳🇱 Нидерланды")))
        h = links.parse_link("hysteria2://a@jp1.example.net:443/?sni=x#JP")
        self.assertIn("udp", links.node_tags(h))

    def test_load_nodes_filters_old_files_and_status_shows_info(self):
        with Env() as e:
            nodes = [ss("Осталось дней: 26522"), vless("NL", "n1.example.net")]
            paths.write_json(e.state / "nodes.json", {"version": 1, "updated": 1, "kind": "json", "nodes": nodes, "rules": []})
            st = control.status()
            self.assertEqual([n["name"] for n in st["nodes"]], ["NL"])
            self.assertEqual(st["subscription"]["info"], ["Осталось дней: 26522"])


class DefaultNode(unittest.TestCase):
    def setUp(self):
        self.hy = links.parse_link("hysteria2://a@jp1.example.net:443/?sni=x#JP")
        self.lte = vless("Только LTE", "l1.example.net")
        self.a = vless("A", "a1.example.net")
        self.b = vless("B", "b1.example.net")

    def test_best_measured_tcp(self):
        cache = {self.a["id"]: {"ping": 90}, self.b["id"]: {"ping": 30}, self.lte["id"]: {"ping": 5}}
        n, why = control.default_node([self.hy, self.lte, self.a, self.b], cache)
        self.assertEqual((n["name"], why), ("B", "best_ping"))

    def test_unmeasured_picks_first_non_lte_tcp(self):
        n, why = control.default_node([self.hy, self.lte, self.a, self.b], {})
        self.assertEqual((n["name"], why), ("A", "first_tcp"))

    def test_only_udp_and_lte(self):
        n, why = control.default_node([self.hy, self.lte], {})
        self.assertEqual((n["name"], why), ("Только LTE", "only_udp_or_lte"))

    def test_user_selection_wins_and_auto_reason_is_persisted(self):
        with Env() as e:
            e.install_units()
            paths.write_json(e.state / "nodes.json", {"version": 1, "updated": 1, "kind": "json", "nodes": [self.hy, self.lte, self.a], "rules": []})
            self.assertEqual(control.status()["node"]["name"], "A")
            self.assertEqual(control.status()["selection"], "first_tcp")
            control.write_state(selected=self.hy["id"], selectedAuto=False)
            st = control.status()
            self.assertEqual((st["node"]["protocol"], st["selection"]), ("hysteria2", "user"))


class Measure(unittest.TestCase):
    def test_tcp_parallel_timeout_udp(self):
        l1 = socket.socket(); l1.bind(("127.0.0.1", 0)); l1.listen(5)
        n_ok = vless("ok", "127.0.0.1", l1.getsockname()[1])
        n_closed = vless("closed", "127.0.0.1", free_port())
        n_hy = links.parse_link("hysteria2://a@127.0.0.1:443/?sni=x#JP")
        t0 = time.monotonic()
        res = metrics.ping_nodes([n_ok, n_closed, n_hy], timeout=1)
        self.assertLess(time.monotonic() - t0, 3)
        self.assertEqual(res[n_ok["id"]]["state"], "ok")
        self.assertGreater(res[n_ok["id"]]["ms"], 0)
        self.assertEqual(res[n_closed["id"]]["state"], "noreply")
        self.assertEqual(res[n_hy["id"]], {"ms": None, "state": "udp"})
        l1.close()

    def test_timeout_state(self):
        def probe(h, p, t):
            return None, "timeout"
        res = metrics.ping_nodes([vless("x", "h.example.net")], probe=probe)
        self.assertEqual(list(res.values())[0]["state"], "timeout")

    def test_ping_all_cache_ttl_and_status_states(self):
        with Env() as e:
            e.install_units()
            l1 = socket.socket(); l1.bind(("127.0.0.2", 0)); l1.listen(5)
            ok = vless("ok", "127.0.0.2", l1.getsockname()[1])
            dead = vless("dead", "127.0.0.2", free_port())
            hy = links.parse_link("hysteria2://a@127.0.0.2:443/?sni=x#JP")
            paths.write_json(e.state / "nodes.json", {"version": 1, "updated": 1, "kind": "json", "nodes": [ok, dead, hy], "rules": []})
            e.write_settings({"pingMethod": "tcp"})
            st0 = {n["name"]: n for n in control.status()["nodes"]}
            self.assertEqual(st0["ok"]["pingState"], "none")              # not measured yet: not "unavailable"
            self.assertEqual(st0["JP"]["pingState"], "na")
            calls = []
            real = metrics.tcp_probe
            with mock.patch.object(metrics, "tcp_probe", lambda h, p, t=3: (calls.append(p), real(h, p, t))[1]):
                control.ping_all()
                n1 = len(calls)
                control.ping_all()                                          # cached ~2 min
                self.assertEqual(len(calls), n1)
                control.ping_all(force=True)
                self.assertEqual(len(calls), 2 * n1)
            st = control.status()
            by = {n["name"]: n for n in st["nodes"]}
            self.assertEqual((by["ok"]["pingState"], by["dead"]["pingState"], by["JP"]["pingState"]), ("ok", "error", "na"))
            self.assertFalse(st["measuring"])
            l1.close()


class Polkit(unittest.TestCase):
    def test_unreadable_directory_is_unknown_not_missing(self):
        with Env() as e:
            e.install_units()
            d = e.etc / "etc/polkit-1/rules.d"
            os.chmod(d, 0)
            try:
                if os.access(d / "x", os.R_OK) or os.geteuid() == 0:
                    self.skipTest("cannot simulate EACCES here")
                self.assertIsNone(system.polkit_state())
                st = control.status()
                self.assertNotIn("polkit_missing", st["degraded"])
                self.assertIsNone(st["service"]["polkit"])
                rows = {r["name"]: r for r in install.check()}
                row = rows["/" + install.POLKIT_DEST]
                self.assertTrue(row["ok"] and row["unknown"])
                self.assertIn("не удалось проверить", row["detail"])
                d_rows = [r for r in cli.doctor() if r["key"] == "root:/" + install.POLKIT_DEST]
                self.assertEqual(d_rows[0]["level"], "info")
            finally:
                os.chmod(d, 0o755)

    def test_absent_file_is_missing(self):
        with Env() as e:
            self.assertIs(system.polkit_state(), False)


class HelperRender(unittest.TestCase):
    def test_render_is_deterministic_across_hash_seeds(self):
        code = ("import sys; sys.path.insert(0, %r); from xvpn import install, system; import hashlib;"
                "print(hashlib.sha256(install.render(user='a', home='/h', xray='/x')[install.HELPER_DEST][0].encode()).hexdigest())"
                % str(os.path.join(os.path.dirname(__file__), "..", "..", "vpn")))
        outs = {subprocess.run([sys.executable, "-c", code], env={**os.environ, "PYTHONHASHSEED": str(i), "PYTHONDONTWRITEBYTECODE": "1"},
                               capture_output=True, text=True).stdout.strip() for i in (1, 2, 3, 4)}
        self.assertEqual(len(outs), 1)

    def test_fresh_render_passes_check_and_old_set_order_is_accepted(self):
        with Env() as e:
            kw = dict(user="alice", home="/home/alice", xray="/usr/bin/xray")
            install.apply(root=e.td / "r", **kw)
            self.assertTrue(all(r["ok"] for r in install.check(root=e.td / "r", **kw)))
            p = e.td / "r" / install.HELPER_DEST
            txt = p.read_text().replace("ALLOWED_TOP = {'dns', 'inbounds', 'log', 'outbounds', 'routing'}",
                                        "ALLOWED_TOP = {'routing', 'dns', 'inbounds', 'outbounds', 'log'}")
            self.assertNotEqual(txt, p.read_text())
            p.write_text(txt)
            self.assertTrue(all(r["ok"] for r in install.check(root=e.td / "r", **kw)))
            p.write_text(txt.replace("'tun', ", "").replace("'socks', 'tun'", "'socks', 'tun', 'http'"))
            self.assertFalse(all(r["ok"] for r in install.check(root=e.td / "r", **kw)))


if __name__ == "__main__":
    unittest.main()
