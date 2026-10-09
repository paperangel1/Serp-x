import os, sys, tempfile, unittest, subprocess, json, re
HERE = os.path.dirname(os.path.abspath(__file__))
XLOG_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "xlog"))
sys.path.insert(0, XLOG_DIR)
sys.dont_write_bytecode = True
import xlog

LINE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d (DEBUG|INFO|WARN|ERROR) [a-z0-9_-]+ .+")

CANARIES = [
    "https://panel.canary-host.example/api/sub/AbCdEf0123456789AbCdEf0123456789?token=ZZZ",
    "Bearer eyJhbGciOiJIUzI1NiJ9.canarypayload.sig123456",
    "token=supersecretvalue1",
    "password: 'hunter2canary'",
    "3f2c1a9e-8b7d-4c5e-9a1b-0123456789ab",
    "vless://canary-uuid@evil.example:443?security=reality#Node",
    "203.0.113.77",
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    "QWxhZGRpbjpvcGVuIHNlc2FtZVF1aWNrQnJvd25Gb3g",
    "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
    "admin@canary-server.example.org",
    "Authorization: Basic Y2FuYXJ5OnNlY3JldA==",
]

class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="xlogtest-")
        self.old = dict(os.environ)
        os.environ["SERPANTINUM_LOG_DIR"] = os.path.join(self.tmp, "logs")
        os.environ.pop("XLOG_LEVEL", None)
        os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    def tearDown(self):
        os.environ.clear(); os.environ.update(self.old)
    def text(self, m):
        with open(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], m + ".log"), encoding="utf-8") as f:
            return f.read()

class Redaction(Base):
    def test_canaries_removed(self):
        for c in CANARIES:
            out = xlog.redact(f"before {c} after")
            for needle in ("canary", "supersecret", "hunter2", "3f2c1a9e", "203.0.113.77", "deadbeef", "QWxhZGRpbn",
                           "b3BlbnNz", "evil.example", "eyJhbGci", "Y2FuYXJ5"):
                self.assertNotIn(needle, out, (c, out))
            self.assertIn("before", out); self.assertIn("after", out)
    def test_idempotent(self):
        s = "GET https://panel.x.example/api/a1b2c3d4e5f6a7b8c9d0?token=q ip 8.8.8.8 token=abc"
        self.assertEqual(xlog.redact(xlog.redact(s)), xlog.redact(s))
    def test_harmless_text_kept(self):
        for s in (os.path.join("/srv/app", "work/serpantinum/src/scripts/custom/cmd/xcmd/engine.py:120"),
                  "xray 26.3.27 at /usr/bin/xray", "192.168.1.3 127.0.0.1 10.0.0.5", "commit 1b2c3d4 on serp-x",
                  "run Приветствие с задержкой ok rc=0 ms=34", "https://github.com/ilyamiro/serpantinum.git",
                  "socks5h://127.0.0.1:1080"):
            self.assertEqual(xlog.redact(s), s)
    def test_url_shapes(self):
        self.assertEqual(xlog.redact("https://panel.example.com/api/x?y=1"), "https://<host>/…")
        self.assertIn("raw.githubusercontent.com/o/r/<id>", xlog.redact("https://raw.githubusercontent.com/o/r/AAAAAAAAAAAAAAAAAAAA?x=1"))
    def test_never_raises(self):
        self.assertIsInstance(xlog.redact(None), str); self.assertIsInstance(xlog.redact(b"\xff"), str)

class Writing(Base):
    def test_format_and_perms(self):
        log = xlog.get("cmd"); log.info("started", pid=12, name="two words")
        t = self.text("cmd"); self.assertRegex(t, LINE)
        self.assertIn('pid=12 name="two words"', t)
        d = os.environ["SERPANTINUM_LOG_DIR"]
        self.assertEqual(oct(os.stat(d).st_mode & 0o777), "0o700")
        self.assertEqual(oct(os.stat(os.path.join(d, "cmd.log")).st_mode & 0o777), "0o600")
    def test_levels(self):
        log = xlog.get("tools"); log.debug("hidden"); log.warn("shown")
        t = self.text("tools"); self.assertNotIn("hidden", t); self.assertIn("WARN tools shown", t)
        os.environ["XLOG_LEVEL"] = "debug"; log.debug("now visible")
        self.assertIn("DEBUG tools now visible", self.text("tools"))
        os.environ["XLOG_LEVEL"] = "error"; log.warn("dropped"); self.assertNotIn("dropped", self.text("tools"))
    def test_level_file(self):
        subprocess.run([sys.executable, os.path.join(XLOG_DIR, "xlog.py"), "level", "debug"], check=True, capture_output=True)
        xlog.get("vpn").debug("dbg"); self.assertIn("dbg", self.text("vpn"))
    def test_exception_traceback_continuation(self):
        try:
            1 / 0
        except ZeroDivisionError:
            xlog.get("hotkeys").exception("boom", where="x")
        t = self.text("hotkeys"); self.assertIn("ERROR hotkeys boom", t); self.assertIn("ZeroDivisionError", t)
        self.assertTrue(all(l.startswith("    ") or LINE.match(l) for l in t.strip().split("\n")))
    def test_secret_in_message_and_kv(self):
        xlog.get("servers").info("call https://panel.canary-host.example/x?token=ZZZ", token="canary-token-value-1234567890abcdef", note="ok")
        t = self.text("servers"); self.assertNotIn("canary", t); self.assertIn("note=ok", t)
    def test_rotation(self):
        os.environ["XLOG_MAX_BYTES"] = "2000"
        import importlib; importlib.reload(xlog)
        for i in range(120): xlog.get("update").info("line number %d with some padding to grow the file" % i)
        d = os.environ["SERPANTINUM_LOG_DIR"]
        names = sorted(f for f in os.listdir(d) if f.startswith("update.log"))
        self.assertEqual(names, ["update.log", "update.log.1", "update.log.2"], names)
        self.assertLess(os.path.getsize(os.path.join(d, "update.log")), 4000)
        os.environ.pop("XLOG_MAX_BYTES"); importlib.reload(xlog)
    def test_bad_module_name_and_unwritable_dir(self):
        xlog.get("../../etc/x").info("no traversal")
        self.assertTrue(os.path.exists(os.path.join(os.environ["SERPANTINUM_LOG_DIR"], "misc.log")))
        os.environ["SERPANTINUM_LOG_DIR"] = "/proc/nope/logs"
        self.assertFalse(xlog.write_line("cmd", "info", "x"))   # must not raise
    def test_timer(self):
        with xlog.get("tools").timer("ocr", rc=0): pass
        self.assertRegex(self.text("tools"), r"INFO tools ocr ms=\d+ rc=0")

class Cli(Base):
    def run_py(self, *a, inp=None):
        return subprocess.run([sys.executable, os.path.join(XLOG_DIR, "xlog.py"), *a], input=inp, capture_output=True, text=True)
    def test_append_and_stdin(self):
        self.assertEqual(self.run_py("append", "update", "info", "hello", "world").returncode, 0)
        self.run_py("append-stdin", inp="tools\twarn\tfrom qml\\nsecond line\nbroken line\nvpn\terror\ttoken=abc123canary\n")
        self.assertIn("hello world", self.text("update")); self.assertIn("WARN tools from qml", self.text("tools"))
        self.assertIn("    second line", self.text("tools")); self.assertNotIn("abc123canary", self.text("vpn"))
    def test_logs_listing_and_filter(self):
        xlog.get("cmd").info("a"); xlog.get("cmd").error("bad thing"); xlog.get("vpn").info("fine")
        out = self.run_py("logs").stdout
        self.assertIn("cmd", out); self.assertIn("последняя проблема: ", out); self.assertIn("bad thing", out)
        tail = self.run_py("logs", "cmd", "--level", "error").stdout
        self.assertIn("bad thing", tail); self.assertNotIn(" INFO ", tail)
    def test_bash_helper(self):
        env = {**os.environ}
        r = subprocess.run(["bash", "-c", f'source "{XLOG_DIR}/xlog.sh"; xlog hotkeys info "apply rc=0 token=canarytok123"; xlog_run tools true; xlog_run tools false'],
                           env=env, capture_output=True, text=True)
        t = self.text("hotkeys"); self.assertIn("apply rc=0", t); self.assertNotIn("canarytok123", t)
        tt = self.text("tools"); self.assertIn("exec cmd=true rc=0", tt); self.assertIn("WARN tools exec cmd=false rc=1", tt)
    def test_report_redacted_and_private(self):
        stub = os.path.join(self.tmp, "x"); open(stub, "w").write('#!/usr/bin/env bash\necho "doctor says token=canary-doctor-secret https://panel.canary-host.example/k?t=1"\n'); os.chmod(stub, 0o755)
        os.environ["SERPANTINUM_X"] = stub
        xlog.get("cmd").info("run ok")
        out = os.path.join(self.tmp, "r.txt")
        r = self.run_py("report", "--out", out)
        self.assertEqual(r.returncode, 0, r.stderr)
        t = open(out, encoding="utf-8").read()
        self.assertIn("===== doctor =====", t); self.assertIn("run ok", t); self.assertNotIn("canary", t)
        self.assertEqual(oct(os.stat(out).st_mode & 0o777), "0o600")
    def test_doctor_json(self):
        xlog.get("vpn").error("kaput")
        d = json.loads(self.run_py("doctor").stdout)
        self.assertTrue(any("kaput" in c["text"] for c in d["checks"]))
        self.assertEqual(d["checks"][0]["level"], "ok")

if __name__ == "__main__":
    unittest.main(verbosity=1)
