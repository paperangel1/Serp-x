import copy
import json
import os
import unittest
from pathlib import Path

from common import LINKS, Env
from xvpn import config, core, links, paths

GOLDEN = Path(__file__).resolve().parent / "golden"
NODES = [links.parse_link(l) for l in LINKS]


def base_settings(**kw):
    s = dict(paths.DEFAULT_SETTINGS)
    s.update(kw)
    return s


CASES = {
    "ru_direct_geo": (0, base_settings(), True, [{"type": "field", "domain": ["domain:ads.example"], "outboundTag": "block"}]),
    "ru_direct_nogeo": (2, base_settings(), False, []),
    "all_user_lists": (5, base_settings(mode="all", bypassDomains=["bank.example", "full:lan.example"], proxyDomains=["geosite:netflix"]), True, []),
    "direct_mode": (4, base_settings(mode="direct"), False, []),
}
BOOT_NL = {"hosts": {"nl1.example.net": ["192.0.2.1"]}, "direct": [], "failed": []}
BOOT = {"hosts": {"jp1.example.net": ["192.0.2.9", "2001:db8::9"]}, "direct": ["jp1.example.net"], "failed": []}
BOOT_CASES = {"boot_domain": (0, base_settings(), True, BOOT_NL), "boot_domain_direct_dns": (5, base_settings(), True, BOOT)}


class Golden(unittest.TestCase):
    def test_golden_files(self):
        for name, (idx, settings, geo, rules) in CASES.items():
            cfg = config.build_config(NODES[idx], settings, rules, geo_present=geo)
            path = GOLDEN / f"{name}.json"
            text = json.dumps(cfg, indent=1, ensure_ascii=False, sort_keys=True) + "\n"
            if os.environ.get("XVPN_UPDATE_GOLDEN") == "1":
                path.write_text(text)
            self.assertEqual(path.read_text(), text, f"golden mismatch: {name} (XVPN_UPDATE_GOLDEN=1 to refresh)")


class BootGolden(unittest.TestCase):
    def test_golden_files(self):
        for name, (idx, settings, geo, boot) in BOOT_CASES.items():
            cfg = config.build_config(NODES[idx], settings, [], geo_present=geo, boot=boot)
            path = GOLDEN / f"{name}.json"
            text = json.dumps(cfg, indent=1, ensure_ascii=False, sort_keys=True) + "\n"
            if os.environ.get("XVPN_UPDATE_GOLDEN") == "1":
                path.write_text(text)
            self.assertEqual(path.read_text(), text, f"golden mismatch: {name}")


ALL_NODES = {"hosts": {"nl1.example.net": ["192.0.2.1"], "de1.example.net": ["192.0.2.2"], "jp1.example.net": ["192.0.2.9", "2001:db8::9"]},
             "ips": ["203.0.113.7", "192.0.2.1", "192.0.2.2", "192.0.2.9", "2001:db8::9"]}


class AllNodesGolden(unittest.TestCase):
    def test_golden_all_nodes_direct(self):
        cfg = config.build_config(NODES[0], base_settings(), [], geo_present=True, boot=BOOT_NL, all_nodes=ALL_NODES)
        path = GOLDEN / "all_nodes_direct.json"
        text = json.dumps(cfg, indent=1, ensure_ascii=False, sort_keys=True) + "\n"
        if os.environ.get("XVPN_UPDATE_GOLDEN") == "1":
            path.write_text(text)
        self.assertEqual(path.read_text(), text, "golden mismatch: all_nodes_direct")
        rule = cfg["routing"]["rules"][1]
        self.assertEqual(rule, {"type": "field", "ip": ["192.0.2.1", "203.0.113.7", "192.0.2.2", "192.0.2.9", "2001:db8::9"], "outboundTag": "direct"})
        self.assertEqual(cfg["dns"]["hosts"]["nl1.example.net"], "192.0.2.1")
        self.assertEqual(cfg["dns"]["hosts"]["jp1.example.net"], ["192.0.2.9", "2001:db8::9"])


class Bootstrap(unittest.TestCase):
    def test_domain_pinned_and_routed_direct(self):
        cfg = config.build_config(NODES[0], base_settings(), [], boot=BOOT_NL)
        self.assertEqual(cfg["dns"]["hosts"]["nl1.example.net"], "192.0.2.1")
        rules = cfg["routing"]["rules"]
        self.assertEqual(rules[0]["ip"], ["77.88.8.8", "77.88.8.1"])                 # direct resolvers stay first
        self.assertEqual(rules[1], {"type": "field", "ip": ["192.0.2.1"], "outboundTag": "direct"})
        self.assertEqual(cfg["outbounds"][0]["settings"]["vnext"][0]["address"], "nl1.example.net")   # SNI/address untouched
        self.assertFalse(any(isinstance(s, dict) and str(s.get("domains", [""])[0]).startswith("full:") for s in cfg["dns"]["servers"]))

    def test_direct_fallback_entry_comes_first(self):
        cfg = config.build_config(NODES[5], base_settings(), [], boot=BOOT)
        self.assertEqual(cfg["dns"]["servers"][0], {"address": "77.88.8.8", "domains": ["full:jp1.example.net"], "skipFallback": True})
        self.assertEqual(cfg["dns"]["hosts"]["jp1.example.net"], ["192.0.2.9", "2001:db8::9"])

    def test_ip_literal_and_no_boot_change_nothing(self):
        self.assertNotIn("hosts", config.build_config(NODES[0], base_settings(), [])["dns"])
        n = copy.deepcopy(NODES[0])
        n["outbound"]["settings"]["vnext"][0]["address"] = "198.51.100.7"
        from xvpn import resolve
        self.assertEqual(resolve.outbound_domains([n["outbound"]]), [])
        self.assertEqual(config.build_config(n, base_settings(), [], boot={"hosts": {}, "direct": [], "failed": []}),
                         config.build_config(n, base_settings(), []))

    def test_root_allowlist_accepts_it(self):
        config.check_root_safe(config.build_config(NODES[5], base_settings(), [], boot=BOOT))


class Structure(unittest.TestCase):
    def cfg(self, **kw):
        return config.build_config(NODES[0], base_settings(**kw), [], geo_present=True)

    def rules(self, cfg):
        return cfg["routing"]["rules"]

    def test_all_outbound_sockets_are_marked(self):
        cfg = self.cfg()
        for ob in cfg["outbounds"]:
            if ob["protocol"] in ("blackhole",):
                continue
            self.assertEqual(ob["streamSettings"]["sockopt"]["mark"], paths.MARK, ob["tag"])

    def test_last_rule_is_the_default(self):
        self.assertEqual(self.rules(self.cfg())[-1]["outboundTag"], "proxy")
        self.assertEqual(self.rules(self.cfg(mode="direct"))[-1]["outboundTag"], "direct")

    def test_ru_direct_has_suffixes_and_geo(self):
        r = json.dumps(self.rules(self.cfg()))
        for needle in ("domain:ru", "domain:su", "domain:xn--p1ai", "geosite:category-ru", "geoip:ru"):
            self.assertIn(needle, r)

    def test_no_geo_rules_when_lists_are_missing(self):
        cfg = config.build_config(NODES[0], base_settings(), [], geo_present=False)
        r = json.dumps(cfg)
        self.assertNotIn("geoip:", r)
        self.assertNotIn("geosite:", r)
        self.assertIn("domain:ru", r)

    def test_all_mode_has_no_ru_rules(self):
        self.assertNotIn("domain:ru", json.dumps(self.rules(self.cfg(mode="all"))))

    def test_private_networks_are_always_direct(self):
        priv = [r for r in self.rules(self.cfg(mode="all")) if "192.168.0.0/16" in r.get("ip", [])]
        self.assertEqual(priv[0]["outboundTag"], "direct")

    def test_user_lists_come_before_subscription_rules_and_ru(self):
        cfg = config.build_config(NODES[0], base_settings(bypassDomains=["a.example"]),
                                  [{"type": "field", "domain": ["x"], "outboundTag": "block"}], geo_present=True)
        rules = self.rules(cfg)
        i_user = next(i for i, r in enumerate(rules) if "domain:a.example" in r.get("domain", []))
        i_sub = next(i for i, r in enumerate(rules) if r.get("outboundTag") == "block")
        i_ru = next(i for i, r in enumerate(rules) if "domain:ru" in r.get("domain", []))
        self.assertTrue(i_user < i_sub < i_ru)

    def test_dns_hijack_and_direct_resolvers(self):
        rules = self.rules(self.cfg())
        self.assertEqual(rules[0], {"type": "field", "ip": ["77.88.8.8", "77.88.8.1"], "outboundTag": "direct"})
        self.assertTrue(any(r.get("outboundTag") == "dns-out" for r in rules))

    def test_ru_names_use_direct_resolvers_foreign_use_doh(self):
        servers = self.cfg()["dns"]["servers"]
        self.assertEqual(servers[0]["address"], "77.88.8.8")
        self.assertTrue(servers[0]["skipFallback"])
        self.assertIn("domain:ru", servers[0]["domains"])
        self.assertTrue(any(isinstance(s, str) and s.startswith("https://") for s in servers))
        # no system resolver entry: it would loop through the tunnel
        self.assertNotIn("localhost", json.dumps(servers))
        self.assertNotIn("localhost", json.dumps(self.cfg(mode="direct")["dns"]))

    def test_custom_direct_resolver(self):
        cfg = self.cfg(dnsDirect=["9.9.9.9"])
        self.assertEqual(self.rules(cfg)[0]["ip"], ["9.9.9.9"])

    def test_inbounds_are_tun_and_loopback_socks(self):
        ibs = self.cfg()["inbounds"]
        self.assertEqual([i["protocol"] for i in ibs], ["tun", "socks"])
        self.assertEqual(ibs[1]["listen"], "127.0.0.1")
        self.assertEqual(ibs[0]["settings"]["name"], paths.TUN_NAME)

    def test_test_variant_has_no_inbounds_and_original_is_untouched(self):
        cfg = self.cfg()
        t = config.test_variant(cfg)
        self.assertEqual(t["inbounds"], [])
        self.assertEqual(len(cfg["inbounds"]), 2)

    def test_node_outbound_not_mutated(self):
        n = copy.deepcopy(NODES[0])
        config.build_config(n, base_settings(), [])
        self.assertNotIn("sockopt", n["outbound"].get("streamSettings", {}))

    def test_every_protocol_builds(self):
        for n in NODES:
            cfg = config.build_config(n, base_settings(), [])
            self.assertEqual(cfg["outbounds"][0]["tag"], "proxy")


class Validate(unittest.TestCase):
    def test_refuses_configs_with_inbounds(self):
        with Env():
            cfg = config.build_config(NODES[0], base_settings(), [])
            with self.assertRaises(RuntimeError):
                core.validate(cfg)

    def test_ok_and_failure_with_stub_xray(self):
        with Env() as e:
            t = config.test_variant(config.build_config(NODES[0], base_settings(), []))
            self.assertEqual(core.validate(t), (True, "ok"))
            e.xray(ok=False, text='bad config near "password": "hunter2" id 11111111-2222-3333-4444-555555555555')
            ok, msg = core.validate(t)
            self.assertFalse(ok)
            self.assertNotIn("hunter2", msg)
            self.assertNotIn("11111111-2222", msg)

    def test_command_line_is_run_test_only(self):
        seen = []

        def runner(cmd, **kw):
            seen.append(cmd)
            class R: returncode = 0; stdout = "Configuration OK."; stderr = ""
            return R()

        with Env():
            core.validate(config.test_variant(config.build_config(NODES[0], base_settings(), [])), runner=runner)
        self.assertEqual(seen[0][-4:-1], ["run", "-test", "-c"])


class Capabilities(unittest.TestCase):
    def test_scan_does_not_execute_the_binary(self):
        with Env() as e:
            (e.stub / "xray").write_bytes(b"\x7fELF Xray 26.3.27 xray-core/proxy/tun/ xray-core/proxy/hysteria/ xray-core/transport/internet/reality/")
            c = core.capabilities()
            self.assertEqual(c["version"], "26.3.27")
            self.assertTrue(c["tun"] and c["hysteria"] and c["reality"])
            self.assertFalse(c["trojan"])


class RootAllowlist(unittest.TestCase):
    def good(self):
        return config.build_config(NODES[0], base_settings(), [])

    def test_generated_configs_pass(self):
        for n in NODES:
            self.assertTrue(config.check_root_safe(config.build_config(n, base_settings(), [])))

    def reject(self, mutate):
        cfg = self.good()
        mutate(cfg)
        with self.assertRaises(config.ConfigRejected):
            config.check_root_safe(cfg)

    def test_rejections(self):
        self.reject(lambda c: c.update(api={"tag": "api"}))
        self.reject(lambda c: c["log"].update(access="/etc/passwd"))
        self.reject(lambda c: c["inbounds"].append({"protocol": "http", "port": 1}))
        self.reject(lambda c: c["inbounds"][1].update(listen="0.0.0.0"))
        self.reject(lambda c: c["inbounds"][0]["settings"].update(name="eth0"))
        self.reject(lambda c: c["outbounds"].append({"protocol": "loopback", "tag": "x"}))
        self.reject(lambda c: c["outbounds"][0]["streamSettings"].setdefault("tlsSettings", {}).update(certificates=[{"certificateFile": "/etc/shadow"}]))
        self.reject(lambda c: c["outbounds"][0]["settings"].update(address="/run/x.sock"))

    def test_log_none_is_fine(self):
        cfg = self.good()
        cfg["log"] = {"access": "none", "loglevel": "warning"}
        self.assertTrue(config.check_root_safe(cfg))


if __name__ == "__main__":
    unittest.main()
