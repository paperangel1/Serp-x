"""Bootstrap resolution of the proxy server's own name, done BEFORE the core starts (TUN is not up yet).

Why: xray must resolve the outbound `address` to dial the node. Its DNS is DoH, and the DoH requests are routed
through that very outbound -> deadlock. So the names are resolved here (system resolver, then plain UDP DNS via
the direct resolver) and handed to xray as `dns.hosts`. Only counts and node names are ever logged.
"""
import json
import os
import random
import socket
import struct
import threading
import time

from .xlogshim import log

TIMEOUT = 3.0
DIRECT_DNS = "77.88.8.8"
_SKIP_PROTOCOLS = ("freedom", "blackhole", "dns")


def _fake():
    raw = os.environ.get("XVPN_RESOLVE_MAP")
    return json.loads(raw) if raw else None


def is_ip(host):
    for fam in (socket.AF_INET, socket.AF_INET6):
        try:
            socket.inet_pton(fam, host.strip("[]"))
            return True
        except (OSError, ValueError):
            pass
    return False


def _sort(ips):
    """IPv4 first, order kept, no duplicates."""
    v4 = [i for i in ips if ":" not in i]
    v6 = [i for i in ips if ":" in i]
    return list(dict.fromkeys(v4 + v6))


def _call_with_timeout(fn, timeout):
    box = {}

    def run():
        try:
            box["v"] = fn()
        except Exception:
            box["v"] = []
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    return box.get("v") or []


def system_lookup(host):
    """Replaceable in tests. -> list of IP strings (system resolver)."""
    fake = _fake()
    if fake is not None:
        v = fake.get(host, "fail")
        if v == "timeout":
            time.sleep(3600)
        return list(v) if isinstance(v, list) else []
    try:
        return [sa[0] for _f, _t, _p, _c, sa in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
                if _f in (socket.AF_INET, socket.AF_INET6)]
    except OSError:
        return []


def _dns_query(host, qtype, server, timeout, port=53):
    qid = random.randrange(65536)
    q = b"".join(bytes([len(p)]) + p.encode("idna") for p in host.strip(".").split(".")) + b"\x00"
    pkt = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.settimeout(timeout)
        s.sendto(pkt, (server, port))
        data, _ = s.recvfrom(1500)
    finally:
        s.close()
    if len(data) < 12 or struct.unpack(">H", data[:2])[0] != qid:
        return []
    an = struct.unpack(">H", data[6:8])[0]

    def skip_name(p):
        while data[p] != 0:
            if data[p] & 0xC0 == 0xC0:
                return p + 2
            p += data[p] + 1
        return p + 1
    pos = skip_name(12) + 4
    out = []
    for _ in range(an):
        pos = skip_name(pos)
        rtype, _c, _ttl, rl = struct.unpack(">HHIH", data[pos:pos + 10])
        pos += 10
        rd = data[pos:pos + rl]
        pos += rl
        if rtype == 1 and rl == 4:
            out.append(socket.inet_ntoa(rd))
        elif rtype == 28 and rl == 16:
            out.append(socket.inet_ntop(socket.AF_INET6, rd))
    return out


def direct_lookup(host, server=DIRECT_DNS, timeout=TIMEOUT):
    """Replaceable in tests. Plain UDP DNS to the direct resolver: A, then AAAA when no A."""
    fake = _fake()
    if fake is not None:
        v = fake.get("direct:" + host, "fail")
        return list(v) if isinstance(v, list) else []
    for qt in (1, 28):
        try:
            r = _dns_query(host, qt, server, timeout)
        except (OSError, IndexError, struct.error, UnicodeError):
            r = []
        if r:
            return r
    return []


def outbound_domains(cfg_or_outbounds):
    """Non-IP server names of the proxy outbounds (vnext/servers/settings.address, wireguard endpoints)."""
    obs = cfg_or_outbounds.get("outbounds", []) if isinstance(cfg_or_outbounds, dict) else cfg_or_outbounds
    found = []

    def walk(n):
        if isinstance(n, dict):
            for k, v in n.items():
                if k == "address" and isinstance(v, str):
                    found.append(v)
                elif k == "endpoint" and isinstance(v, str):
                    found.append(v.rsplit(":", 1)[0] if v.count(":") == 1 else v)
                else:
                    walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    for ob in obs or []:
        if ob.get("protocol") not in _SKIP_PROTOCOLS:
            walk(ob.get("settings") or {})
    return list(dict.fromkeys(h.strip().lower() for h in found if h and not is_ip(h)))


def bootstrap(domains, timeout=TIMEOUT, label=""):
    """-> {"hosts": {domain: [ip,...]}, "direct": [domains resolved only by the direct DNS], "failed": [domains]}.
    Names are resolved in parallel; a hanging resolver costs `timeout`, not N x timeout."""
    t0 = time.monotonic()
    res, lock = {}, threading.Lock()

    def one(d):
        ips = _call_with_timeout(lambda: system_lookup(d), timeout)
        via = "system"
        if not ips:
            ips = _call_with_timeout(lambda: direct_lookup(d, timeout=timeout), timeout + 0.5)
            via = "direct"
        with lock:
            res[d] = (_sort(ips)[:4], via)
    ths = [threading.Thread(target=one, args=(d,), daemon=True) for d in domains]
    for t in ths:
        t.start()
    for t in ths:
        t.join(timeout * 2 + 1)
    out = {"hosts": {}, "direct": [], "failed": []}
    for d in domains:
        ips, via = res.get(d, ([], "none"))
        if ips:
            out["hosts"][d] = ips
            if via == "direct":
                out["direct"].append(d)
        else:
            out["failed"].append(d)
    log.info("server name resolution", node=label or None, names=len(domains), ok=len(out["hosts"]),
             via_direct=len(out["direct"]), failed=len(out["failed"]), ms=int((time.monotonic() - t0) * 1000))
    return out


def server_ips(boot):
    return list(dict.fromkeys(ip for v in boot["hosts"].values() for ip in v))


def system_many(domains, timeout=TIMEOUT):
    """System resolver only, in parallel -> {domain: [ips]} (failures omitted)."""
    res = {}

    def one(d):
        res[d] = _sort(_call_with_timeout(lambda: system_lookup(d), timeout))
    ths = [threading.Thread(target=one, args=(d,), daemon=True) for d in domains]
    for t in ths:
        t.start()
    for t in ths:
        t.join(timeout + 1)
    return {d: v for d, v in res.items() if v}


def all_nodes_net(nodes, boot=None, timeout=TIMEOUT, cap=256):
    """Network identity of EVERY subscription node -> {"hosts": {domain: [ips]}, "ips": [ips]}.
    Names already resolved by `boot` are reused; the rest go through the system resolver in parallel (a hanging
    resolver costs `timeout`, not N x timeout). Names that do not resolve are simply absent. Counts only are logged."""
    nodes = list(nodes)[:cap]
    have = dict((boot or {}).get("hosts") or {})
    addrs = list(dict.fromkeys((n.get("address") or "").strip().lower() for n in nodes))
    literal = [a.strip("[]") for a in addrs if a and is_ip(a)]
    names = [a for a in addrs if a and not is_ip(a)]
    t0 = time.monotonic()
    got = dict(have)
    got.update(system_many([d for d in names if d not in have], timeout))
    hosts = {d: got[d] for d in names if d in got}
    ips = list(dict.fromkeys(literal + [ip for v in hosts.values() for ip in v]))[:cap * 4]
    log.info("all nodes resolved", nodes=len(nodes), names=len(names), ok=len(hosts), ips=len(ips),
             ms=int((time.monotonic() - t0) * 1000))
    return {"hosts": hosts, "ips": ips}
