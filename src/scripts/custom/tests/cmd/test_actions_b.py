"""Stage 9b: file rename / archive, HTTP request, Gemini and server command nodes. Network only against a mock server on
127.0.0.1 (a random port); Gemini through a mock endpoint with no proxy; the servers CLI is a stub script."""
import glob
import http.server
import json
import os
import threading
import unittest
import zipfile

import common as C
from common import node
from test_actions import ActBase, FileTests
from xcmd import actions_b as AB


class Mock(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *a):
        pass

    def reply(self, code, body, headers=()):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        Mock.seen.append(("GET", self.path, dict(self.headers), b""))
        if self.path.startswith("/redir-file"):
            return self.reply(302, "", [("Location", "file:///etc/passwd")])
        if self.path.startswith("/redir-ok"):
            return self.reply(302, "", [("Location", "/hello")])
        if self.path.startswith("/big"):
            return self.reply(200, "x" * (AB.HTTP_MAX_BODY + 500))
        if self.path.startswith("/missing"):
            return self.reply(404, "nope")
        self.reply(200, "hello")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        Mock.seen.append(("POST", self.path, dict(self.headers), body))
        if "generateContent" in self.path:
            mode = Mock.gemini
            if mode == "ok":
                return self.reply(200, json.dumps({"candidates": [{"content": {"parts": [{"text": "Это объяснение."}]}}]}))
            if mode == "quota":
                return self.reply(429, json.dumps({"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "message": "quota"}}))
            if mode == "key":
                return self.reply(400, json.dumps({"error": {"code": 400, "status": "INVALID_ARGUMENT", "message": "API key not valid"}}))
            if mode == "unavailable-first":
                if "model-a" in self.path:
                    return self.reply(503, json.dumps({"error": {"code": 503, "status": "UNAVAILABLE", "message": "busy"}}))
                return self.reply(200, json.dumps({"candidates": [{"content": {"parts": [{"text": "second"}]}}]}))
            if mode == "blocked":
                return self.reply(200, json.dumps({"promptFeedback": {"blockReason": "SAFETY"}}))
        self.reply(200, "posted:" + body.decode())

    gemini = "ok"


class NetBase(ActBase):
    async def asyncSetUp(self):
        self.runtime(ui=getattr(self, "ui", None))
        Mock.seen = []
        Mock.gemini = "ok"
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.base = "http://127.0.0.1:%d" % self.port

    def logtext(self):
        out = ""
        for p in glob.glob(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], "*.log")):
            with open(p, encoding="utf-8", errors="replace") as f:
                out += f.read()
        return out


class HttpTests(NetBase):
    async def go1(self, **props):
        res = await self.go("http", [node("a", "action.http.request@1", **props)])
        return res, self.last_step(res, "a")

    async def test_get_and_status_pins(self):
        res, st = await self.go1(url=self.base + "/x")
        self.assertEqual((res["status"], st["out"]["status"], st["out"]["text"], st["out"]["ok"]), ("ok", 200, "hello", True))
        res, st = await self.go1(url=self.base + "/missing")
        self.assertEqual((res["status"], st["out"]["status"], st["out"]["ok"]), ("ok", 404, False))     # an error status is an answer

    async def test_post_headers_and_secret_never_logged(self):
        sec = os.path.join(self.env.root, ".config", "serpantinum", "secrets")
        os.makedirs(sec)
        with open(os.path.join(sec, "apitok"), "w") as f:
            f.write("TOKEN-VALUE-77\n")
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.env.root, ".config")
        self.addCleanup(os.environ.pop, "XDG_CONFIG_HOME", None)
        res, st = await self.go1(url=self.base + "/p?key=QUERYSECRET", method="POST", body="payload-1", headers="X-Token: secret:apitok\nAccept: text/plain")
        self.assertEqual(res["status"], "ok", res)
        method, path, headers, body = Mock.seen[-1]
        self.assertEqual((method, body, headers["X-Token"]), ("POST", b"payload-1", "TOKEN-VALUE-77"))
        self.assertEqual(st["out"]["text"], "‹16 символов›")                       # the body text travels on, so it stays hidden here too
        self.assertEqual(st["in"]["headers"], "***")
        blob = self.logtext() + json.dumps(res)
        self.assertNotIn("TOKEN-VALUE-77", blob)
        self.assertNotIn("QUERYSECRET", blob)
        self.assertNotIn("payload-1", self.logtext())

    async def test_redirects_only_to_http(self):
        res, st = await self.go1(url=self.base + "/redir-file")
        self.assertEqual(res["status"], "err")
        self.assertIn("перенаправление", res["message"] + json.dumps(res["steps"], ensure_ascii=False))
        res, st = await self.go1(url=self.base + "/redir-ok")
        self.assertEqual((st["out"]["status"], st["out"]["text"]), (200, "hello"))

    async def test_size_cap_bad_url_and_refused_connection(self):
        status, raw = AB._http("GET", self.base + "/big", {}, None, 5)
        self.assertEqual((status, len(raw)), (200, AB.HTTP_MAX_BODY + 1))                # read one byte past the cap to know it is cut
        res, st = await self.go1(url=self.base + "/big")
        self.assertEqual(res["status"], "ok")
        for url in ("ftp://example.org/x", "file:///etc/passwd", "http://user:pw@127.0.0.1/", "example.org"):
            res, _ = await self.go1(url=url)
            self.assertEqual(res["status"], "err", url)
        res, _ = await self.go1(url="http://127.0.0.1:1/")
        self.assertEqual(res["status"], "err")
        self.assertIn("Не удалось выполнить запрос", json.dumps(res, ensure_ascii=False))

    async def test_missing_secret_is_a_clear_error(self):
        res, _ = await self.go1(url=self.base + "/x", headers="X: secret:nope")
        self.assertEqual(res["status"], "err")
        self.assertIn("Секрет", json.dumps(res, ensure_ascii=False))

    async def test_capability_net_http_is_required(self):
        cmd = self.cmd("noapp", [node("a", "action.http.request@1", url=self.base)])
        self.add(cmd, approve=False)
        res = await self.rt.engine.run("noapp")
        self.assertEqual(res["status"], "denied")


class GeminiTests(NetBase):
    def setUp(self):
        super().setUp()
        self.key = os.path.join(self.env.root, "gemini_key")
        with open(self.key, "w") as f:
            f.write("KEY-SECRET-99\n")
        self.set_env(X_GEMINI_KEY_FILE=self.key, X_GEMINI_PROXY="", X_GEMINI_MODELS="model-a model-b")

    def set_env(self, **kw):
        for k, v in kw.items():
            old = os.environ.get(k)
            os.environ[k] = v
            self.addCleanup(lambda k=k, old=old: os.environ.pop(k, None) if old is None else os.environ.__setitem__(k, old))

    async def ask(self, **props):
        self.set_env(X_GEMINI_ENDPOINT=self.base + "/v1beta/models")
        res = await self.go("g", [node("a", "action.ai.gemini@1", **dict({"text": "Some PRIVATE sentence."}, **props))])
        return res, self.last_step(res, "a") if res["steps"] and any(s["node"] == "a" for s in res["steps"]) else None

    async def test_explain_ok_and_nothing_private_in_logs(self):
        res, st = await self.ask(mode="explain", language="ru")
        self.assertEqual(res["status"], "ok", res)
        method, path, headers, body = Mock.seen[-1]
        self.assertIn("/model-a:generateContent", path)
        self.assertNotIn("KEY-SECRET-99", path)                                  # the key is a header, not in the URL
        self.assertEqual(headers["x-goog-api-key"], "KEY-SECRET-99")
        payload = json.loads(body)
        self.assertEqual(payload["contents"][0]["parts"][0]["text"], "Some PRIVATE sentence.")
        self.assertIn("Russian", payload["systemInstruction"]["parts"][0]["text"])
        self.assertEqual(st["out"]["result"], "‹15 символов›")                  # the answer is length-logged
        blob = self.logtext() + json.dumps(res, ensure_ascii=False)
        for secret in ("PRIVATE", "KEY-SECRET-99", "объяснение"):
            self.assertNotIn(secret, blob)
        self.assertEqual(glob.glob("/tmp/xcmd-gemini-*"), [])                     # the temporary payload file is gone

    async def test_modes(self):
        await self.ask(mode="translate", language="en")
        self.assertIn("Translate the text into English", json.loads(Mock.seen[-1][3])["systemInstruction"]["parts"][0]["text"])
        await self.ask(mode="custom", prompt="Make it rhyme")
        self.assertIn("Make it rhyme", json.loads(Mock.seen[-1][3])["systemInstruction"]["parts"][0]["text"])
        res, _ = await self.ask(mode="custom", prompt="")
        self.assertIn("Запрос", json.dumps(res, ensure_ascii=False))

    async def test_fallback_model_on_unavailable(self):
        Mock.gemini = "unavailable-first"
        res, st = await self.ask()
        self.assertEqual(res["status"], "ok")
        self.assertEqual([p for _, p, _, _ in Mock.seen if "generateContent" in p][-2:][0].split("/")[-1].split(":")[0], "model-a")

    async def test_clear_russian_errors(self):
        for mode, word in (("quota", "квота"), ("key", "ключ"), ("blocked", "отказался")):
            Mock.gemini = mode
            res, _ = await self.ask()
            self.assertEqual(res["status"], "err", mode)
            self.assertIn(word, res["message"].lower() if res.get("message") else json.dumps(res, ensure_ascii=False).lower(), mode)
        os.remove(self.key)
        res, _ = await self.ask()
        self.assertIn("Не задан ключ", json.dumps(res, ensure_ascii=False))

    async def test_tunnel_down_and_size_cap_and_empty(self):
        with open(self.key, "w") as f:
            f.write("k")
        self.set_env(X_GEMINI_PROXY="socks5h://127.0.0.1:1")                  # a closed local port: «tunnel down»
        res, _ = await self.ask()
        self.assertIn("Туннель", json.dumps(res, ensure_ascii=False))
        self.set_env(X_GEMINI_PROXY="")
        res, _ = await self.ask(text="x" * (AB.GEMINI_MAX_TEXT + 1))
        self.assertIn("слишком длинный", json.dumps(res, ensure_ascii=False))
        res, _ = await self.ask(text="   ")
        self.assertIn("пустой", json.dumps(res, ensure_ascii=False))

    async def test_curl_timeout_and_key_not_in_argv(self):
        self.sh("curl", 'printf "%%s\\n" "$*" > "%s/curl.args"\ncat > "%s/curl.stdin"\nexit 28\n' % (self.env.fake, self.env.fake))
        res, _ = await self.ask()
        self.assertIn("не ответил", json.dumps(res, ensure_ascii=False))
        self.assertNotIn("KEY-SECRET-99", self.env.read("curl.args"))
        self.assertIn("KEY-SECRET-99", self.env.read("curl.stdin"))
        self.assertNotIn("PRIVATE", self.env.read("curl.args"))

    async def test_capability_declared_and_texts(self):
        from xcmd import uiview
        self.assertIn("Google", uiview.CAP_WARN_RU["net.gemini"])
        self.assertIn("Google", uiview.CAP_WARN_EN["net.gemini"])
        for c in ("net.gemini", "servers.run", "trigger.clipboard", "trigger.notifications"):
            self.assertIn(c, uiview.CAP_WARN_RU)
            self.assertTrue(uiview.CAP_RU[c] and uiview.CAP_EN[c])
            from xcmd.model import is_risky_cap
            self.assertTrue(is_risky_cap(c), c)


class PermissionPromptTests(NetBase):
    async def test_summary_carries_the_explicit_permission_texts(self):
        from xcmd import uiview
        cmd = self.cmd("perm", [node("a", "action.ai.gemini@1", text="x")])
        cmd["nodes"].insert(0, node("c", "event.clipboard.link@1"))
        cmd["nodes"].insert(0, node("n", "event.notification.received@1"))
        for lang, word in (("ru", "Google"), ("en", "Google")):
            caps = {c["id"]: c for c in uiview._summary(cmd, self.rt.sch, lang)["caps"]}
            self.assertEqual(set(caps), {"net.gemini", "trigger.clipboard", "trigger.notifications"})
            self.assertIn(word, caps["net.gemini"]["warn"])
            self.assertTrue(all(c["risky"] and c["warn"] and c["new"] for c in caps.values()))


class ServerRunTests(NetBase):
    CMDS = {"commands": [{"id": "diag-load", "label": "Нагрузка", "danger": "none", "timeout": 60},
                         {"id": "act-restart-node", "label": "Перезапустить ноду", "danger": "confirm", "timeout": 90},
                         {"id": "act-reboot", "label": "Перезагрузить сервер", "danger": "typed", "timeout": 30}]}

    async def asyncSetUp(self):
        self.ui = C.FakeUi({"answer": True})
        await super().asyncSetUp()
        os.makedirs(os.path.join(self.env.root, "srvstate"))
        with open(os.path.join(self.env.root, "srvstate", "state.json"), "w") as f:
            json.dump({"servers": {"id-7": {"name": "VPS-Alpha"}}}, f)
        self.sh("fake-servers", 'case "$1" in\n commands) cat "$FAKE_DIR/commands.json";;\n run) echo "$2 $3" >> "$FAKE_DIR/run.log"\n'
                                ' echo "::serp-start::abc"; echo "line one"; echo "line two"; echo "::serp-exit::abc::{\\"code\\": ${FAKE_CODE:-0}, \\"ms\\": 5}";;\nesac\n')
        self.env.write_fake("commands.json", json.dumps(self.CMDS))
        for k, v in (("XCMD_SERVERS_BIN", os.path.join(self.env.bin, "fake-servers")), ("XCMD_SERVERS_STATE", os.path.join(self.env.root, "srvstate"))):
            os.environ[k] = v
            self.addCleanup(os.environ.pop, k, None)

    async def run_node(self, **props):
        res = await self.go("srv", [node("a", "action.server.run@1", **props)])
        return res, (self.last_step(res, "a") if any(s["node"] == "a" for s in res["steps"]) else None)

    async def test_safe_command_runs_without_asking_and_resolves_name(self):
        res, st = await self.run_node(server="vps-alpha", command="diag-load")
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.env.lines("run.log"), ["id-7 diag-load"])
        self.assertEqual((st["out"]["output"], st["out"]["exit_code"]), ("line one\nline two", 0))
        self.assertEqual(self.ui.requests, [])

    async def test_confirm_command_asks_and_refusal_stops(self):
        res, _ = await self.run_node(server="id-7", command="act-restart-node")
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.ui.requests[0][0], "confirm")
        self.ui.answer = {"answer": False}
        self.env.write_fake("run.log", "")
        res, _ = await self.run_node(server="id-7", command="act-restart-node")
        self.assertEqual(res["status"], "err")
        self.assertEqual(self.env.lines("run.log"), [])

    async def test_no_answer_means_no_run(self):
        self.ui.answer = None
        res, _ = await self.run_node(server="id-7", command="act-restart-node")
        self.assertEqual(res["status"], "err")
        self.assertEqual(self.env.lines("run.log"), [])

    async def test_typed_is_refused_unless_explicitly_allowed_and_approved(self):
        res, _ = await self.run_node(server="id-7", command="act-reboot")
        self.assertEqual(res["status"], "err")
        self.assertIn("вручную", json.dumps(res, ensure_ascii=False))
        res, _ = await self.run_node(server="id-7", command="act-reboot", allow_typed=True)       # approved by add(): both rights
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.ui.requests[-1][0], "confirm")                                     # ... and still confirmed
        from xcmd.model import compute_capabilities
        cmd = self.cmd("t", [node("a", "action.server.run@1", server="s", command="diag-load", allow_typed=True)])
        self.assertEqual(compute_capabilities(cmd, self.rt.sch), ["servers.run", "servers.run.typed"])
        cmd = self.cmd("t2", [node("a", "action.server.run@1", server="s", command="diag-load")])
        self.assertEqual(compute_capabilities(cmd, self.rt.sch), ["servers.run"])

    async def test_unknown_command_bad_id_and_failed_exit(self):
        res, _ = await self.run_node(server="id-7", command="nope")
        self.assertIn("нет команды", json.dumps(res, ensure_ascii=False))
        res, _ = await self.run_node(server="id-7", command="a; rm -rf /")
        self.assertEqual(res["status"], "err")
        os.environ["FAKE_CODE"] = "3"
        self.addCleanup(os.environ.pop, "FAKE_CODE", None)
        res, _ = await self.run_node(server="id-7", command="diag-load")
        self.assertEqual(res["status"], "err")
        self.assertIn("кодом 3", json.dumps(res, ensure_ascii=False))

    async def test_output_is_not_logged(self):
        await self.run_node(server="id-7", command="diag-load")
        self.assertNotIn("line one", self.logtext())

    def test_parse_run_output(self):
        out, info = AB.parse_run_output("::serp-start::ab\nhello\n::serp-exit::ab::{\"code\": 2}\n")
        self.assertEqual((out, info["code"]), ("hello", 2))


class RenameArchiveTests(FileTests):
    async def test_rename_and_undo(self):
        src = self.mk("dl/a.txt", "data")
        res = await self.go("rn", [node("a", "action.file.rename@1", path=src, name="b.txt", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertTrue(os.path.exists(src))                                          # undone
        res = await self.go("rn2", [node("a", "action.file.rename@1", path=src, name="b.txt")])
        self.assertEqual(self.last_step(res, "a")["out"]["new_path"], self.f("dl", "b.txt"))
        self.assertEqual(self.rd(self.f("dl", "b.txt")), "data")

    async def test_rename_never_overwrites_and_validates(self):
        a, b = self.mk("dl/a.txt", "A"), self.mk("dl/b.txt", "B")
        res = await self.go("rn3", [node("a", "action.file.rename@1", path=a, name="b.txt")])
        self.assertEqual(self.last_step(res, "a")["out"]["new_path"], self.f("dl", "b (1).txt"))
        self.assertEqual(self.rd(b), "B")
        res = await self.go("rn4", [node("a", "action.file.rename@1", path=self.f("dl", "b (1).txt"), name="b.txt", on_exists="fail")])
        self.assertEqual(res["status"], "err")
        for bad in ("../x", "a/b", "..", ""):
            res = await self.go("rn5", [node("a", "action.file.rename@1", path=b, name=bad)])
            self.assertEqual(res["status"], "err", bad)
        self.assertEqual(self.rd(b), "B")

    async def test_rename_outside_home_needs_the_explicit_right(self):
        outside = "/tmp/xcmd-rename-%d.txt" % os.getpid()
        with open(outside, "w") as fh:
            fh.write("x")
        self.addCleanup(lambda: [os.remove(p) for p in glob.glob(outside[:-4] + "*") if os.path.exists(p)])
        res = await self.go("rn6", [node("a", "action.file.rename@1", path=outside, name="moved-away.txt")])
        self.assertEqual(res["status"], "err")
        self.assertTrue(os.path.exists(outside))

    async def test_archive_files_and_folder(self):
        a, b = self.mk("dl/a.txt", "A"), self.mk("dl/sub/b.txt", "B")
        res = await self.go("ar", [node("a", "action.file.archive@1", paths=[a, self.f("dl", "sub")], name="pack")])
        self.assertEqual(res["status"], "ok", res)
        out = self.last_step(res, "a")["out"]
        self.assertEqual((out["archive"], out["count"]), (self.f("dl", "pack.zip"), 2))
        with zipfile.ZipFile(out["archive"]) as z:
            self.assertEqual(sorted(z.namelist()), ["a.txt", "sub/b.txt"])
        res = await self.go("ar2", [node("a", "action.file.archive@1", paths=[a], name="pack.zip")])
        self.assertEqual(self.last_step(res, "a")["out"]["archive"], self.f("dl", "pack (1).zip"))        # never overwritten
        self.assertFalse([f for f in os.listdir(self.f("dl")) if f.endswith(".part")])

    async def test_archive_errors(self):
        res = await self.go("ar3", [node("a", "action.file.archive@1", paths=[self.f("nope.txt")])])
        self.assertEqual(res["status"], "err")
        res = await self.go("ar4", [node("a", "action.file.archive@1", paths=[self.mk("x.txt")], name="../evil")])
        self.assertEqual(res["status"], "err")


if __name__ == "__main__":
    unittest.main()
