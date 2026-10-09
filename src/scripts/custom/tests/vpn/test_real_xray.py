"""Opt-in (XVPN_REAL_XRAY=1): validates every generated outbound shape with the REAL xray binary.
Only `xray run -test` on the inbound-less variant, wrapped in an isolated user+net namespace
(core.validate enforces both). Skipped by default so the suite never depends on the installed xray."""
import os
import unittest

from common import LINKS, Env
from xvpn import config, core, links, paths

NODES_ = [links.parse_link(l) for l in LINKS]


@unittest.skipUnless(os.environ.get("XVPN_REAL_XRAY") == "1" and os.path.isfile("/usr/bin/xray"), "set XVPN_REAL_XRAY=1")
class RealXray(unittest.TestCase):
    def test_every_protocol_passes_xray_test(self):
        with Env():
            os.environ["XVPN_XRAY"] = "/usr/bin/xray"
            os.environ.pop("XVPN_NO_UNSHARE", None)
            for mode in ("ru-direct", "all", "direct"):
                for l in LINKS:
                    n = links.parse_link(l)
                    cfg = config.build_config(n, dict(paths.DEFAULT_SETTINGS, mode=mode, bypassDomains=["bank.example"], proxyDomains=["full:x.example"]), [], geo_present=False)
                    ok, msg = core.validate(config.test_variant(cfg))
                    self.assertTrue(ok, f"{n['protocol']}/{mode}: {msg}")
            boot = {"hosts": {"nl1.example.net": ["192.0.2.1"], "jp1.example.net": ["2001:db8::1", "192.0.2.9"]}, "direct": ["jp1.example.net"], "failed": []}
            for i in (0, 5):
                cfg = config.build_config(NODES_[i], dict(paths.DEFAULT_SETTINGS), [], geo_present=False, boot=boot)
                ok, msg = core.validate(config.test_variant(cfg))
                self.assertTrue(ok, f"bootstrap config {i}: {msg}")
            from xvpn import ping
            allnodes = {"hosts": {"nl1.example.net": ["192.0.2.1"]}, "ips": ["192.0.2.1", "203.0.113.7"]}
            cfg = config.build_config(NODES_[0], dict(paths.DEFAULT_SETTINGS), [], geo_present=False, boot=boot, all_nodes=allnodes)
            ok, msg = core.validate(config.test_variant(cfg))
            self.assertTrue(ok, f"all-nodes config: {msg}")
            pcfg = ping.build_probe_config([links.parse_link(l) for l in LINKS], {"nl1.example.net": ["192.0.2.1"]},
                                           list(range(20001, 20007)), [("u%d" % i, "p%d" % i) for i in range(6)])
            ok, msg = core.validate(config.test_variant(pcfg))          # -test only, inbound-less variant
            self.assertTrue(ok, f"probe config: {msg}")
            self.assertEqual(core.capabilities()["version"], "26.3.27") if core.capabilities()["version"] else None


if __name__ == "__main__":
    unittest.main()
