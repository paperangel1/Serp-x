"""Xray config generator + the guards that keep root-side use safe.

The generated config (with the tun inbound) is only ever started by the root service.
Everything that runs on the user's machine for validation uses `test_variant()`, i.e. the same config
WITHOUT inbounds, so `xray run -test` cannot open a device or a socket.
"""
import copy
import json

from . import paths

PRIVATE_V4 = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10"]
PRIVATE_V6 = ["fc00::/7", "fe80::/10", "::1/128"]
RU_SUFFIXES = ["domain:ru", "domain:su", "domain:xn--p1ai"]          # .ru .su .рф
RU_GEOSITE = ["geosite:category-ru", "geosite:ru-available-only-inside"]
RU_GEOIP = ["geoip:ru"]

SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"], "routeOnly": True}


def _with_mark(outbound):
    ob = copy.deepcopy(outbound)
    ss = ob.setdefault("streamSettings", {})
    ss.setdefault("sockopt", {})["mark"] = paths.MARK
    return ob


def build_config(node, settings, sub_rules=None, geo_present=False, with_inbounds=True, boot=None, all_nodes=None):
    """-> xray config dict for `node` (a nodes.json entry) honouring settings (mode, user domain lists).

    boot = resolve.bootstrap() result: the server's own name is pinned in `dns.hosts` (xray must never need DNS
    to reach its server: the DoH servers are themselves routed through that server), the resolved IPs go direct,
    and names that only the direct resolver could answer also get a first, direct DNS server entry.

    all_nodes = {"hosts": {domain: [ip,...]}, "ips": [ip,...]} for EVERY subscription node (resolve.all_nodes_net):
    their IPs join the same "ip -> direct" rule and their names join dns.hosts, so a short-lived measurement
    instance dialling any node reaches it directly even while this tunnel is up (no hairpin through the tunnel)."""
    boot = boot or {}
    all_nodes = all_nodes or {}
    hosts = {d: (v[0] if len(v) == 1 else list(v)) for d, v in (all_nodes.get("hosts") or {}).items() if v}
    hosts.update({d: (v[0] if len(v) == 1 else list(v)) for d, v in (boot.get("hosts") or {}).items() if v})
    srv_ips = list(dict.fromkeys([ip for v in (boot.get("hosts") or {}).values() for ip in v] + list(all_nodes.get("ips") or [])))
    mode = settings.get("mode", "ru-direct")
    bypass = [d for d in settings.get("bypassDomains", []) if isinstance(d, str) and d.strip()]
    via_vpn = [d for d in settings.get("proxyDomains", []) if isinstance(d, str) and d.strip()]
    port = int(settings.get("socksPort", paths.DEFAULT_SETTINGS["socksPort"]))

    dns_direct = [ip for ip in settings.get("dnsDirect", []) if isinstance(ip, str) and ip.strip()] or ["77.88.8.8"]
    rules = []
    # Queries of xray's own DNS module towards the direct resolvers must leave on the physical link (marked
    # socket) -- NOT through the tunnel, otherwise they would loop. Matched by destination IP: no reliance on tags.
    rules.append({"type": "field", "ip": list(dns_direct), "outboundTag": "direct"})
    if srv_ips:                                         # the node itself is never routed into the tunnel
        rules.append({"type": "field", "ip": srv_ips, "outboundTag": "direct"})
    rules.append({"type": "field", "inboundTag": ["tun-in", "socks-in"], "network": "udp", "port": "53", "outboundTag": "dns-out"})
    rules.append({"type": "field", "ip": PRIVATE_V4 + PRIVATE_V6, "outboundTag": "direct"})
    if bypass:
        rules.append({"type": "field", "domain": [_dom(d) for d in bypass], "outboundTag": "direct"})
    if via_vpn:
        rules.append({"type": "field", "domain": [_dom(d) for d in via_vpn], "outboundTag": "proxy"})
    for r in (sub_rules or []):
        rules.append(r)
    ru_domains = list(RU_SUFFIXES) + (RU_GEOSITE if geo_present else [])
    if mode == "ru-direct":
        rules.append({"type": "field", "domain": list(ru_domains), "outboundTag": "direct"})
        if geo_present:
            rules.append({"type": "field", "ip": list(RU_GEOIP), "outboundTag": "direct"})
    final = "direct" if mode == "direct" else "proxy"
    rules.append({"type": "field", "network": "tcp,udp", "outboundTag": final})

    dns_servers = [{"address": dns_direct[0], "domains": ["full:" + d], "skipFallback": True}
                   for d in boot.get("direct", [])]
    if mode == "ru-direct":
        for ip in dns_direct:
            dns_servers.append({"address": ip, "domains": list(ru_domains), "skipFallback": True})
    if mode == "direct":
        dns_servers.extend(dns_direct)
    else:
        dns_servers.extend(["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"])

    cfg = {
        "log": {"loglevel": "warning"},
        "dns": {"servers": dns_servers, "queryStrategy": "UseIP"},
        "inbounds": [],
        "outbounds": [
            _with_mark(node["outbound"]),
            {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIP"},
             "streamSettings": {"sockopt": {"mark": paths.MARK}}},
            {"tag": "block", "protocol": "blackhole"},
            {"tag": "dns-out", "protocol": "dns", "streamSettings": {"sockopt": {"mark": paths.MARK}}},
        ],
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules},
    }
    if hosts:
        cfg["dns"]["hosts"] = hosts
    if with_inbounds:
        cfg["inbounds"] = [
            {"tag": "tun-in", "protocol": "tun", "settings": {"name": paths.TUN_NAME, "MTU": 1500, "userLevel": 0},
             "sniffing": dict(SNIFF)},
            {"tag": "socks-in", "listen": "127.0.0.1", "port": port, "protocol": "socks",
             "settings": {"udp": True, "auth": "noauth"}, "sniffing": dict(SNIFF)},
        ]
    return cfg


def _dom(d):
    d = d.strip()
    if ":" in d.split(".")[0]:           # already has a matcher prefix (domain:, full:, regexp:, geosite:)
        return d
    return "domain:" + d.lstrip(".")


def test_variant(cfg):
    """Copy of the config without any inbound: safe to feed to `xray run -test`."""
    c = copy.deepcopy(cfg)
    c["inbounds"] = []
    return c


# ---------------------------------------------------------------- root-side allowlist

ALLOWED_TOP = {"log", "dns", "inbounds", "outbounds", "routing"}
ALLOWED_INBOUND_PROTOCOLS = {"tun", "socks"}


class ConfigRejected(ValueError):
    pass


_FILE_KEYS = {"certificateFile", "keyFile", "file", "ca", "caFile"}


def _walk(node, key=""):
    """Reject anything that makes root xray touch the filesystem or a unix socket."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in _FILE_KEYS:
                raise ConfigRejected("file reference not allowed: " + k)
            _walk(v, k)
    elif isinstance(node, list):
        for v in node:
            _walk(v, key)
    elif isinstance(node, str):
        if "\x00" in node:
            raise ConfigRejected("NUL in config")
        if key in ("address", "listen") and (node.startswith(("/", "@", "unix:", "file:"))):
            raise ConfigRejected("unix socket / file address not allowed")


def check_root_safe(cfg, expect_tun=paths.TUN_NAME):
    """Allowlist applied by the root helper before a user-writable config is started as root.

    Xray can write files (log paths), listen on any address and so on; a root service must not trust
    the contents of a file the user can edit. Raises ConfigRejected on anything unexpected.
    """
    if not isinstance(cfg, dict):
        raise ConfigRejected("config is not an object")
    extra = set(cfg) - ALLOWED_TOP
    if extra:
        raise ConfigRejected("unexpected top-level keys: " + ",".join(sorted(extra)))
    log = cfg.get("log") or {}
    if any(k in log for k in ("access", "error")) and (log.get("access") not in (None, "", "none") or log.get("error") not in (None, "", "none")):
        raise ConfigRejected("log files are not allowed")
    for ib in cfg.get("inbounds") or []:
        proto = ib.get("protocol")
        if proto not in ALLOWED_INBOUND_PROTOCOLS:
            raise ConfigRejected("inbound protocol not allowed: " + str(proto))
        if proto == "socks" and ib.get("listen") != "127.0.0.1":
            raise ConfigRejected("socks inbound must listen on 127.0.0.1")
        if proto == "tun" and (ib.get("settings") or {}).get("name") != expect_tun:
            raise ConfigRejected("tun name mismatch")
    _walk(cfg)
    for ob in cfg.get("outbounds") or []:
        if ob.get("protocol") not in ("vless", "vmess", "trojan", "shadowsocks", "hysteria", "wireguard", "freedom", "blackhole", "dns", "socks", "http"):
            raise ConfigRejected("outbound protocol not allowed: " + str(ob.get("protocol")))
    return True
