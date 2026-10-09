"""Fixtures for the VPN tests: temp dirs wired through XVPN_* env, fake systemctl/xray, local servers.
Nothing here touches the real network, systemd or the user's data."""
import base64
import http.server
import json
import os
import shutil
import socket
import stat
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
VPN_DIR = HERE.parent.parent / "vpn"
sys.path.insert(0, str(VPN_DIR))

from xvpn import paths  # noqa: E402

FAKE_UUID = "11111111-2222-3333-4444-555555555555"
PBK = "A" * 43          # valid base64url of 32 bytes: the real xray -test checks REALITY keys

LINKS = [
    f"vless://{FAKE_UUID}@nl1.example.net:443?type=tcp&security=reality&sni=www.example.com&fp=chrome&pbk={PBK}&sid=ab12&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20%D0%9D%D0%B8%D0%B4%D0%B5%D1%80%D0%BB%D0%B0%D0%BD%D0%B4%D1%8B-1",
    f"vless://{FAKE_UUID}@de1.example.net:8443?type=ws&security=tls&sni=de1.example.net&path=%2Fws&host=de1.example.net#%F0%9F%87%A9%F0%9F%87%AA%20%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F-1",
    "ss://" + base64.urlsafe_b64encode(b"chacha20-ietf-poly1305:pass-word-1").decode().rstrip("=") + "@fi1.example.net:8388#%F0%9F%87%AB%F0%9F%87%AE%20Finland-1",
    "ss://" + base64.b64encode(b"aes-256-gcm:legacy-pass@se1.example.net:8389").decode() + "#Sweden-1",
    "trojan://trojan-pass@us1.example.net:443?security=tls&sni=us1.example.net#%F0%9F%87%BA%F0%9F%87%B8%20USA-1",
    "hysteria2://hy2-auth@jp1.example.net:443/?sni=jp1.example.net&obfs=salamander&obfs-password=obfspw#%F0%9F%87%AF%F0%9F%87%B5%20Japan-1",
]


def b64_body(links=None):
    return base64.b64encode("\n".join(links or LINKS).encode()).decode()


class Env:
    """Temp state/secrets/data/settings + stub binaries on env vars. Use as a context manager."""

    def __init__(self):
        self.td = Path(tempfile.mkdtemp(prefix="xvpn-t-"))
        self.state = self.td / "state"
        self.secrets = self.td / "secrets"
        self.data = self.td / "data"
        self.sysnet = self.td / "sysnet"
        self.stub = self.td / "stub"
        self.settings = self.td / "settings.json"
        self.etc = self.td / "etc"
        for d in (self.state, self.secrets, self.data, self.sysnet, self.stub, self.etc):
            d.mkdir(parents=True)
        self.old = {}
        self.write_settings({})
        self._systemctl()
        self.xray()
        self._notify()
        self._happ_stubs()
        self._journal()

    def _happ_stubs(self):
        """pgrep/ip fakes: Happ's core 'runs' only when <stub>/happ-core exists, happ-xray holds a default route only when <stub>/happ-route exists."""
        p = self.stub / "pgrep"
        p.write_text(f'#!/usr/bin/env bash\n[ -f "{self.stub}/happ-core" ]\n')
        p.chmod(0o755)
        p = self.stub / "ip"
        p.write_text(f'#!/usr/bin/env bash\nif [ -f "{self.stub}/happ-route" ] && [[ " $* " == *" -4 "* ]]; then echo "default dev happ-xray scope link"; fi\nexit 0\n')
        p.chmod(0o755)

    def happ(self, core=False, route=False):
        for name, on in (("happ-core", core), ("happ-route", route)):
            f = self.stub / name
            f.write_text("1") if on else (f.unlink() if f.exists() else None)

    def write_settings(self, vpn):
        self.settings.write_text(json.dumps({"vpn": vpn}))

    def _systemctl(self):
        p = self.stub / "systemctl"
        p.write_text(f"""#!/usr/bin/env bash
d="{self.stub}"
case "$1" in
  is-active) f="$d/state-$2"; if [ -f "$f" ]; then cat "$f"; [ "$(cat "$f")" = active ]; exit $?; fi; echo inactive; exit 3;;
  start|restart) echo "$@" >> "$d/calls"; [ -f "$d/fail-start" ] && exit 1
      echo active > "$d/state-$2"; if [ "$2" = serp-xray.service ]; then mkdir -p "{self.sysnet}/serp-xray/statistics"; echo 1000 > "{self.sysnet}/serp-xray/statistics/rx_bytes"; echo 500 > "{self.sysnet}/serp-xray/statistics/tx_bytes"; fi; exit 0;;
  stop) echo "$@" >> "$d/calls"; echo inactive > "$d/state-$2"; rm -rf "{self.sysnet}/serp-xray"; exit 0;;
  *) exit 0;;
esac
""")
        p.chmod(0o755)

    def xray(self, ok=True, text=None):
        p = self.stub / "xray"
        body = text or ("Xray 26.3.27 (stub)\nConfiguration OK." if ok else "Failed to start: bad config")
        p.write_text(f"#!/usr/bin/env bash\ncat <<'EOT'\n{body}\nEOT\nexit {0 if ok else 23}\n")
        p.chmod(0o755)

    def _journal(self):
        p = self.stub / "journalctl"
        p.write_text(f'#!/usr/bin/env bash\ncat "{self.stub}/journal" 2>/dev/null\nexit 0\n')
        p.chmod(0o755)

    def journal(self, text):
        (self.stub / "journal").write_text(text)

    def resolve_map(self, m):
        os.environ["XVPN_RESOLVE_MAP"] = json.dumps(m)

    def _notify(self):
        p = self.stub / "notify-send"
        p.write_text(f'#!/usr/bin/env bash\necho "$@" >> "{self.stub}/notified"\n')
        p.chmod(0o755)

    def calls(self):
        f = self.stub / "calls"
        return f.read_text().splitlines() if f.exists() else []

    def notified(self):
        f = self.stub / "notified"
        return f.read_text().splitlines() if f.exists() else []

    def set_unit(self, name, value):
        (self.stub / f"state-{name}").write_text(value)

    def install_units(self):
        for rel in ("etc/systemd/system/serp-xray.service", "etc/polkit-1/rules.d/49-serpantinum-xray.rules"):
            p = self.etc / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x")

    def __enter__(self):
        env = {
            "XVPN_STATE_DIR": self.state, "XVPN_SECRETS_DIR": self.secrets, "XVPN_DATA_DIR": self.data,
            "XVPN_SETTINGS": self.settings, "XVPN_EVENTS": self.td / "events.jsonl", "XVPN_SYS_NET": self.sysnet,
            "XVPN_SYSTEMCTL": self.stub / "systemctl", "XVPN_XRAY": self.stub / "xray", "XVPN_NOTIFY": self.stub / "notify-send",
            "XVPN_PGREP": self.stub / "pgrep", "XVPN_JOURNALCTL": self.stub / "journalctl",
            "XVPN_RESOLVE_MAP": json.dumps({f"{h}1.example.net": ["192.0.2.%d" % i] for i, h in enumerate(("nl", "de", "fi", "se", "us", "jp"), 1)}), "XVPN_IP": self.stub / "ip",
            "XVPN_ETC_ROOT": self.etc, "XVPN_ALLOW_HTTP": "1", "XVPN_NO_WATCHDOG": "1", "XVPN_NO_UNSHARE": "1",
        }
        for k, v in env.items():
            self.old[k] = os.environ.get(k)
            os.environ[k] = str(v)
        return self

    def __exit__(self, *a):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.td, ignore_errors=True)


class SubServer:
    """Throwaway localhost http.server on a high port: serves a subscription body, headers depend on User-Agent."""

    def __init__(self, routes):
        outer = self
        self.hits = []
        self.routes = routes        # path -> callable(ua) -> (status, headers dict, body bytes)

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.hits.append((self.path, self.headers.get("User-Agent", "")))
                fn = outer.routes.get(self.path.split("?")[0])
                if not fn:
                    self.send_response(404); self.end_headers(); return
                status, hdrs, body = fn(self.headers.get("User-Agent", ""))
                self.send_response(status)
                for k, v in hdrs.items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def url(self, path="/sub/TOKEN"):
        return f"http://127.0.0.1:{self.port}{path}"

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class FakeSocks:
    """SOCKS5 server on localhost that answers HTTP requests with a canned reply (probe/speedtest target)."""

    def __init__(self, reply=b"HTTP/1.1 204 No Content\r\n\r\n", body_bytes=0):
        self.reply, self.body_bytes = reply, body_bytes
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.alive = True
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self.alive:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            c.settimeout(3)
            c.recv(3); c.sendall(b"\x05\x00")
            head = c.recv(4)
            if head[3] == 1:
                c.recv(6)
            elif head[3] == 3:
                n = c.recv(1)[0]; c.recv(n + 2)
            c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            c.recv(1024)
            c.sendall(self.reply)
            if self.body_bytes:
                c.sendall(b"x" * self.body_bytes)
        except OSError:
            pass
        finally:
            c.close()

    def close(self):
        self.alive = False
        try:
            self.sock.shutdown(socket.SHUT_RDWR)      # wakes the blocked accept() so the port really stops answering
        except OSError:
            pass
        self.sock.close()


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)
