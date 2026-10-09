"""Stage-0 build changes: unit/launchers point at the installed copy, `cmd install --check`, the one-off migrations
(VPN data dir, Gemini proxy, telemetry leftovers, cmdd unit) and the Gemini proxy default. Everything in temp dirs."""
import importlib.util
import json
import os
import unittest
from unittest import mock

import common as C
from xcmd import actions_b, paths, service

MIGRATE = os.path.join(C.REPO, "src", "scripts", "custom", "x_migrate.py")
XDG = ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XCMD_BIN_X", "XCMD_DESKTOP_DIR", "SERPANTINUM_INSTALL_DIR",
       "XVPN_DATA_DIR", "XMIGRATE_STATE", "XMIGRATE_SETTINGS", "XMIGRATE_VERSION_FILE", "X_GEMINI_PROXY", "XCMD_SETTINGS")


def load_migrate():
    spec = importlib.util.spec_from_file_location("x_migrate_under_test", MIGRATE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class PrepCase(C.Base):
    def setUp(self):
        super().setUp()
        p = mock.patch.dict(os.environ)
        p.start()
        self.addCleanup(p.stop)
        for k in XDG:
            os.environ.pop(k, None)
        self.home = self.env.root                       # Env already points HOME there
        os.environ["HOME"] = self.home

    def w(self, rel, text="x"):
        p = os.path.join(self.home, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        return p


class UnitAndLaunchers(PrepCase):
    def test_bin_x_prefers_the_installed_copy_over_the_checkout(self):
        self.assertEqual(paths.bin_x(), os.path.normpath(os.path.join(paths.CMD_DIR, "..", "..", "..", "..", "bin", "serpantinum-x")))
        inst = self.w(".local/share/serpantinum/bin/serpantinum-x")
        self.assertEqual(paths.bin_x(), inst)
        local = self.w(".local/bin/serpantinum-x")
        self.assertEqual(paths.bin_x(), local)
        os.environ["XCMD_BIN_X"] = "/opt/x/serpantinum-x"
        self.assertEqual(paths.bin_x(), "/opt/x/serpantinum-x")

    def test_rendered_unit_points_into_the_install(self):
        inst = self.w(".local/share/serpantinum/bin/serpantinum-x")
        self.assertIn("ExecStart=%s cmd daemon" % inst, service.render_unit())
        self.assertNotIn(C.REPO, service.render_unit())

    def test_desktop_entries_are_rendered_installed_and_removed(self):
        ents = service.desktop_entries()
        self.assertEqual(sorted(ents), ["serpantinum-commands-palette.desktop", "serpantinum-commands.desktop"])
        for text in ents.values():
            self.assertNotIn("@HOME@", text)
            self.assertIn('Exec="%s/.local/bin/serpantinum" ipc call xcmd ' % self.home, text)
            self.assertIn("[Desktop Entry]", text)
            keys = dict(l.split("=", 1) for l in text.splitlines() if "=" in l and not l.startswith("["))
            for k in ("Type", "Name", "Exec", "Icon", "Terminal", "Categories"):
                self.assertIn(k, keys)
        self.assertEqual(sorted(service.install_desktop()), sorted(ents))
        d = paths.desktop_dir()
        self.assertTrue(d.startswith(self.home))
        self.assertEqual(sorted(os.listdir(d)), sorted(ents))
        self.assertEqual(sorted(service.uninstall_desktop()), sorted(ents))
        self.assertEqual(os.listdir(d), [])

    def test_check_migrate_unit_and_idempotence(self):
        os.environ["XCMD_UNIT_DIR"] = self.env.units
        self.assertEqual(service.check()["installed"], False)
        self.assertEqual(service.migrate_unit(), "absent")
        os.makedirs(self.env.units, exist_ok=True)
        with open(service.unit_path(), "w") as f:
            f.write("[Service]\nExecStart=/somewhere/else/serpantinum-x cmd daemon\n")
        self.assertEqual(service.check()["current"], False)
        self.assertEqual(service.migrate_unit(), "rewritten")
        self.assertTrue(service.check()["current"])
        self.assertEqual(service.migrate_unit(), "ok")
        self.assertEqual(self.env.lines("systemctl.log"), ["--user daemon-reload"])      # only a reload, never a restart


class GeminiProxy(PrepCase):
    def test_default_is_no_proxy(self):
        self.assertEqual(actions_b.gemini_settings()["proxy"], "")

    def test_settings_and_env(self):
        self.w(".config/serpantinum/settings.json", json.dumps({"ai": {"proxy": "socks5h://127.0.0.1:9999"}}))
        self.assertEqual(actions_b.gemini_settings()["proxy"], "socks5h://127.0.0.1:9999")
        os.environ["X_GEMINI_PROXY"] = ""
        self.assertEqual(actions_b.gemini_settings()["proxy"], "")
        os.environ["X_GEMINI_PROXY"] = "socks5h://127.0.0.1:1"
        self.assertEqual(actions_b.gemini_settings()["proxy"], "socks5h://127.0.0.1:1")


class Migrations(PrepCase):
    def setUp(self):
        super().setUp()
        self.m = load_migrate()
        from xvpn import paths as vpn_paths              # HOME is read at import time there
        p = mock.patch.object(vpn_paths, "HOME", self.home)
        p.start()
        self.addCleanup(p.stop)
        self.m._tunnel_up = lambda *a, **k: False          # never probe the real 127.0.0.1:1080
        os.environ["XCMD_UNIT_DIR"] = self.env.units

    def test_vpn_data_moves_once_and_leaves_a_symlink(self):
        self.w(".local/share/serpantinum/vpn/geo/geoip.dat", "G")
        r = self.m.run()
        self.assertEqual(r["vpn_data"], "moved")
        new = os.path.join(self.home, ".local/share/serpantinum-x/vpn")
        old = os.path.join(self.home, ".local/share/serpantinum/vpn")
        self.assertEqual(open(os.path.join(new, "geo/geoip.dat")).read(), "G")
        self.assertTrue(os.path.islink(old) and os.path.realpath(old) == os.path.realpath(new))
        self.assertEqual(self.m.run()["vpn_data"], "already done")

    def test_vpn_data_not_overwritten_when_new_has_data(self):
        self.w(".local/share/serpantinum/vpn/a", "old")
        self.w(".local/share/serpantinum-x/vpn/b", "new")
        self.assertTrue(self.m.run()["vpn_data"].startswith("skipped"))
        self.assertTrue(os.path.exists(os.path.join(self.home, ".local/share/serpantinum/vpn/a")))

    def test_dry_run_changes_nothing(self):
        self.w(".local/share/serpantinum/vpn/a", "old")
        self.w(".local/state/serpantinum/version", 'SERPANTINUM_VERSION="2.2.4"\nTELEMETRY_ID="abc"\n')
        r = self.m.run(dry=True)
        self.assertEqual(r["vpn_data"], "would move")
        self.assertEqual(r["telemetry_state"], "would remove")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".local/share/serpantinum-x")))
        self.assertIn("TELEMETRY_ID", open(os.path.join(self.home, ".local/state/serpantinum/version")).read())
        self.assertFalse(os.path.exists(self.m.state_file()))

    def test_gemini_proxy_kept_for_an_existing_tunnel_only(self):
        sp = self.w(".config/serpantinum/settings.json", json.dumps({"general": {"language": "ru"}}))
        self.assertEqual(self.m.run()["gemini_proxy"], "nothing")                      # no tunnel -> nothing to keep
        os.remove(self.m.state_file())
        self.w(".config/systemd/user/gemini-proxy-tunnel.service", "[Service]\n")
        self.assertEqual(self.m.run()["gemini_proxy"], "kept socks5h://127.0.0.1:1080")
        data = json.load(open(sp))
        self.assertEqual(data["ai"]["proxy"], "socks5h://127.0.0.1:1080")
        self.assertEqual(data["general"], {"language": "ru"})                          # other settings intact

    def test_gemini_proxy_respects_an_explicit_choice_and_fresh_installs(self):
        self.w(".config/systemd/user/gemini-proxy-tunnel.service", "[Service]\n")
        self.assertEqual(self.m.run()["gemini_proxy"], "nothing")                      # no settings.json: fresh
        os.remove(self.m.state_file())
        sp = self.w(".config/serpantinum/settings.json", json.dumps({"ai": {"proxy": ""}}))
        self.assertTrue(self.m.run()["gemini_proxy"].startswith("skipped"))
        self.assertEqual(json.load(open(sp))["ai"]["proxy"], "")

    def test_telemetry_leftovers_removed_from_version_file(self):
        vf = self.w(".local/state/serpantinum/version", 'SERPANTINUM_VERSION="2.2.4"\nTELEMETRY_ID="abc"\nENABLE_TELEMETRY="true"\nSELECTED_COMPOSITORS="hyprland"\n')
        self.assertEqual(self.m.run()["telemetry_state"], "removed")
        self.assertEqual(open(vf).read(), 'SERPANTINUM_VERSION="2.2.4"\nSELECTED_COMPOSITORS="hyprland"\n')

    def test_cmdd_unit_step_follows_the_install(self):
        inst = self.w(".local/share/serpantinum/bin/serpantinum-x")
        os.makedirs(self.env.units, exist_ok=True)
        with open(service.unit_path(), "w") as f:
            f.write("[Service]\nExecStart=%s cmd daemon\n" % C.REPO)
        self.assertEqual(self.m.run()["cmdd_unit"], "rewritten")
        self.assertIn("ExecStart=%s cmd daemon" % inst, open(service.unit_path()).read())
        self.assertEqual(self.m.run()["cmdd_unit"], "ok")


if __name__ == "__main__":
    unittest.main()
