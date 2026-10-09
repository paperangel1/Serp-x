"""Node ping ("Incy/Happ style"): latency of EVERY node, whatever its protocol.

Methods (settings.vpn.pingMethod):
  httpGet / httpHead  a real HTTP request to settings.vpn.pingUrl sent THROUGH the node. One short-lived user-level
                      Xray instance (no TUN, no mark) gets one loopback SOCKS inbound per node (random free port,
                      random per-run credentials) routed to that node's own outbound. Latency = time from opening the
                      SOCKS connection until the response (headers; body for GET) is complete. Works for UDP nodes.
                      Tries: one; a second one only after an immediate non-timeout failure, inside the same overall
                      timeout (so a dead node still costs exactly `pingTimeout`). Only 2xx counts as an answer.
  tcp                 TCP handshake to host:port; UDP nodes are "na".
  icmp                system `ping -c1 -W`; UDP nodes are "na"; no reply (blocked) is "timeout".

Result per node: {"ms": int|None, "state": ok|timeout|error|na, "reason": str}. "measuring" is a transient state the
status shows while a run is in flight. The instance is ALWAYS torn down (process group kill + temp dir removal), also
on exceptions, timeouts and SIGTERM. Logs carry method, counts, timings and failure reasons only: never addresses,
URLs or credentials.
"""
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlsplit

from . import core, metrics, paths, resolve
from .xlogshim import log

HTTP_METHODS = ("httpGet", "httpHead")
START_WAIT = 6.0          # seconds the instance may need to open its inbounds
MAX_BODY = 65536
MAX_WORKERS = 32


class MeasureError(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def cache_key(settings):
    """A cached result is reusable only for the same method (and the same URL for the HTTP methods)."""
    m = settings["pingMethod"]
    if m in HTTP_METHODS:
        return m + ":" + hashlib.sha1(settings["pingUrl"].encode()).hexdigest()[:8]
    return m


def _res(ms=None, state="error", reason=""):
    return {"ms": ms, "state": state, "reason": reason}


# ---------------------------------------------------------------- instance config + lifecycle

def reserve_ports(n):
    """n distinct free loopback ports chosen by the OS (all held at once, so they cannot repeat)."""
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind(("127.0.0.1", 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def build_probe_config(nodes, hosts, ports, creds):
    """Config of the measurement instance. nodes: nodes.json entries; hosts: dns.hosts; ports/creds: per node."""
    inbounds, outbounds, rules = [], [], []
    for i, n in enumerate(nodes):
        ob = copy.deepcopy(n["outbound"])
        ob["tag"] = "out%d" % i
        ss = ob.get("streamSettings")
        if isinstance(ss, dict) and isinstance(ss.get("sockopt"), dict):
            ss["sockopt"].pop("mark", None)
            if not ss["sockopt"]:
                ss.pop("sockopt")
        outbounds.append(ob)
        inbounds.append({"tag": "in%d" % i, "listen": "127.0.0.1", "port": ports[i], "protocol": "socks",
                         "settings": {"auth": "password", "udp": False,
                                      "accounts": [{"user": creds[i][0], "pass": creds[i][1]}]}})
        rules.append({"type": "field", "inboundTag": ["in%d" % i], "outboundTag": "out%d" % i})
    cfg = {"log": {"loglevel": "none"}, "inbounds": inbounds, "outbounds": outbounds,
           "routing": {"domainStrategy": "AsIs", "rules": rules}}
    if hosts:
        cfg["dns"] = {"hosts": {d: (v[0] if len(v) == 1 else list(v)) for d, v in hosts.items() if v},
                      "servers": ["localhost"], "queryStrategy": "UseIP"}
    return cfg


class Instance:
    """Context manager around `xray run -c <tmp>`. __exit__ always kills the process group and removes the temp dir."""

    def __init__(self, cfg, ports):
        self.cfg, self.ports = cfg, ports
        self.proc = None
        self.td = None

    def __enter__(self):
        try:
            self._start()
        except BaseException:
            self.stop()
            raise
        return self

    def __exit__(self, *a):
        self.stop()

    def _start(self):
        path = core.xray_path()
        if not os.path.isfile(path):
            raise MeasureError("core_missing")
        self.td = tempfile.mkdtemp(prefix="xvpn-ping-")
        os.chmod(self.td, 0o700)
        f = os.path.join(self.td, "config.json")
        fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(self.cfg, fh)
        try:
            self.proc = subprocess.Popen([path, "run", "-c", f], cwd=self.td, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            raise MeasureError("core_start")
        t0 = time.monotonic()
        while True:
            if self.proc.poll() is not None:
                raise MeasureError("core_exit")
            try:
                socket.create_connection(("127.0.0.1", self.ports[-1]), timeout=0.3).close()
                return
            except OSError:
                pass
            if time.monotonic() - t0 > START_WAIT:
                raise MeasureError("core_start_timeout")
            time.sleep(0.05)

    def stop(self):
        p, self.proc = self.proc, None
        if p is not None:
            for sig, wait in ((signal.SIGTERM, 1.5), (signal.SIGKILL, 3)):
                try:
                    os.killpg(p.pid, sig)
                except (ProcessLookupError, PermissionError):
                    break
                try:
                    p.wait(wait)
                    break
                except subprocess.TimeoutExpired:
                    continue
            try:                                   # group members that outlived the leader
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                p.wait(1)
            except subprocess.TimeoutExpired:
                pass
        td, self.td = self.td, None
        if td:
            shutil.rmtree(td, ignore_errors=True)


# ---------------------------------------------------------------- HTTP through a SOCKS5 inbound

class _Fail(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _recvn(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise _Fail("eof")
        buf += c
    return buf


def http_via_socks(port, user, pw, url, method, deadline, via_host="127.0.0.1"):
    """One request through the SOCKS5 inbound (user/password auth). -> HTTP status. Raises _Fail / socket.timeout."""
    sp = urlsplit(url)
    host, https = sp.hostname, sp.scheme == "https"
    dport = sp.port or (443 if https else 80)
    path = (sp.path or "/") + ("?" + sp.query if sp.query else "")

    def left():
        r = deadline - time.monotonic()
        if r <= 0:
            raise socket.timeout()
        return r
    s = socket.create_connection((via_host, port), timeout=left())
    try:
        s.settimeout(left())
        s.sendall(b"\x05\x01\x02")
        if _recvn(s, 2) != b"\x05\x02":
            raise _Fail("socks")
        u, p = user.encode(), pw.encode()
        s.sendall(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        if _recvn(s, 2) != b"\x01\x00":
            raise _Fail("auth")
        hb = host.encode("idna")
        s.settimeout(left())
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + dport.to_bytes(2, "big"))
        head = _recvn(s, 4)
        if head[1] != 0:
            raise _Fail("socks")
        _recvn(s, {1: 4, 4: 16}.get(head[3]) or (_recvn(s, 1)[0]))
        _recvn(s, 2)
        if https:
            s.settimeout(left())
            try:
                s = ssl.create_default_context().wrap_socket(s, server_hostname=host)
            except ssl.SSLError:
                raise _Fail("tls")
        req = ("%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: serpantinum-ping\r\nAccept: */*\r\nConnection: close\r\n\r\n"
               % ("HEAD" if method == "httpHead" else "GET", path, sp.netloc.rsplit("@", 1)[-1]))
        s.settimeout(left())
        s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            s.settimeout(left())
            c = s.recv(4096)
            if not c:
                break
            buf += c
            if len(buf) > 32768:
                raise _Fail("bad_reply")
        m = re.match(rb"HTTP/\d(?:\.\d)? (\d{3})", buf)
        if not m:
            raise _Fail("bad_reply")
        code = int(m.group(1))
        if method == "httpGet" and b"\r\n\r\n" in buf and code not in (204, 304) and 200 <= code < 300:
            hdr, _, body = buf.partition(b"\r\n\r\n")
            cl = re.search(rb"(?i)\r\ncontent-length:\s*(\d+)", hdr)
            want = min(int(cl.group(1)), MAX_BODY) if cl else MAX_BODY
            while len(body) < want:
                s.settimeout(left())
                c = s.recv(8192)
                if not c:
                    break
                body += c
        return code
    except (ssl.SSLError, ConnectionError):
        raise _Fail("io")
    finally:
        try:
            s.close()
        except OSError:
            pass


def probe_node(port, creds, url, method, timeout):
    """-> result dict. Max `timeout` seconds in total; one retry only after a quick non-timeout failure."""
    t_end = time.monotonic() + timeout
    last = "error"
    for attempt in (1, 2):
        t0 = time.monotonic()
        try:
            code = http_via_socks(port, creds[0], creds[1], url, method, t_end)
        except (socket.timeout, TimeoutError):
            return _res(state="timeout", reason="timeout")
        except _Fail as e:
            last = e.reason
        except OSError:
            last = "io"
        else:
            if 200 <= code < 300:
                return _res(max(1, int((time.monotonic() - t0) * 1000)), "ok")
            return _res(state="error", reason="status")          # a definite answer: no retry
        if time.monotonic() >= t_end - 0.2:
            break
    return _res(state="error", reason=last)


def measure_http(nodes, settings):
    url, method, timeout = settings["pingUrl"], settings["pingMethod"], settings["pingTimeout"]
    out = {}
    doms = {n["id"]: resolve.outbound_domains([n["outbound"]]) for n in nodes}
    alld = list(dict.fromkeys(d for v in doms.values() for d in v))
    boot = resolve.bootstrap(alld, label="ping") if alld else {"hosts": {}, "failed": [], "direct": []}
    run = []
    for n in nodes:
        if any(d in boot["failed"] for d in doms[n["id"]]):
            out[n["id"]] = _res(state="error", reason="dns")
        else:
            run.append(n)
    if not run:
        return out
    ports = reserve_ports(len(run))
    creds = [(secrets.token_hex(8), secrets.token_hex(16)) for _ in run]
    cfg = build_probe_config(run, boot["hosts"], ports, creds)
    old = {}

    def _term(signum, _frm):
        raise SystemExit(128 + signum)
    if threading.current_thread() is threading.main_thread():
        for sg in (signal.SIGTERM, signal.SIGHUP):
            old[sg] = signal.signal(sg, _term)
    t0 = time.monotonic()
    try:
        try:
            with Instance(cfg, ports):
                log.info("probe core up", ms=int((time.monotonic() - t0) * 1000), inbounds=len(run))
                with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(run))) as ex:
                    futs = [(n, ex.submit(probe_node, ports[i], creds[i], url, method, timeout)) for i, n in enumerate(run)]
                    for n, f in futs:
                        try:
                            out[n["id"]] = f.result()
                        except Exception:                               # one broken probe must not lose the others
                            out[n["id"]] = _res(state="error", reason="internal")
        except MeasureError as e:
            log.warn("probe core failed", reason=e.reason)
            for n in run:
                out[n["id"]] = _res(state="error", reason=e.reason)
    finally:
        for sg, h in old.items():
            signal.signal(sg, h)
    return out


# ---------------------------------------------------------------- tcp / icmp

def _resolved(nodes):
    return resolve.system_many([h for h in dict.fromkeys(n["address"] for n in nodes if not n.get("udp"))
                                if not resolve.is_ip(h)])


def measure_tcp(nodes, settings):
    known = _resolved(nodes)

    def probe(host, port, timeout):
        if host in known:
            host = known[host][0]
        elif not resolve.is_ip(host):
            return None, "noreply"
        return metrics.tcp_probe(host, port, timeout)
    res = metrics.ping_nodes(nodes, probe=probe, timeout=settings["pingTimeout"])
    return {nid: _res(v["ms"], {"udp": "na", "noreply": "error"}.get(v["state"], v["state"]),
                      {"udp": "udp", "noreply": "noreply"}.get(v["state"], "")) for nid, v in res.items()}


def ping_bin():
    return os.environ.get("XVPN_PING") or shutil.which("ping")


def icmp_probe(ip, timeout):
    b = ping_bin()
    if not b:
        return _res(state="na", reason="no_ping_binary")
    try:
        r = subprocess.run([b, "-c", "1", "-W", str(int(timeout)), ip], capture_output=True, text=True, timeout=timeout + 2)
    except (OSError, subprocess.SubprocessError):
        return _res(state="timeout", reason="timeout")
    m = re.search(r"time[=<]\s*([\d.]+)\s*ms", r.stdout or "")
    if r.returncode == 0 and m:
        return _res(max(1, int(round(float(m.group(1))))), "ok")
    return _res(state="timeout", reason="timeout")


def measure_icmp(nodes, settings):
    out, todo = {}, []
    for n in nodes:
        if n.get("udp"):
            out[n["id"]] = _res(state="na", reason="udp")
        else:
            todo.append(n)
    known = _resolved(todo)

    def one(n):
        h = n["address"]
        ip = h if resolve.is_ip(h) else (known.get(h) or [None])[0]
        return n["id"], (icmp_probe(ip, settings["pingTimeout"]) if ip else _res(state="error", reason="dns"))
    if todo:
        with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(todo))) as ex:
            out.update(dict(ex.map(one, todo)))
    return out


def measure(nodes, settings):
    """-> {node id: {"ms", "state", "reason"}} for the configured method."""
    m = settings["pingMethod"]
    if not nodes:
        return {}
    if m in HTTP_METHODS:
        return measure_http(nodes, settings)
    return (measure_icmp if m == "icmp" else measure_tcp)(nodes, settings)


# ---------------------------------------------------------------- doctor

def selfcheck():
    """Dry check, no network: xray exists and a loopback port can be bound. -> (ok, text)."""
    caps = core.capabilities()
    if not caps["exists"]:
        return False, "Замер пинга: не найден xray"
    try:
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", 0))
        finally:
            s.close()
    except OSError:
        return False, "Замер пинга: нельзя открыть локальный порт"
    return True, "Замер пинга работает (xray найден, локальные порты доступны)"
