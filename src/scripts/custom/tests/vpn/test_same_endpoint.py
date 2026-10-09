import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "vpn"))
from xvpn import links  # noqa: E402


def vless(name, addr="198.51.100.7", uid="11111111-2222-3333-4444-555555555555", port=443):
    return {"remarks": name, "outbounds": [
        {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": addr, "port": port,
            "users": [{"id": uid, "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
         "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"serverName": "example.org", "publicKey": "k"}}},
        {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"}]}


def ss(name):
    return {"remarks": name, "outbounds": [
        {"tag": "proxy", "protocol": "shadowsocks", "settings": {"servers": [{"address": "203.0.113.1", "port": 1, "method": "aes-128-gcm", "password": "x"}]}},
        {"tag": "direct", "protocol": "freedom"}]}


class SameEndpoint(unittest.TestCase):
    def parse(self):
        doc = [ss("🇪🇺Осталось дней: 26521"), vless("🌀 АВТО-ВЫБОР | WIFI"), vless("🇳🇱Netherlands | Основной 1"),
               ss("🇪🇺⬇️ Обход Глушилок ⬇️"), vless("🇷🇺 [CDN] Yandex | Только LTE сети!", addr="198.51.100.9")]
        return links.parse_subscription_text(json.dumps(doc))

    def test_entries_sharing_an_endpoint_are_all_kept(self):
        p = self.parse()
        names = [n["name"] for n in p["nodes"]]
        self.assertEqual(len(names), 3, names)
        self.assertTrue(any("Основной 1" in n for n in names), names)
        self.assertTrue(any("АВТО-ВЫБОР" in n for n in names), names)

    def test_ids_are_unique_and_first_keeps_classic_id(self):
        p = self.parse()
        ids = [n["id"] for n in p["nodes"]]
        self.assertEqual(len(ids), len(set(ids)))
        auto = next(n for n in p["nodes"] if "АВТО" in n["name"])
        self.assertEqual(auto["id"], links.node_id("vless", "198.51.100.7", 443, "11111111-2222-3333-4444-555555555555"))

    def test_placeholders_and_section_headers_are_not_servers(self):
        p = self.parse()
        info = " | ".join(str(i.get("name") if isinstance(i, dict) else i) for i in p["info"])
        self.assertIn("Осталось дней", info)
        self.assertIn("Обход Глушилок", info)
        self.assertFalse(any("Обход" in n["name"] or "Осталось" in n["name"] for n in p["nodes"]))

    def test_exact_duplicates_are_still_dropped(self):
        doc = [vless("A"), vless("A")]
        self.assertEqual(len(links.parse_subscription_text(json.dumps(doc))["nodes"]), 1)

    def test_ids_are_stable_between_refreshes(self):
        a = [n["id"] for n in self.parse()["nodes"]]
        b = [n["id"] for n in self.parse()["nodes"]]
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
