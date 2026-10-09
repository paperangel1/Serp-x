import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import unittest

from common import FAKE_UUID, LINKS, VPN_DIR, Env, SubServer, b64_body, mode
from xvpn import control, geo, paths, subscription


def links_route(extra=None):
    hdr = {"subscription-userinfo": "upload=1000; download=3000; total=200000; expire=1893456000",
           "profile-title": "base64:" + base64.b64encode("Мой план".encode()).decode(), "profile-update-interval": "12",
           "support-url": "https://support.example/"}
    hdr.update(extra or {})
    return lambda ua: (200, hdr, b64_body().encode())


class Refresh(unittest.TestCase):
    def test_links_subscription_stored_securely(self):
        with Env() as e:
            srv = SubServer({"/sub/TOKEN": links_route()})
            try:
                subscription.write_url(srv.url())
                meta = subscription.refresh()
                self.assertEqual((meta["kind"], meta["count"]), ("links", 6))
                self.assertEqual(meta["userinfo"], {"used": 4000, "total": 200000, "expire": 1893456000})
                self.assertEqual(meta["title"], "Мой план")
                self.assertEqual(meta["intervalHours"], 12)
                self.assertEqual(mode(e.state / "nodes.json"), 0o600)
                self.assertEqual(mode(e.state / "meta.json"), 0o600)
                self.assertEqual(mode(e.secrets / "vpn_subscription"), 0o600)
                for name in ("meta.json", "nodes.json"):
                    self.assertNotIn("TOKEN", (e.state / name).read_text())          # the URL never leaves the secret file
                self.assertNotIn("TOKEN", (e.td / "events.jsonl").read_text())
            finally:
                srv.close()

    def test_json_preferred_when_a_later_user_agent_gets_it(self):
        doc = [{"remarks": "\U0001F1F3\U0001F1F1 NL", "outbounds": [{"tag": "proxy", "protocol": "vless",
                "settings": {"vnext": [{"address": "a.example", "port": 443, "users": [{"id": FAKE_UUID}]}]}}],
                "routing": {"rules": [{"type": "field", "domain": ["domain:x.ru"], "outboundTag": "direct"}]}}]

        def route(ua):
            if ua.startswith("Happ"):
                return 200, {}, json.dumps(doc).encode()
            return 200, {}, b64_body().encode()

        with Env():
            srv = SubServer({"/sub/TOKEN": route})
            try:
                subscription.write_url(srv.url())
                meta = subscription.refresh()
                self.assertEqual(meta["kind"], "json")
                self.assertEqual(meta["ua"], "Happ/4")
                nodes = subscription.load_nodes()
                self.assertEqual(nodes["rules"][0]["domain"], ["domain:x.ru"])
                self.assertEqual(len(srv.hits), 3)       # tried all candidates, kept the richest format
                # the successful UA is remembered: next refresh asks once
                srv.hits.clear()
                subscription.refresh()
                self.assertEqual(srv.hits[0][1], "Happ/4")
            finally:
                srv.close()

    def test_failure_keeps_old_nodes(self):
        with Env():
            srv = SubServer({"/sub/TOKEN": links_route()})
            try:
                subscription.write_url(srv.url())
                subscription.refresh()
                srv.routes["/sub/TOKEN"] = lambda ua: (500, {}, b"boom")
                with self.assertRaises(subscription.SubscriptionError) as cm:
                    subscription.refresh()
                self.assertEqual(cm.exception.code, "http_error")
                self.assertEqual(len(subscription.load_nodes()["nodes"]), 6)
            finally:
                srv.close()

    def test_url_validation(self):
        for bad in ("", "ftp://x/y", "file:///etc/passwd", "javascript:alert(1)", "notaurl"):
            with self.assertRaises(subscription.SubscriptionError, msg=bad):
                subscription.validate_url(bad)
        os.environ.pop("XVPN_ALLOW_HTTP", None)
        try:
            with self.assertRaises(subscription.SubscriptionError):
                subscription.validate_url("http://panel.example/sub/x")
            self.assertTrue(subscription.validate_url("http://127.0.0.1:9/x"))
            self.assertTrue(subscription.validate_url("https://panel.example/sub/x"))
        finally:
            os.environ["XVPN_ALLOW_HTTP"] = "1"

    def test_error_messages_never_contain_the_url(self):
        with Env():
            subscription.write_url("http://127.0.0.1:1/sub/SECRETTOKEN")        # nothing listens there
            with self.assertRaises(subscription.SubscriptionError) as cm:
                subscription.refresh()
            self.assertNotIn("SECRETTOKEN", cm.exception.detail + cm.exception.code)

    def test_due(self):
        with Env():
            self.assertFalse(subscription.due())                               # no url -> nothing to do
            srv = SubServer({"/sub/TOKEN": links_route()})
            try:
                subscription.write_url(srv.url())
                self.assertTrue(subscription.due())
                subscription.refresh()
                self.assertFalse(subscription.due())
                self.assertTrue(subscription.due(now=time.time() + 13 * 3600))
            finally:
                srv.close()


class UserInfo(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(subscription.parse_userinfo("upload=1; download=2; total=10; expire=5"), {"used": 3, "total": 10, "expire": 5})
        self.assertIsNone(subscription.parse_userinfo("garbage"))
        self.assertIsNone(subscription.parse_userinfo(""))

    def test_expiry_notifications_once_per_day(self):
        with Env() as e:
            now = 1_800_000_000
            meta = {"userinfo": {"used": 95, "total": 100, "expire": now + 3 * 86400}}
            self.assertEqual(len(control.check_expiry(meta, now)), 2)
            self.assertEqual(len(control.check_expiry(meta, now + 3600)), 0)      # same day: silent
            self.assertEqual(len(control.check_expiry(meta, now + 86400)), 2)    # next day: again
            self.assertEqual(len(e.notified()), 4)
            self.assertEqual(control.check_expiry({"userinfo": {"used": 1, "total": 100, "expire": now + 90 * 86400}}, now), [])


class CliSetSubscription(unittest.TestCase):
    def run_cli(self, e, *args, stdin=""):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        r = subprocess.run(["bash", str(VPN_DIR / "x_vpn.sh"), *args], input=stdin, capture_output=True, text=True, env=env, timeout=60)
        return r.returncode, r.stdout, r.stderr

    def test_set_and_clear_via_stdin(self):
        with Env() as e:
            srv = SubServer({"/sub/TOKEN": links_route()})
            try:
                rc, out, err = self.run_cli(e, "set-subscription", stdin=srv.url() + "\n")
                self.assertEqual(rc, 0, err)
                self.assertTrue(json.loads(out)["ok"])
                self.assertNotIn("TOKEN", out + err)
                rc, out, _ = self.run_cli(e, "status")
                st = json.loads(out)
                self.assertTrue(st["subscription"]["configured"])
                self.assertNotIn("TOKEN", out)
                self.assertTrue(st["subscription"]["display"].startswith("http://127.0.0.1/"))
                self.assertEqual(len(st["nodes"]), 6)
                rc, out, _ = self.run_cli(e, "clear-subscription")
                self.assertFalse((e.secrets / "vpn_subscription").exists())
                self.assertFalse((e.state / "nodes.json").exists())
            finally:
                srv.close()

    def test_failed_set_restores_previous_secret(self):
        with Env() as e:
            good = SubServer({"/sub/TOKEN": links_route()})
            bad = SubServer({"/sub/TOKEN": lambda ua: (200, {}, b"%%% not a subscription")})
            try:
                self.assertEqual(self.run_cli(e, "set-subscription", stdin=good.url() + "\n")[0], 0)
                rc, out, _ = self.run_cli(e, "set-subscription", stdin=bad.url() + "\n")
                self.assertEqual(rc, 1)
                self.assertFalse(json.loads(out)["ok"])
                self.assertEqual(subscription.read_url(), good.url())
            finally:
                good.close(); bad.close()

    def test_bad_url_rejected_without_storing(self):
        with Env() as e:
            rc, out, _ = self.run_cli(e, "set-subscription", stdin="ftp://x/y\n")
            self.assertEqual(rc, 1)
            self.assertEqual(json.loads(out)["error"], "bad_url")
            self.assertFalse((e.secrets / "vpn_subscription").exists())


class Geo(unittest.TestCase):
    def files(self, geoip=b"G" * 2000, geosite=b"S" * 3000, good_sums=True):
        def sums(data, ok=True):
            h = hashlib.sha256(data).hexdigest() if ok else "0" * 64
            return (200, {}, f"{h}  file.dat\n".encode())
        return {"/rel/geoip.dat": lambda ua: (200, {}, geoip),
                "/rel/geosite.dat": lambda ua: (200, {}, geosite),
                "/rel/geoip.dat.sha256sum": lambda ua: sums(geoip),
                "/rel/geosite.dat.sha256sum": lambda ua: sums(geosite, good_sums)}

    def test_download_and_verify(self):
        with Env() as e:
            srv = SubServer(self.files())
            try:
                meta = geo.update(srv.url("/rel"))
                self.assertEqual((e.data / "geo" / "geoip.dat").read_bytes(), b"G" * 2000)
                self.assertEqual(set(meta["sha256"]), {"geoip.dat", "geosite.dat"})
                self.assertTrue(geo.info()["present"])
            finally:
                srv.close()

    def test_digest_mismatch_changes_nothing(self):
        with Env() as e:
            srv = SubServer(self.files())
            try:
                geo.update(srv.url("/rel"))
                srv.routes = self.files(geoip=b"N" * 2000, geosite=b"T" * 3000, good_sums=False)
                with self.assertRaises(geo.GeoError) as cm:
                    geo.update(srv.url("/rel"))
                self.assertEqual(cm.exception.code, "digest_mismatch")
                self.assertEqual((e.data / "geo" / "geoip.dat").read_bytes(), b"G" * 2000)      # untouched
                self.assertEqual((e.data / "geo" / "geosite.dat").read_bytes(), b"S" * 3000)
            finally:
                srv.close()

    def test_missing_digest_file(self):
        with Env():
            r = self.files()
            del r["/rel/geoip.dat.sha256sum"]
            srv = SubServer(r)
            try:
                with self.assertRaises(geo.GeoError):
                    geo.update(srv.url("/rel"))
            finally:
                srv.close()

    def test_plain_http_to_the_internet_refused(self):
        with Env():
            os.environ.pop("XVPN_ALLOW_HTTP", None)
            try:
                with self.assertRaises(geo.GeoError) as cm:
                    geo.update("http://example.com/rel")
                self.assertEqual(cm.exception.code, "http_not_allowed")
            finally:
                os.environ["XVPN_ALLOW_HTTP"] = "1"


if __name__ == "__main__":
    unittest.main()
