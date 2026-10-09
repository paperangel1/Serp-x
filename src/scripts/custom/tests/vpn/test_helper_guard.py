import importlib.util
import os
import subprocess
import unittest
from unittest import mock

HELPER = os.path.join(os.path.dirname(__file__), "..", "..", "vpn", "system", "serp-xray-helper.py")


def load():
    spec = importlib.util.spec_from_file_location("serp_xray_helper", HELPER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fake_run(core=False, route=""):
    def run(cmd, **kw):
        if cmd[0] == "pgrep":
            return subprocess.CompletedProcess(cmd, 0 if core else 1, "", "")
        if cmd[0] == "ip":
            return subprocess.CompletedProcess(cmd, 0, route, "")
        raise AssertionError(f"guard must not call {cmd}")  # notably: never systemctl is-active happd
    return run


class HelperGuard(unittest.TestCase):
    def test_daemon_alone_is_not_a_conflict(self):
        m = load()
        with mock.patch.object(m.subprocess, "run", fake_run()), mock.patch.object(m.os.path, "exists", return_value=False):
            m.guard()

    def test_happ_core_running_is_a_conflict(self):
        m = load()
        with mock.patch.object(m.subprocess, "run", fake_run(core=True)):
            with self.assertRaises(RuntimeError):
                m.guard()

    def test_tunnel_with_default_route_is_a_conflict(self):
        m = load()
        with mock.patch.object(m.subprocess, "run", fake_run(route="default dev happ-xray metric 1")), \
                mock.patch.object(m.os.path, "exists", return_value=True):
            with self.assertRaises(RuntimeError):
                m.guard()

    def test_stale_tunnel_without_route_is_fine(self):
        m = load()
        with mock.patch.object(m.subprocess, "run", fake_run(route="")), mock.patch.object(m.os.path, "exists", return_value=True):
            m.guard()


if __name__ == "__main__":
    unittest.main()
