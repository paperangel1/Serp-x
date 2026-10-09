#!/usr/bin/env python3
"""Offline tests for the Servers backend. Nothing here touches the network (only 127.0.0.1 on high ports), the
user's real config, real servers, real secrets, or any system file. Real `act-*` actions are never executed:
the unprivileged install mode replaces them with stubs."""
import base64
import sys as _sys
_sys.dont_write_bytecode = True
import http.server
import io
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVERS = HERE.parent / "servers"
PY = str(SERVERS / "x_servers.py")
sys.path.insert(0, str(SERVERS))
import x_servers as xs  # noqa: E402

ME = os.environ.get("USER") or subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
TOKEN = "tok_" + "x" * 28
FAKE_NODES = {"response": [
    {"uuid": "11111111-aaaa", "name": "🇳🇱 Нидерланды-1", "address": "nl1.example.test", "isConnected": True,
     "isXrayRunning": True, "xrayVersion": "26.7.28", "usersOnline": 128, "trafficUsedBytes": 1800, "countryCode": "NL"},
    {"uuid": "22222222-bbbb", "name": "Germany-1", "address": "de1.example.test", "isConnected": False,
     "isDisabled": False, "countryCode": "DE"},
]}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class MockPanel(http.server.BaseHTTPRequestHandler):
    payload = FAKE_NODES
    status = 200
    seen_auth = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        MockPanel.seen_auth.append(self.headers.get("Authorization"))
        if self.path.split("?")[0] != "/api/nodes":
            self.send_response(404)
            self.end_headers()
            return
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_response(401)
            self.end_headers()
            return
        body = json.dumps(MockPanel.payload) if not isinstance(MockPanel.payload, str) else MockPanel.payload
        self.send_response(MockPanel.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())


class Env:
    """Throw-away HOME with its own config/state dirs."""

    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="serp-test-"))
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home))
        for k in list(self.env):
            if k.startswith("SERP_") and k != "SERPANTINUM_LOG_DIR":
                self.env.pop(k)
        self.env.update(XDG_CONFIG_HOME=str(self.home / ".config"), XDG_STATE_HOME=str(self.home / ".local" / "state"),
                        XDG_CACHE_HOME=str(self.home / ".cache"))
        self.cfg = self.home / ".config" / "serpantinum"
        self.state = self.home / ".local" / "state" / "serpantinum"

    def run(self, *args, stdin="", env=None, timeout=60):
        e = dict(self.env, **(env or {}))
        return subprocess.run([sys.executable, PY, *args], input=stdin, capture_output=True, text=True, env=e, timeout=timeout)

    def js(self, *args, **kw):
        cp = self.run(*args, **kw)
        lines = [ln for ln in cp.stdout.splitlines() if ln.strip().startswith("{")]
        return json.loads(lines[-1]) if lines else {"_stdout": cp.stdout, "_stderr": cp.stderr}

    def write(self, rel, text, mode=0o600):
        p = self.cfg / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        p.chmod(mode)
        return p

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class Unit(unittest.TestCase):
    def test_ansi_and_control_stripped(self):
        self.assertEqual(xs.clean_text("\x1b[31mred\x1b[0m ok\x07\x00 \x1b]0;title\x07tail"), "red ok tail")
        self.assertEqual(len(xs.clean_text("a" * 5000)), xs.MAX_LINE_LEN)

    def test_flag_from_name_and_country(self):
        self.assertEqual(xs.flag_from("🇳🇱 Нидерланды-1", ""), "🇳🇱")
        self.assertEqual(xs.strip_flag("🇳🇱 Нидерланды-1"), "Нидерланды-1")
        self.assertEqual(xs.flag_from("Germany", "de"), "🇩🇪")
        self.assertEqual(xs.flag_from("Plain", ""), "")

    def test_nodes_shapes(self):
        item = {"uuid": "u1", "name": "Fin", "address": "a.test", "isConnected": True}
        for shape in ({"response": [item]}, [item], {"data": [item]}, {"nodes": [item]}, {"response": {"nodes": [item]}}):
            nodes = [xs.normalize_node(n) for n in xs._nodes_from(shape)]
            self.assertEqual(len(nodes), 1, shape)
            self.assertTrue(nodes[0]["online"])
        n = xs.normalize_node({"id": "x", "nodeName": "Old", "host": "h.test", "status": "online"})
        self.assertEqual((n["name"], n["address"], n["online"]), ("Old", "h.test", True))
        self.assertFalse(xs.normalize_node({"uuid": "x", "name": "n", "isConnected": True, "isDisabled": True})["online"])

    def test_token_regex(self):
        for ok in ("status", "diag-net", "a", "x" * 32):
            self.assertTrue(xs.TOKEN_RE.match(ok), ok)
        for bad in ("", "Status", "a b", "a;b", "../x", "x" * 33, "-lead", "a\nb", "a$(id)"):
            self.assertFalse(xs.TOKEN_RE.match(bad), repr(bad))

    def test_predefined_commands(self):
        ids = {c["id"] for c in xs.PREDEFINED}
        self.assertEqual(len(ids), 10)
        self.assertEqual(next(c for c in xs.PREDEFINED if c["id"] == "act-reboot")["danger"], "typed")
        for c in xs.PREDEFINED:
            self.assertTrue((SERVERS / "server" / "commands.d" / c["id"]).is_file(), c["id"])


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        os.environ["HOME"] = str(self.e.home)
        for k in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            os.environ[k] = self.e.env[k]

    def tearDown(self):
        self.e.close()

    def test_custom_commands_validation(self):
        self.e.write("servers/commands.toml", """
[[command]]
id = "backup-db"
label = "Бэкап базы"
danger = "confirm"
timeout = 120
[[command]]
id = "Bad ID"
[[command]]
id = "diag-net"
[[command]]
id = "ok-two"
danger = "weird"
""")
        cmds, problems = xs.custom_commands()
        self.assertEqual([c["id"] for c in cmds], ["backup-db", "ok-two"])
        self.assertEqual(cmds[1]["danger"], "confirm")
        self.assertEqual(len(problems), 2)

    def test_broken_toml_reported(self):
        self.e.write("servers/commands.toml", "[[command\nid=")
        cmds, problems = xs.custom_commands()
        self.assertEqual(cmds, [])
        self.assertTrue(problems)

    def test_manual_and_match_override(self):
        self.e.write("servers/servers.toml", """
[[server]]
match = "germany-1"
host = "ssh.de.example.test"
port = 2222
user = "ops"
[[server]]
name = "🇫🇮 Own box"
host = "box.example.test"
""")
        nodes = [xs.normalize_node(n) for n in xs._nodes_from(FAKE_NODES)]
        merged = xs.merge_servers(nodes)
        de = next(s for s in merged if s["name"] == "Germany-1")
        self.assertEqual((de["address"], de["port"], de["user"]), ("ssh.de.example.test", 2222, "ops"))
        box = next(s for s in merged if s["source"] == "manual")
        self.assertEqual((box["name"], box["flag"], box["id"]), ("Own box", "🇫🇮", "m:own-box"))
        self.assertEqual(len(merged), 3)


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", cls.port), MockPanel)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.e = Env()
        MockPanel.payload, MockPanel.status = FAKE_NODES, 200
        os.environ["HOME"] = str(self.e.home)
        os.environ.pop("XDG_CONFIG_HOME", None)

    def tearDown(self):
        self.e.close()

    def creds(self, url=None, token=TOKEN):
        self.e.write("secrets/remnawave_url", (url or f"http://127.0.0.1:{self.port}") + "\n")
        self.e.write("secrets/remnawave_token", token + "\n")

    def test_not_configured(self):
        self.assertEqual(xs.api_fetch_nodes(), ([], "not_configured"))

    def test_fetch_ok_and_bearer(self):
        self.creds()
        nodes, err = xs.api_fetch_nodes()
        self.assertIsNone(err)
        self.assertEqual([n["name"] for n in nodes], ["Нидерланды-1", "Germany-1"])
        self.assertEqual(nodes[0]["flag"], "🇳🇱")
        self.assertEqual(nodes[0]["usersOnline"], 128)
        self.assertEqual(MockPanel.seen_auth[-1], "Bearer " + TOKEN)

    def test_bad_token_error_has_no_secrets(self):
        self.creds(token="wrong-token-123456")
        nodes, err = xs.api_fetch_nodes()
        self.assertEqual((nodes, err), ([], "http_401"))
        self.assertNotIn("wrong-token", err)

    def test_http_remote_rejected(self):
        self.creds(url="http://panel.example.test")
        self.assertEqual(xs.api_fetch_nodes()[1], "insecure_url")

    def test_bad_json_and_other_shape(self):
        self.creds()
        MockPanel.payload = "not json"
        self.assertEqual(xs.api_fetch_nodes()[1], "bad_response")
        MockPanel.payload = [{"id": "z", "nodeName": "Plain list", "host": "p.test", "status": "online"}]
        nodes, err = xs.api_fetch_nodes()
        self.assertIsNone(err)
        self.assertEqual(nodes[0]["name"], "Plain list")

    def test_network_error_has_no_url(self):
        self.creds(url=f"http://127.0.0.1:{free_port()}")
        nodes, err = xs.api_fetch_nodes()
        self.assertEqual(nodes, [])
        self.assertTrue(err.startswith("network:"))
        self.assertNotIn("127.0.0.1", err)

    def test_poll_cli_and_events(self):
        self.creds()
        r = self.e.js("poll")
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["servers"]), 2)
        self.assertTrue(r["configured"])
        self.assertNotIn(TOKEN, json.dumps(r))
        # node goes down -> server.down event
        MockPanel.payload = {"response": [dict(FAKE_NODES["response"][0], isConnected=False), FAKE_NODES["response"][1]]}
        self.e.js("poll")
        ev = (self.e.state / "events.jsonl").read_text().splitlines()
        self.assertTrue(any('"server.down"' in ln for ln in ev), ev)
        self.assertNotIn("nl1.example.test", "".join(ev))  # no addresses on the bus

    def test_secret_set_and_status(self):
        r = self.e.js("secret-set", "remnawave_url", stdin="https://panel.example.test/\n")
        self.assertTrue(r["ok"])
        self.assertEqual((self.e.cfg / "secrets" / "remnawave_url").read_text().strip(), "https://panel.example.test")
        self.assertEqual(stat.S_IMODE((self.e.cfg / "secrets" / "remnawave_url").stat().st_mode), 0o600)
        self.assertFalse(self.e.js("secret-set", "remnawave_url", stdin="ftp://x\n")["ok"])
        self.assertFalse(self.e.js("secret-set", "remnawave_url", stdin="http://panel.example.test\n")["ok"])
        self.assertFalse(self.e.js("secret-set", "remnawave_token", stdin="short\n")["ok"])
        self.assertFalse(self.e.js("secret-set", "remnawave_token", stdin="has space token 1234\n")["ok"])
        self.assertTrue(self.e.js("secret-set", "remnawave_token", stdin=TOKEN + "\n")["ok"])
        st = self.e.js("secret-status")
        self.assertEqual((st["urlSet"], st["tokenSet"], st["host"]), (True, True, "panel.example.test"))
        self.assertNotIn(TOKEN, json.dumps(self.e.js("config")))
        self.assertFalse(self.e.js("secret-set", "other", stdin="x\n")["ok"])

    def test_doctor_flags_loose_permissions(self):
        self.creds()
        (self.e.cfg / "secrets" / "remnawave_token").chmod(0o644)
        cp = self.e.run("doctor")
        checks = json.loads(cp.stdout)["checks"]
        self.assertTrue(any(c["level"] == "fail" and "remnawave_token" in c["text"] for c in checks))
        self.assertNotEqual(cp.returncode, 0)


class KeyAndEnrollOffline(unittest.TestCase):
    def setUp(self):
        self.e = Env()

    def tearDown(self):
        self.e.close()

    def test_key_new_info_oneliner(self):
        self.assertFalse(self.e.js("key-info")["exists"])
        r = self.e.js("key-new")
        self.assertTrue(r["ok"])
        self.assertTrue(r["fingerprint"].startswith("SHA256:"))
        self.assertEqual(stat.S_IMODE((self.e.cfg / "servers" / "id_serp").stat().st_mode), 0o600)
        self.assertFalse(self.e.js("key-new")["ok"])  # refuses to overwrite
        self.assertTrue(self.e.js("key-new", "--force")["ok"])
        one = self.e.js("oneliner")
        self.assertTrue(one["ok"])
        cmd = one["command"]
        self.assertIn("base64 -d", cmd)
        self.assertNotIn("PRIVATE", cmd)
        pub = (self.e.cfg / "servers" / "id_serp.pub").read_text().split()[1]
        self.assertIn(pub, cmd)
        b64 = re.search(r"echo '?([A-Za-z0-9+/=]{200,})", cmd).group(1)
        names = tarfile.open(fileobj=io.BytesIO(base64.b64decode(b64)), mode="r:gz").getnames()
        for n in ("serp-run", "serp-root", "install.sh", "commands.d/status", "commands.d/act-reboot"):
            self.assertIn(n, names)
        priv = (self.e.cfg / "servers" / "id_serp").read_text().split()[3][:20]
        self.assertNotIn(priv, cmd)

    def test_enroll_password_is_never_exposed(self):
        """A stub `ssh` records argv, runs the askpass helper and plays the server side."""
        self.e.js("key-new")
        self.e.write("servers/servers.toml", '[[server]]\nname="Box"\nhost="box.example.test"\n')
        stub_dir = self.e.tmp / "bin"
        stub_dir.mkdir()
        rec = self.e.tmp / "rec"
        rec.mkdir()
        (stub_dir / "ssh").write_text(f"""#!/bin/bash
echo "$@" > {rec}/argv.$$
last="${{@: -1}}"
if [ "$last" = "status" ]; then
    echo '{{"cpu":3,"uptime":10,"load":[0.1,0.2,0.3],"diskPct":20}}'; exit 0
fi
if [ -n "$SSH_ASKPASS" ]; then "$SSH_ASKPASS" "login password:" > {rec}/askpass.$$; fi
cat > {rec}/stdin.$$
echo SERP_INSTALL_OK
""")
        (stub_dir / "ssh").chmod(0o755)
        pw = "S3cret-PW-9917"
        env = {"PATH": f"{stub_dir}:{os.environ['PATH']}"}
        for user in ("root", "admin"):
            r = self.e.js("enroll", "--host", "box.example.test", "--user", user, stdin=pw + "\n", env=env)
            self.assertTrue(r["ok"], r)
        files = {p.name.split(".")[0] + "." + str(i): p.read_text() for i, p in enumerate(sorted(rec.iterdir()))}
        argv_all = " ".join(v for k, v in files.items() if k.startswith("argv"))
        self.assertNotIn(pw, argv_all)
        self.assertIn("StrictHostKeyChecking=accept-new", argv_all)
        self.assertIn("PubkeyAuthentication=no", argv_all)
        self.assertIn("NumberOfPasswordPrompts=1", argv_all)
        self.assertTrue(any(v.strip() == pw for k, v in files.items() if k.startswith("askpass")))
        stdins = [v for k, v in files.items() if k.startswith("stdin")]
        self.assertEqual(sum(1 for v in stdins if v.startswith(pw + "\n")), 1)  # only the sudo (non-root) run feeds it
        self.assertEqual(sum(1 for v in stdins if pw in v), 1)
        for p in self.e.tmp.rglob("*"):
            if p.is_file() and p.parent != rec:
                self.assertNotIn(pw, p.read_text(errors="ignore"), p)  # not in state, history, config, events
        self.assertTrue("sudo -S -p" in argv_all)  # non-root login goes through sudo


class SshTests(unittest.TestCase):
    """Local unprivileged sshd on a high 127.0.0.1 port; real forced command, real scripts, stubbed act-* actions."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="serp-sshd-"))
        t = cls.tmp
        cls.port = free_port()
        run = lambda *a: subprocess.run(a, check=True, capture_output=True)
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(t / "host"))
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(t / "admin"))
        cls.admin_ak = t / "ak_admin"
        cls.admin_ak.write_text((t / "admin.pub").read_text())
        cls.serp_ak = t / "ak_serp"
        cls.serp_ak.write_text("")
        (t / "sshd_config").write_text(f"""Port {cls.port}
ListenAddress 127.0.0.1
HostKey {t}/host
PidFile {t}/sshd.pid
AuthorizedKeysFile {cls.admin_ak} {cls.serp_ak}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel ERROR
""")
        cls.proc = subprocess.Popen(["/usr/bin/sshd", "-D", "-e", "-f", str(t / "sshd_config")],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=0.3).close()
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise unittest.SkipTest("sshd did not start: " + cls.proc.stderr.read().decode()[:300])
        cls.prefix = t / "root"
        cls.e = Env()
        cls.e.js("key-new")
        cls.e.write("servers/servers.toml", f'[[server]]\nname = "Local"\nhost = "127.0.0.1"\nport = {cls.port}\nuser = "{ME}"\n')
        cls.e.write("servers/commands.toml", """
[[command]]
id = "t-echo"
label = "Echo"
script = "SCRIPT_ECHO"
[[command]]
id = "t-flood"
label = "Flood"
script = "SCRIPT_FLOOD"
timeout = 20
""".replace("SCRIPT_ECHO", str(t / "t-echo.sh")).replace("SCRIPT_FLOOD", str(t / "t-flood.sh")))
        (t / "t-echo.sh").write_text("#!/bin/sh\nprintf '\\033[31mred\\033[0m ok\\n'\necho \"cmd-ok\"\n")
        (t / "t-flood.sh").write_text("#!/bin/sh\ni=0; while [ $i -lt 1000 ]; do echo line-$i; i=$((i+1)); done\n")
        cls.enroll_env = {"SERP_TEST_MODE": "1", "SERP_TEST_ADMIN_KEY": str(t / "admin"), "SERP_TEST": "1",
                          "SERP_PREFIX": str(cls.prefix), "SERP_AUTH_KEYS": str(cls.serp_ak),
                          "SERP_TEST_SERP_USER": ME}
        cls.enrolled = cls.e.js("enroll", "--host", "127.0.0.1", "--port", str(cls.port), "--user", ME,
                                "--serp-user", ME, "--server", "m:local", env=cls.enroll_env)

    @classmethod
    def tearDownClass(cls):
        cls.proc.send_signal(signal.SIGTERM)
        try:
            cls.proc.wait(5)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.e.close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def raw(self, remote_cmd, extra=None, timeout=30):
        cmd = xs_ssh_base(self.e, self.port) + (extra or []) + ([remote_cmd] if remote_cmd is not None else [])
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    def test_00_enrollment_worked(self):
        self.assertTrue(self.enrolled["ok"], self.enrolled)
        self.assertEqual(self.enrolled["state"], "ok")
        ak = self.serp_ak.read_text()
        self.assertTrue(ak.startswith('restrict,command="'), ak)
        self.assertIn("ssh-ed25519", ak)
        self.assertEqual(ak.count("\n"), 1)
        kh = (self.e.cfg / "servers" / "known_hosts").read_text()
        self.assertIn("127.0.0.1", kh)

    def test_status_json(self):
        r = self.raw("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout.strip().splitlines()[-1])
        for k in ("cpu", "load", "memTotalKb", "diskPct", "uptime", "host", "kernel"):
            self.assertIn(k, d)
        self.assertGreater(d["uptime"], 0)

    def test_empty_command_means_status(self):
        r = self.raw(None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('"uptime"', r.stdout)

    def test_injection_and_bad_tokens_rejected(self):
        marker = self.tmp / "pwned"
        for bad in ("status; touch %s" % marker, "status && id", "$(id)", "`id`", "../../bin/sh", "STATUS", "a b",
                    "x" * 33, "status\nid", "-h", "sh", "bash -c id", "diag-net|id"):
            r = self.raw(bad)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertNotIn("uid=", r.stdout + r.stderr, bad)
        self.assertFalse(marker.exists())

    def test_unknown_token(self):
        r = self.raw("nope")
        self.assertEqual(r.returncode, 127)
        self.assertIn("unknown command", r.stdout + r.stderr)

    def test_no_pty_no_forwarding(self):
        r = self.raw("status", extra=["-tt"])
        self.assertIn("PTY allocation request failed", r.stderr)
        # restrict = no-port-forwarding: a direct-tcpip channel (stdio forwarding) must be refused by the server
        r2 = self.raw(None, extra=["-W", f"127.0.0.1:{self.port}"], timeout=15)
        self.assertNotEqual(r2.returncode, 0, r2.stderr)

    def test_act_scripts_are_stubbed_in_tests(self):
        r = self.raw("act-reboot")
        self.assertIn("TEST STUB act-reboot", r.stdout)

    def test_group_writable_script_refused_and_timeout_header(self):
        cmddir = self.prefix / "etc" / "serpantinum" / "commands.d"
        s = cmddir / "t-bad"
        s.write_text("#!/bin/sh\necho should-not-run\n")
        s.chmod(0o775)
        r = self.raw("t-bad")
        self.assertEqual(r.returncode, 126)
        self.assertNotIn("should-not-run", r.stdout)
        slow = cmddir / "t-slow"
        slow.write_text("#!/bin/sh\n# serp-timeout: 1\nsleep 5\necho late\n")
        slow.chmod(0o755)
        t0 = time.time()
        r = self.raw("t-slow")
        self.assertLess(time.time() - t0, 4)
        self.assertNotIn("late", r.stdout)
        link = cmddir / "t-link"
        link.symlink_to("/bin/true")
        self.assertNotEqual(self.raw("t-link").returncode, 0)

    def test_poll_ssh_and_backoff(self):
        r = self.e.js("poll", "--ssh")
        loc = next(s for s in r["servers"] if s["name"] == "Local")
        self.assertEqual(loc["ssh"]["state"], "ok", loc)
        self.assertTrue(loc["enrolled"])
        self.assertIn("cpu", loc["ssh"]["status"])
        # break the connection: forget the key -> state denied -> backoff on the next poll
        bad = Env()
        bad.write("servers/servers.toml", f'[[server]]\nname = "Dead"\nhost = "127.0.0.1"\nport = {free_port()}\nuser = "{ME}"\n')
        bad.js("key-new")
        a = bad.js("poll", "--ssh")["servers"][0]
        self.assertIn(a["ssh"]["state"], ("unreachable", "unenrolled", "error"))
        b = bad.js("poll", "--ssh")["servers"][0]
        self.assertTrue(b["ssh"].get("backoff"), b)
        bad.close()

    def test_run_streams_output_ansi_cap_and_history(self):
        # sync the custom scripts first (same code path as enrollment)
        r = self.e.js("enroll", "--host", "127.0.0.1", "--port", str(self.port), "--user", ME, "--serp-user", ME,
                      "--server", "m:local", env=self.enroll_env)
        self.assertTrue(r["ok"], r)
        cp = self.e.run("run", "m:local", "t-echo")
        lines = cp.stdout.splitlines()
        self.assertTrue(lines[0].startswith("::serp-start::"))
        nonce = lines[0].split("::")[-1]
        self.assertIn("red ok", lines)
        self.assertIn("cmd-ok", lines)
        self.assertNotIn("\x1b", cp.stdout)
        ex = json.loads(lines[-1].split("::", 3)[-1])
        self.assertTrue(lines[-1].startswith(f"::serp-exit::{nonce}::"))
        self.assertEqual(ex["code"], 0)
        cp = self.e.run("run", "m:local", "t-flood")
        out_lines = cp.stdout.splitlines()
        text = [ln for ln in out_lines if ln.startswith("line-")]
        self.assertEqual(len(text), 400)
        ex = json.loads(out_lines[-1].split("::", 3)[-1])
        self.assertEqual(ex["dropped"], 600)
        hist = self.e.js("history", "-n", "5")["history"]
        self.assertEqual(hist[0]["command"], "t-flood")
        self.assertIn("server.command", (self.e.state / "events.jsonl").read_text())

    def test_run_rejects_unknown_command_and_server(self):
        cp = self.e.run("run", "m:local", "rm-rf")
        self.assertIn('"error": "unknown command"', cp.stdout)
        cp = self.e.run("run", "m:ghost", "diag-net")
        self.assertIn('"error": "unknown server"', cp.stdout)

    def test_enroll_rerun_is_idempotent_and_drops_stale(self):
        cmddir = self.prefix / "etc" / "serpantinum" / "commands.d"
        (cmddir / "t-stale").write_text("#!/bin/sh\necho stale\n")
        (cmddir / "t-stale").chmod(0o755)
        r = self.e.js("enroll", "--host", "127.0.0.1", "--port", str(self.port), "--user", ME, "--serp-user", ME,
                      env=self.enroll_env)
        self.assertTrue(r["ok"], r)
        self.assertFalse((cmddir / "t-stale").exists())
        self.assertEqual(self.serp_ak.read_text().count("\n"), 1)

    def test_zz_uninstall_removes_restricted_access(self):
        r = self.e.js("enroll", "--host", "127.0.0.1", "--port", str(self.port), "--user", ME, "--serp-user", ME,
                      "--server", "m:local", "--uninstall", env=self.enroll_env)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["state"], "removed")
        self.assertFalse(self.serp_ak.exists())


class ManualServers(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.toml = self.e.cfg / "servers" / "servers.toml"

    def tearDown(self):
        self.e.close()

    def add(self, name="Мой VPS", host="vps.example.test", *extra):
        return self.e.js("add", "--name", name, "--host", host, *extra)

    def test_add_creates_dir_and_file_with_modes(self):
        r = self.add()
        self.assertTrue(r["ok"], r)
        self.assertEqual(stat.S_IMODE(self.toml.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.toml.parent.stat().st_mode), 0o700)
        import tomllib
        row = tomllib.loads(self.toml.read_text())["server"][0]
        self.assertEqual((row["name"], row["host"], row["port"], row["user"]), ("Мой VPS", "vps.example.test", 22, "serp"))
        self.assertFalse(list(self.toml.parent.glob("*.tmp.*")))

    def test_id_slug_unique(self):
        a = self.add("Box One", "a.example.test")["server"]["id"]
        b = self.add("Box One", "b.example.test")["server"]["id"]
        c = self.add("Box One", "c.example.test")["server"]["id"]
        self.assertEqual((a, b, c), ("m:box-one", b, c))
        self.assertEqual(len({a, b, c}), 3)
        self.assertTrue(all(i.startswith("m:") for i in (a, b, c)))   # can never equal a panel uuid
        r = self.add("Other", "d.example.test", "--id", "box-one")
        self.assertEqual((r["ok"], r["error"]), (False, "id_taken"))
        self.assertEqual(self.add("Cyr", "e.example.test", "--id", "Bad ID")["error"], "bad_id")

    def test_cyrillic_name_gets_ascii_id(self):
        r = self.add("Мой сервер", "x.example.test")
        self.assertRegex(r["server"]["id"], r"^m:[a-z0-9-]+$")

    def test_does_not_collide_with_panel_state_ids(self):
        self.e.write("../../.local/state/serpantinum/servers/state.json", json.dumps({"servers": {"box": {"name": "Box"}}}), 0o600)
        self.assertNotEqual(self.add("Box", "p.example.test")["server"]["id"], "m:box")

    def test_validation(self):
        bad = [("name", ["--name", "", "--host", "a.test"]), ("name", ["--name", "x" * 61, "--host", "a.test"]),
               ("name", ["--name", "a\x07b", "--host", "a.test"]), ("name", ["--name", "a\nb", "--host", "a.test"]),
               ("host", ["--name", "n", "--host", "a b.test"]), ("host", ["--name", "n", "--host", "a;rm.test"]),
               ("host", ["--name", "n", "--host", "$(id).test"]), ("host", ["--name", "n", "--host=-oProxy.test"]),
               ("host", ["--name", "n", "--host", "999.1.1.1"]), ("host", ["--name", "n", "--host", "1.2.3"]),
               ("host", ["--name", "n", "--host", "a..b"]), ("host", ["--name", "n", "--host", "fe80::1%eth0"]),
               ("host", ["--name", "n", "--host", "http://a.test"]),
               ("port", ["--name", "n", "--host", "a.test", "--port", "0"]), ("port", ["--name", "n", "--host", "a.test", "--port", "65536"]),
               ("user", ["--name", "n", "--host", "a.test", "--user", "Root"]), ("user", ["--name", "n", "--host", "a.test", "--user", "a b"]),
               ("user", ["--name", "n", "--host", "a.test", "--user", "x" * 33]), ("user", ["--name", "n", "--host", "a.test", "--user", "1abc"])]
        for field, args in bad:
            r = self.e.js("add", *args)
            self.assertFalse(r.get("ok"), args)
            self.assertEqual(r.get("field"), field, (args, r))
        self.assertFalse(self.toml.exists())
        for host in ("a.example.test", "10.0.0.1", "2001:db8::1", "xn--e1afmkfd.test", "localhost", "my-host"):
            self.assertTrue(self.e.js("add", "--name", host, "--host", host, "--port", "2222")["ok"], host)

    def test_append_preserves_comments_and_backup(self):
        orig = '# my notes\n[[server]]\nmatch = "germany-1"\nhost = "ssh.de.example.test"  # override\n\n[other]\nk = 1\n'
        self.e.write("servers/servers.toml", orig)
        self.assertTrue(self.add()["ok"])
        txt = self.toml.read_text()
        self.assertTrue(txt.startswith(orig))
        self.assertEqual((self.toml.parent / "servers.toml.bak").read_text(), orig)
        self.assertEqual(stat.S_IMODE((self.toml.parent / "servers.toml.bak").stat().st_mode), 0o600)
        self.assertTrue(self.add("Two", "two.example.test")["ok"])
        self.assertIn("vps.example.test", (self.toml.parent / "servers.toml.bak").read_text())   # rolling

    def test_broken_file_is_not_touched(self):
        self.e.write("servers/servers.toml", "[[server\nbroken")
        r = self.add()
        self.assertEqual(r["error"], "config_broken")
        self.assertEqual(self.toml.read_text(), "[[server\nbroken")

    def test_idempotent_and_duplicate(self):
        a = self.add()
        b = self.add()
        self.assertTrue(b["ok"] and b["existed"])
        self.assertEqual(a["server"]["id"], b["server"]["id"])
        self.assertEqual(self.toml.read_text().count("[[server]]"), 1)
        c = self.add("Renamed", "vps.example.test")
        self.assertEqual((c["ok"], c["error"]), (False, "duplicate"))
        self.assertEqual(self.toml.read_text().count("[[server]]"), 1)

    def test_atomic_write_leaves_old_file_on_failure(self):
        self.assertTrue(self.add()["ok"])
        before = self.toml.read_text()
        (self.toml.parent / "servers.toml.bak").unlink(missing_ok=True)
        (self.toml.parent / "servers.toml.bak").mkdir()        # the backup step fails -> nothing is replaced
        r = self.add("Two", "two.example.test")
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "write_failed")
        self.assertFalse(list(self.toml.parent.glob("*.tmp.*")))
        self.assertEqual(self.toml.read_text(), before)

    def test_special_chars_roundtrip(self):
        n = 'He said "hi" \\ back'
        self.assertTrue(self.add(n, "q.example.test")["ok"])
        self.assertEqual(self.e.js("list")["servers"][0]["name"], n)

    def test_remove(self):
        self.e.write("servers/servers.toml", '# keep me\n[[server]]\nmatch = "germany-1"\nhost = "x.example.test"\n')
        a = self.add("Alpha", "a.example.test")["server"]["id"]
        b = self.add("Beta", "b.example.test")["server"]["id"]
        r = self.e.js("remove", a)
        self.assertEqual((r["ok"], r["removed"]), (True, True))
        txt = self.toml.read_text()
        self.assertIn("# keep me", txt)
        self.assertIn('match = "germany-1"', txt)
        self.assertNotIn("Alpha", txt)
        self.assertIn("Beta", txt)
        self.assertEqual([x["id"] for x in self.e.js("list")["servers"]], [b])
        again = self.e.js("remove", a)                   # idempotent
        self.assertEqual((again["ok"], again["removed"]), (True, False))
        self.assertEqual(self.e.js("remove", b[2:])["removed"], True)   # slug without prefix works too
        self.assertIn('match = "germany-1"', self.toml.read_text())

    def test_remove_never_touches_panel_or_override(self):
        self.e.write("servers/servers.toml", '[[server]]\nmatch = "germany-1"\nhost = "x.example.test"\n')
        before = self.toml.read_text()
        for sid in ("11111111-aaaa", "m:germany-1", "germany-1", "m:x"):
            self.assertFalse(self.e.js("remove", sid)["removed"], sid)
        self.assertEqual(self.toml.read_text(), before)

    def test_remove_forgets_known_hosts(self):
        if not shutil.which("ssh-keygen"):
            self.skipTest("no ssh-keygen")
        self.add("Alpha", "a.example.test")
        kg = self.e.tmp / "k"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(kg)], check=True)
        pub = (self.e.tmp / "k.pub").read_text().split()
        (self.e.cfg / "servers").mkdir(parents=True, exist_ok=True)
        kh = self.e.cfg / "servers" / "known_hosts"
        kh.write_text(f"a.example.test {pub[0]} {pub[1]}\nother.example.test {pub[0]} {pub[1]}\n")
        r = self.e.js("remove", "m:alpha", "--forget-host")
        self.assertTrue(r["removed"] and r["forgotHost"])
        txt = kh.read_text()
        self.assertNotIn("a.example.test", txt)
        self.assertIn("other.example.test", txt)
        self.assertFalse((kh.parent / "known_hosts.old").exists())

    def test_poll_merges_manual_without_panel(self):
        self.add("Alpha", "127.0.0.1", "--port", "9")
        r = self.e.js("poll")
        self.assertEqual(r["apiError"], "not_configured")
        self.assertFalse(r["configured"])
        s = r["servers"][0]
        self.assertEqual((s["id"], s["manual"], s["name"], s["enrolled"]), ("m:alpha", True, "Alpha", False))
        self.assertNotEqual(s["ssh"]["state"], "ok")

    def test_poll_merges_manual_with_panel(self):
        port = free_port()
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), MockPanel)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            MockPanel.payload, MockPanel.status = FAKE_NODES, 200
            self.e.js("secret-set", "remnawave_url", stdin=f"http://127.0.0.1:{port}\n")
            self.e.js("secret-set", "remnawave_token", stdin=TOKEN + "\n")
            self.add("Alpha", "127.0.0.1", "--port", "9")
            r = self.e.js("poll")
            self.assertEqual(len(r["servers"]), 3)
            self.assertEqual([s["id"] for s in r["servers"] if s.get("manual")], ["m:alpha"])
            self.assertFalse(any(s.get("manual") for s in r["servers"] if s["uuid"]))
        finally:
            srv.shutdown()

    def test_logs_have_no_hosts(self):
        logdir = self.e.tmp / "logs"
        env = {"SERPANTINUM_LOG_DIR": str(logdir)}
        self.e.js("add", "--name", "Secretbox", "--host", "203.0.113.77", env=env)
        blob = "".join(p.read_text(errors="replace") for p in logdir.rglob("*") if p.is_file())
        self.assertIn("m:secretbox", blob)
        self.assertNotIn("203.0.113.77", blob)


def xs_ssh_base(e, port):
    return ["ssh", "-T", "-i", str(e.cfg / "servers" / "id_serp"), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", f"UserKnownHostsFile={e.cfg / 'servers' / 'known_hosts'}", "-o", "StrictHostKeyChecking=yes",
            "-o", "LogLevel=ERROR", "-p", str(port), f"{ME}@127.0.0.1"]


if __name__ == "__main__":
    unittest.main(verbosity=1)
