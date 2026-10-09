"""Connectivity probe, node ping and throughput. Only the paths are implemented here; they are
exercised in tests against local fake servers, never against real nodes.
"""
import socket
import ssl
import struct
import time
from concurrent.futures import ThreadPoolExecutor

from . import paths

PROBES = [("1.1.1.1", 80, "1.1.1.1"), ("connectivitycheck.gstatic.com", 80, "connectivitycheck.gstatic.com")]


def socks_connect(via_port, host, port, timeout=5, via_host="127.0.0.1"):
    """Minimal SOCKS5 CONNECT (no auth). -> connected socket. Raises OSError on failure."""
    s = socket.create_connection((via_host, via_port), timeout=timeout)
    try:
        s.settimeout(timeout)
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise OSError("socks: no-auth refused")
        try:
            addr = socket.inet_aton(host)
            req = b"\x05\x01\x00\x01" + addr
        except OSError:
            hb = host.encode("idna")
            req = b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb
        s.sendall(req + struct.pack(">H", port))
        head = s.recv(4)
        if len(head) < 4 or head[1] != 0:
            raise OSError("socks: connect failed")
        n = {1: 4, 4: 16}.get(head[3])
        if n is None:                                    # domain
            n = s.recv(1)[0]
        s.recv(n + 2)
        return s
    except BaseException:
        s.close()
        raise


def probe_via_socks(port, targets=None, timeout=4, via_host="127.0.0.1"):
    """True when an HTTP exchange completes through the proxy (connect-success alone proves nothing:
    xray answers the SOCKS CONNECT before dialling)."""
    for host, p, hdr in (targets or PROBES):
        try:
            s = socks_connect(port, host, p, timeout, via_host)
            try:
                s.sendall(f"HEAD / HTTP/1.1\r\nHost: {hdr}\r\nConnection: close\r\n\r\n".encode())
                if s.recv(16).startswith(b"HTTP/"):
                    return True
            finally:
                s.close()
        except OSError:
            continue
    return False


def tcp_probe(host, port, timeout=3):
    """-> (ms, None) on success, else (None, "timeout" | "noreply"). noreply = refused / unreachable / DNS failure."""
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
    except (socket.timeout, TimeoutError):
        return None, "timeout"
    except OSError:
        return None, "noreply"
    return max(1, int((time.monotonic() - t0) * 1000)), None


def tcp_ping(host, port, timeout=3):
    """Milliseconds for a TCP handshake, or None."""
    return tcp_probe(host, port, timeout)[0]


def ping_nodes(nodes, probe=tcp_probe, timeout=3, workers=16):
    """nodes: nodes.json entries -> {id: {"ms": int|None, "state": "ok"|"timeout"|"noreply"|"udp"}}.
    TCP handshakes run in parallel (a dead node costs `timeout`, not N x timeout). UDP-based nodes
    (hysteria2) cannot be probed by TCP: state "udp" = not measured, NOT a failure."""
    res = {}
    todo = []
    for n in nodes:
        if n.get("udp"):
            res[n["id"]] = {"ms": None, "state": "udp"}
        else:
            todo.append(n)

    def one(n):
        try:
            r = probe(n["address"], int(n["port"]), timeout)
        except (OSError, ValueError, KeyError):
            r = (None, "noreply")
        if not isinstance(r, tuple):                    # a plain-ms probe
            r = (r, None if r else "timeout")
        return n["id"], ({"ms": r[0], "state": "ok"} if r[0] else {"ms": None, "state": r[1] or "timeout"})

    if todo:
        with ThreadPoolExecutor(max_workers=min(workers, len(todo))) as ex:
            for nid, v in ex.map(one, todo):
                res[nid] = v
    return res


def download_mbps(via_port, url_host="speed.cloudflare.com", path="/__down?bytes=50000000", seconds=5,
                  port=443, use_tls=True, via_host="127.0.0.1"):
    """Throughput through the proxy in Mbit/s (rough: bytes received in `seconds`)."""
    s = socks_connect(via_port, url_host, port, 8, via_host)
    try:
        if use_tls:
            s = ssl.create_default_context().wrap_socket(s, server_hostname=url_host)
        s.settimeout(5)
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: {url_host}\r\nConnection: close\r\n\r\n".encode())
        got, t0 = 0, time.monotonic()
        while time.monotonic() - t0 < seconds:
            try:
                chunk = s.recv(65536)
            except (socket.timeout, TimeoutError):
                break
            if not chunk:
                break
            got += len(chunk)
        dt = max(time.monotonic() - t0, 0.001)
        return round(got * 8 / dt / 1e6, 1)
    finally:
        s.close()


def load_cache():
    return paths.read_json(paths.state_dir() / "metrics.json", {}) or {}


def save_cache(cache):
    paths.write_json(paths.state_dir() / "metrics.json", cache, 0o600)
