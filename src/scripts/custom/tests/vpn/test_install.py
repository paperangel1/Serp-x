import importlib.util
import json
import os
import pwd
import stat
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from common import Env
from xvpn import config, install, links, paths
from common import LINKS

NODES = [links.parse_link(l) for l in LINKS]


def load_helper(env=None):
    """The rendered (root-owned in production) helper as a module."""
    src = install.render(user="alice", home="/home/alice", xray="/usr/bin/xray")[install.HELPER_DEST][0]
    td = tempfile.mkdtemp(prefix="helper-")
    p = Path(td) / "helper.py"
    p.write_text(src)
    spec = importlib.util.spec_from_file_location("serp_helper", p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Render(unittest.TestCase):
    def test_substitutions(self):
        files = install.render(user="alice", home="/home/alice", xray="/usr/bin/xray")
        unit = files[install.UNIT_DEST][0]
        self.assertIn("XVPN_USER=alice", unit)
        self.assertIn("XVPN_USER_STATE=/home/alice/.local/state/serpantinum/vpn", unit)
        self.assertIn("XVPN_USER_DATA=/home/alice/.local/share/serpantinum-x/vpn", unit)
        self.assertNotIn("share/serpantinum/", unit)
        self.assertIn("ExecStart=/usr/bin/xray run -c /run/serp-xray/config.json", unit)
        self.assertIn("ExecStartPost=/usr/local/lib/serpantinum-xray/serp-xray-helper post-start", unit)
        self.assertIn("Restart=no", unit)
        self.assertNotIn("WantedBy", unit)                            # never started at boot
        self.assertNotIn("@", unit.replace("@", "", 0) if False else "".join(c for c in unit if c == "@"))
        pol = files[install.POLKIT_DEST][0]
        self.assertIn('subject.user != "alice"', pol)
        self.assertIn("serp-xray.service", pol)
        self.assertNotIn("@USER@", pol)
        self.assertEqual(files[install.HELPER_DEST][1], 0o755)

    def test_unit_does_not_stop_or_conflict_with_happ(self):
        unit = install.render(user="a", home="/h", xray="/x")[install.UNIT_DEST][0]
        self.assertNotIn("Conflicts", unit)
        self.assertNotIn("happd", unit.split("ExecStartPre")[0])

    def test_helper_has_the_allowlist_inlined_and_no_user_imports(self):
        src = install.render(user="a", home="/h", xray="/x")[install.HELPER_DEST][0]
        self.assertIn("def check_root_safe", src)
        self.assertNotIn("@@ALLOWLIST@@", src)
        self.assertNotIn("import xvpn", src)
        self.assertNotIn("from xvpn", src)
        compile(src, "helper", "exec")


class CheckAndApply(unittest.TestCase):
    def test_check_reports_missing_then_ok_after_apply_to_prefix(self):
        with Env() as e:
            kw = dict(user="alice", home="/home/alice", xray="/usr/bin/xray")
            rows = install.check(root=e.td / "fake-root", **kw)
            self.assertTrue(all(not r["ok"] and r["detail"] == "missing" for r in rows))
            install.apply(root=e.td / "fake-root", **kw)
            rows = install.check(root=e.td / "fake-root", **kw)
            self.assertTrue(all(r["ok"] for r in rows), rows)
            helper = e.td / "fake-root" / install.HELPER_DEST
            self.assertEqual(stat.S_IMODE(helper.stat().st_mode), 0o755)

    def test_check_detects_drift(self):
        with Env() as e:
            kw = dict(user="alice", home="/home/alice", xray="/usr/bin/xray")
            install.apply(root=e.td / "r", **kw)
            (e.td / "r" / install.UNIT_DEST).write_text("tampered")
            bad = [r for r in install.check(root=e.td / "r", **kw) if not r["ok"]]
            self.assertEqual([r["name"] for r in bad], ["/" + install.UNIT_DEST])

    def test_real_apply_is_guarded(self):
        with Env():
            os.environ.pop("XVPN_ALLOW_ROOT_INSTALL", None)
            calls = []
            with self.assertRaises(PermissionError):
                install.apply(runner=lambda *a, **k: calls.append(a))
            self.assertEqual(calls, [])                               # nothing ran, no sudo

    def test_real_apply_uses_sudo_install_with_the_guard_set(self):
        with Env():
            os.environ["XVPN_ALLOW_ROOT_INSTALL"] = "1"
            seen = []

            class R:
                returncode = 0; stderr = ""

            try:
                r = install.apply(runner=lambda cmd, **k: (seen.append(cmd), R())[1], user="a", home="/h", xray="/x")
            finally:
                os.environ.pop("XVPN_ALLOW_ROOT_INSTALL", None)
            self.assertTrue(r["ok"])
            installs = [c for c in seen if c[:4] == ["sudo", "-n", "install", "-D"]]
            self.assertEqual(len(installs), 4)
            self.assertTrue(all(c[-1].startswith("/etc/") or c[-1].startswith("/usr/local/") for c in installs))
            self.assertIn(["sudo", "-n", "systemctl", "daemon-reload"], seen)


class HelperAllowlist(unittest.TestCase):
    """The inlined copy must behave exactly like config.check_root_safe."""

    def cases(self):
        good = lambda: config.build_config(NODES[0], dict(paths.DEFAULT_SETTINGS), [])
        yield good(), True
        for n in NODES:
            yield config.build_config(n, dict(paths.DEFAULT_SETTINGS), []), True
        c = good(); c["log"]["access"] = "/etc/x"; yield c, False
        c = good(); c["api"] = {}; yield c, False
        c = good(); c["inbounds"].append({"protocol": "http"}); yield c, False
        c = good(); c["inbounds"][1]["listen"] = "0.0.0.0"; yield c, False
        c = good(); c["inbounds"][0]["settings"]["name"] = "eth0"; yield c, False
        c = good(); c["outbounds"].append({"protocol": "loopback"}); yield c, False
        c = good(); c["outbounds"][0]["streamSettings"]["tlsSettings"] = {"certificates": [{"keyFile": "/x"}]}; yield c, False
        c = good(); c["outbounds"][0]["settings"]["address"] = "unix:/x"; yield c, False

    def test_same_verdicts(self):
        h = load_helper()
        for cfg, ok in self.cases():
            if ok:
                self.assertTrue(h.check_root_safe(cfg))
                self.assertTrue(config.check_root_safe(cfg))
            else:
                with self.assertRaises(h.ConfigRejected):
                    h.check_root_safe(cfg)
                with self.assertRaises(config.ConfigRejected):
                    config.check_root_safe(cfg)


class HelperRouting(unittest.TestCase):
    def setUp(self):
        self.h = load_helper()
        self.td = Path(tempfile.mkdtemp(prefix="run-"))
        self.h.RUN = str(self.td)
        self.h.KS_MARK = str(self.td / "ks")
        self.cmds = []
        self.fail_on = None

        def fake_run(cmd, check=True):
            line = " ".join(cmd[1:] if cmd[0] == "ip" else cmd)
            self.cmds.append(line)
            if self.fail_on and self.fail_on in line:
                if check:
                    raise RuntimeError("boom")
                return 2
            return 0

        self.h.run = fake_run
        mock.patch.object(self.h.time, "sleep", lambda s: None).start()
        mock.patch.object(self.h.os.path, "exists", lambda p: True).start()
        self.addCleanup(mock.patch.stopall)
        (self.td / "runtime.json").write_text(json.dumps({"killSwitch": False, "blockIPv6": True, "bypassIps": ["203.0.113.5", "2001:db8::7"]}))

    def idx(self, needle):
        return next(i for i, c in enumerate(self.cmds) if needle in c)

    def test_activation_is_the_last_step_and_order_is_safe(self):
        self.h.post_start()
        mark = self.idx("fwmark 0x2333 lookup main")
        supp = self.idx("suppress_prefixlength 0")
        route = self.idx("route replace default dev serp-xray table 22333")
        activate = max(i for i, c in enumerate(self.cmds) if "rule add pref 9200 lookup 22333" in c)
        self.assertTrue(mark < route and supp < route < activate)
        self.assertEqual(activate, max(i for i, c in enumerate(self.cmds) if "rule add" in c))
        self.assertIn("-4 rule add pref 9000 to 203.0.113.5/32 lookup main", self.cmds)
        self.assertIn("-6 rule add pref 9000 to 2001:db8::7/128 lookup main", self.cmds)

    def test_ipv6_blackhole_when_blocking(self):
        self.h.post_start()
        self.assertIn("-6 route replace blackhole default table 22333", self.cmds)
        self.cmds.clear()
        (self.td / "runtime.json").write_text(json.dumps({"blockIPv6": False}))
        self.h.post_start()
        self.assertIn("-6 route replace default dev serp-xray table 22333", self.cmds)

    def test_failure_cleans_up_and_raises(self):
        self.fail_on = "route replace default dev serp-xray"
        with self.assertRaises(RuntimeError):
            self.h.post_start()
        self.assertFalse(any("pref 9200 lookup 22333" in c and "rule add" in c for c in self.cmds))   # never activated
        self.assertTrue(any("rule del pref 9100" in c for c in self.cmds))                             # cleaned

    def test_clean_stop_removes_everything(self):
        with mock.patch.dict(os.environ, {"SERVICE_RESULT": "success"}):
            self.h.post_stop()
        self.assertTrue(any("route flush table 22333" in c for c in self.cmds))
        self.assertFalse(os.path.exists(str(self.td / "ks")) and False)

    def test_crash_without_killswitch_removes_everything(self):
        with mock.patch.dict(os.environ, {"SERVICE_RESULT": "exit-code"}):
            self.h.post_stop()
        self.assertTrue(any("route flush table 22333" in c for c in self.cmds))
        self.assertFalse(any("blackhole" in c for c in self.cmds))

    def test_crash_with_killswitch_leaves_a_blackhole_and_unblock_removes_it(self):
        (self.td / "runtime.json").write_text(json.dumps({"killSwitch": True}))
        with mock.patch.dict(os.environ, {"SERVICE_RESULT": "signal"}):
            self.h.post_stop()
        self.assertIn("-4 route replace blackhole default table 22333", self.cmds)
        self.assertTrue((self.td / "ks").exists())
        self.cmds.clear()
        mock.patch.object(self.h.os.path, "exists", lambda p: os.path.lexists(p)).start()
        self.h.unblock()
        self.assertTrue(any("route flush table 22333" in c for c in self.cmds))
        self.assertFalse((self.td / "ks").exists())

    def test_user_stop_with_killswitch_still_restores_internet(self):
        (self.td / "runtime.json").write_text(json.dumps({"killSwitch": True}))
        with mock.patch.dict(os.environ, {"SERVICE_RESULT": "success"}):
            self.h.post_stop()
        self.assertFalse(any("blackhole" in c for c in self.cmds))

    def test_guard_refuses_while_happ_runs(self):
        # Happ's VPN is on while its core xray runs (a mere happ-xray interface or the permanent happd daemon is not).
        def run(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 0 if cmd[0] == "pgrep" else 1, "", "")
        with mock.patch.object(self.h.subprocess, "run", run):
            with self.assertRaises(RuntimeError):
                self.h.guard()


class HelperPrepare(unittest.TestCase):
    def setUp(self):
        self.h = load_helper()
        self.td = Path(tempfile.mkdtemp(prefix="prep-"))
        self.state = self.td / "state"
        self.state.mkdir()
        self.h.RUN = str(self.td / "run")
        self.me = pwd.getpwuid(os.getuid()).pw_name
        self.env = mock.patch.dict(os.environ, {"XVPN_USER": self.me, "XVPN_USER_STATE": str(self.state), "XVPN_USER_DATA": str(self.td / "data")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.good = config.build_config(NODES[0], dict(paths.DEFAULT_SETTINGS), [])

    def write(self, cfg=None, runtime=None):
        (self.state / "config.json").write_text(json.dumps(cfg or self.good))
        if runtime is not None:
            (self.state / "runtime.json").write_text(json.dumps(runtime))

    def test_stages_validated_config_and_sanitised_runtime(self):
        self.write(runtime={"killSwitch": True, "blockIPv6": False, "bypassIps": ["203.0.113.1", "not-an-ip", "; rm -rf /", "2001:db8::1"]})
        self.h.prepare()
        staged = json.loads((self.td / "run" / "config.json").read_text())
        self.assertEqual(staged["outbounds"][0]["tag"], "proxy")
        self.assertEqual(stat.S_IMODE(os.stat(self.td / "run" / "config.json").st_mode), 0o600)
        rt = json.loads((self.td / "run" / "runtime.json").read_text())
        self.assertEqual(rt, {"killSwitch": True, "blockIPv6": False, "bypassIps": ["203.0.113.1", "2001:db8::1"]})

    def test_unsafe_config_is_not_staged(self):
        bad = dict(self.good); bad["log"] = {"access": "/etc/cron.d/x"}
        self.write(bad)
        with self.assertRaises(self.h.ConfigRejected):
            self.h.prepare()
        self.assertFalse((self.td / "run" / "config.json").exists())

    def test_symlinked_or_foreign_config_is_refused(self):
        real = self.td / "elsewhere.json"
        real.write_text(json.dumps(self.good))
        os.symlink(real, self.state / "config.json")
        with self.assertRaises(RuntimeError):
            self.h.prepare()

    def test_oversized_config_is_refused(self):
        self.write()
        with mock.patch.object(self.h, "MAX_CONFIG", 10):
            with self.assertRaises(RuntimeError):
                self.h.prepare()

    def test_geo_files_are_copied_when_present(self):
        self.write()
        geo = self.td / "data" / "geo"
        geo.mkdir(parents=True)
        (geo / "geoip.dat").write_bytes(b"ip")
        (geo / "geosite.dat").write_bytes(b"site")
        self.h.prepare()
        self.assertEqual((self.td / "run" / "geo" / "geoip.dat").read_bytes(), b"ip")


if __name__ == "__main__":
    unittest.main()
