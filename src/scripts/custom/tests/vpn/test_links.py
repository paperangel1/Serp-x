import json
import unittest

from common import FAKE_UUID, LINKS, PBK, b64_body
from xvpn import flags, links, subscription


class Flags(unittest.TestCase):
    def test_split_flag_emoji(self):
        f, cc, label = flags.split_name("\U0001F1F3\U0001F1F1 Нидерланды-1")
        self.assertEqual((cc, label), ("NL", "Нидерланды-1"))
        self.assertEqual(f, "\U0001F1F3\U0001F1F1")

    def test_flag_in_the_middle_and_dashes(self):
        f, cc, label = flags.split_name("Node \U0001F1E9\U0001F1EA - fast")
        self.assertEqual(cc, "DE")
        self.assertIn("fast", label)

    def test_fallback_from_country_words(self):
        self.assertEqual(flags.split_name("Sweden-1")[1], "SE")
        self.assertEqual(flags.split_name("Финляндия 3")[1], "FI")
        self.assertEqual(flags.split_name("sg-fast")[1], "")          # no guess without a real word

    def test_short_codes_need_word_boundaries(self):
        self.assertEqual(flags.split_name("Ukraine node")[1], "UA")   # longest word wins over "uk"
        self.assertEqual(flags.split_name("Busan")[1], "")            # "usa" inside a word is ignored

    def test_roundtrip(self):
        self.assertEqual(flags.flag_to_cc(flags.cc_to_flag("jp")), "JP")
        self.assertEqual(flags.cc_to_flag("x1"), "")


class Links(unittest.TestCase):
    def parse(self, i):
        return links.parse_link(LINKS[i])

    def test_vless_reality(self):
        n = self.parse(0)
        self.assertEqual((n["protocol"], n["cc"], n["name"]), ("vless", "NL", "Нидерланды-1"))
        ob = n["outbound"]
        self.assertEqual(ob["streamSettings"]["security"], "reality")
        self.assertEqual(ob["streamSettings"]["realitySettings"]["publicKey"], PBK)
        self.assertEqual(ob["settings"]["vnext"][0]["users"][0]["flow"], "xtls-rprx-vision")
        self.assertEqual(ob["settings"]["vnext"][0]["users"][0]["id"], FAKE_UUID)

    def test_vless_ws_tls(self):
        ss = self.parse(1)["outbound"]["streamSettings"]
        self.assertEqual(ss["network"], "ws")
        self.assertEqual(ss["wsSettings"]["path"], "/ws")
        self.assertEqual(ss["tlsSettings"]["serverName"], "de1.example.net")

    def test_ss_sip002_and_legacy(self):
        a, b = self.parse(2), self.parse(3)
        s = a["outbound"]["settings"]["servers"][0]
        self.assertEqual((s["method"], s["password"], s["port"]), ("chacha20-ietf-poly1305", "pass-word-1", 8388))
        s = b["outbound"]["settings"]["servers"][0]
        self.assertEqual((s["method"], s["password"], s["address"]), ("aes-256-gcm", "legacy-pass", "se1.example.net"))
        self.assertEqual(a["cc"], "FI")
        self.assertEqual(b["cc"], "SE")        # from the country word, no flag in the name

    def test_ss_plugin_is_unsupported(self):
        with self.assertRaises(links.LinkError):
            links.parse_link("ss://YWVzLTEyOC1nY206cHc@h.example:1?plugin=v2ray-plugin#x")

    def test_trojan(self):
        n = self.parse(4)
        self.assertEqual(n["outbound"]["settings"]["servers"][0]["password"], "trojan-pass")
        self.assertEqual(n["outbound"]["streamSettings"]["security"], "tls")

    def test_hysteria2(self):
        n = self.parse(5)
        self.assertTrue(n["udp"])
        ob = n["outbound"]
        self.assertEqual(ob["protocol"], "hysteria")
        self.assertEqual(ob["streamSettings"]["hysteriaSettings"]["auth"], "hy2-auth")
        self.assertEqual(ob["streamSettings"]["finalmask"]["udp"][0]["type"], "salamander")
        self.assertEqual(links.parse_link(LINKS[5].replace("hysteria2://", "hy2://"))["protocol"], "hysteria2")

    def test_reality_without_key_rejected(self):
        with self.assertRaises(links.LinkError):
            links.parse_link(f"vless://{FAKE_UUID}@h.example:443?security=reality&sni=a#x")

    def test_ids_are_stable_and_do_not_leak_secrets(self):
        a, b = self.parse(0), self.parse(0)
        self.assertEqual(a["id"], b["id"])
        self.assertNotIn(FAKE_UUID, a["id"])
        self.assertEqual(len(a["id"]), 10)


class Bodies(unittest.TestCase):
    def test_base64_body(self):
        r = links.parse_subscription_text(b64_body())
        self.assertEqual(r["kind"], "links")
        self.assertEqual(len(r["nodes"]), 6)
        self.assertEqual([n["protocol"] for n in r["nodes"]].count("ss"), 2)

    def test_plain_body_with_junk_lines(self):
        body = "\n".join(["# comment", "garbage line", LINKS[0], "unknown://x", LINKS[0], LINKS[4]])
        r = links.parse_subscription_text(body)
        self.assertEqual(len(r["nodes"]), 2)             # duplicate removed
        self.assertEqual(len(r["skipped"]), 1)           # unknown scheme counted

    def test_empty_body(self):
        with self.assertRaises(links.LinkError):
            links.parse_subscription_text("   ")

    def test_json_subscription_with_routing(self):
        doc = [{"remarks": "\U0001F1F3\U0001F1F1 NL json",
                "outbounds": [{"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "a.example", "port": 443, "users": [{"id": FAKE_UUID}]}]}},
                              {"tag": "direct", "protocol": "freedom"}],
                "routing": {"rules": [{"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
                                      {"type": "field", "domain": ["domain:example.ru"], "outboundTag": "direct", "evil": "x"},
                                      {"type": "field", "inboundTag": ["x"], "outboundTag": "proxy"},
                                      {"type": "field", "domain": ["a"], "outboundTag": "weird"}]}}]
        r = links.parse_subscription_text(json.dumps(doc))
        self.assertEqual(r["kind"], "json")
        self.assertEqual(r["nodes"][0]["name"], "NL json")
        self.assertEqual(len(r["rules"]), 2)             # only matcher fields + known tags survive
        self.assertNotIn("evil", r["rules"][1])
        self.assertEqual(r["nodes"][0]["outbound"]["tag"], "proxy")

    def test_json_garbage(self):
        with self.assertRaises(links.LinkError):
            links.parse_subscription_text("[1, 2]" if False else "{not json")

    def test_public_nodes_have_no_credentials(self):
        r = links.parse_subscription_text(b64_body())
        blob = json.dumps(subscription.public_nodes({"nodes": r["nodes"]}))
        for secret in (FAKE_UUID, "pass-word-1", "legacy-pass", "trojan-pass", "hy2-auth", PBK):
            self.assertNotIn(secret, blob)
        self.assertNotIn("nl1.example.net", blob)        # hosts are masked to their tail
        self.assertIn("example.net", blob)


if __name__ == "__main__":
    unittest.main()
