"""Subscription bodies -> nodes (Xray outbounds).

Supported: vless / ss (SIP002 + legacy) / trojan / hysteria2 links (plain list or base64), and the
Xray-JSON subscription format (a JSON array of full configs, one per node, with `remarks`).
Links contain credentials: nothing here logs or prints them.
"""
import base64
import binascii
import hashlib
import json
import re
from urllib.parse import parse_qs, unquote, urlsplit

from . import flags


class LinkError(ValueError):
    pass


def _b64(s):
    s = s.strip().replace("-", "+").replace("_", "/")
    s += "=" * (-len(s) % 4)
    try:
        return base64.b64decode(s, validate=False)
    except (binascii.Error, ValueError) as e:
        raise LinkError("bad base64") from e


def _q(qs, key, default=""):
    v = qs.get(key)
    return v[0] if v else default


def _port(sp):
    try:
        p = sp.port
    except ValueError as e:
        raise LinkError("bad port") from e
    if not p:
        raise LinkError("no port")
    return p


def node_id(protocol, address, port, secret):
    """Stable id that does not expose the credential."""
    h = hashlib.sha1(f"{protocol}|{address}|{port}|{secret}".encode("utf-8")).hexdigest()
    return h[:10]


def _make_node(protocol, name, address, port, outbound, secret, udp=False, extra=None):
    flag, cc, label = flags.split_name(name)
    return {
        "id": node_id(protocol, address, port, secret),
        "name": label or f"{address}:{port}",
        "rawName": name,
        "flag": flag,
        "cc": cc,
        "protocol": protocol,
        "address": address,
        "port": port,
        "udp": udp,
        "extra": extra or {},
        "outbound": outbound,
    }


def _stream(qs, default_security="none"):
    """Query parameters of vless/trojan links -> Xray streamSettings."""
    net = _q(qs, "type", "tcp").lower()
    net = {"raw": "tcp", "splithttp": "xhttp", "http": "h2"}.get(net, net)
    if net not in ("tcp", "ws", "grpc", "httpupgrade", "xhttp", "kcp"):
        raise LinkError("unsupported transport " + net)
    sec = _q(qs, "security", default_security).lower()
    if sec not in ("none", "tls", "reality"):
        raise LinkError("unsupported security " + sec)
    ss = {"network": net, "security": sec}
    path = unquote(_q(qs, "path"))
    host = _q(qs, "host")
    if net == "ws":
        ss["wsSettings"] = {"path": path or "/", **({"headers": {"Host": host}} if host else {})}
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {"path": path or "/", **({"host": host} if host else {})}
    elif net == "xhttp":
        x = {"path": path or "/"}
        if host:
            x["host"] = host
        if _q(qs, "mode"):
            x["mode"] = _q(qs, "mode")
        ss["xhttpSettings"] = x
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": unquote(_q(qs, "serviceName")), "multiMode": _q(qs, "mode") == "multi"}
    elif net == "tcp" and _q(qs, "headerType") == "http":
        ss["tcpSettings"] = {"header": {"type": "http", "request": {"path": [path or "/"], "headers": {"Host": [host] if host else []}}}}
    elif net == "kcp":
        ss["kcpSettings"] = {"header": {"type": _q(qs, "headerType", "none")}, **({"seed": _q(qs, "seed")} if _q(qs, "seed") else {})}
    sni = _q(qs, "sni") or _q(qs, "peer") or host
    if sec == "tls":
        t = {}
        if sni:
            t["serverName"] = sni
        if _q(qs, "fp"):
            t["fingerprint"] = _q(qs, "fp")
        if _q(qs, "alpn"):
            t["alpn"] = [a for a in unquote(_q(qs, "alpn")).split(",") if a]
        if _q(qs, "allowInsecure") in ("1", "true") or _q(qs, "insecure") in ("1", "true"):
            t["allowInsecure"] = True
        ss["tlsSettings"] = t
    elif sec == "reality":
        if not _q(qs, "pbk"):
            raise LinkError("reality without public key")
        r = {"serverName": sni, "fingerprint": _q(qs, "fp", "chrome"), "publicKey": _q(qs, "pbk"),
             "shortId": _q(qs, "sid"), "spiderX": unquote(_q(qs, "spx"))}
        ss["realitySettings"] = r
    return ss


def parse_vless(link):
    sp = urlsplit(link)
    uid = unquote(sp.username or "")
    if not uid or not sp.hostname:
        raise LinkError("vless: no id/host")
    qs = parse_qs(sp.query, keep_blank_values=True)
    enc = _q(qs, "encryption", "none") or "none"
    user = {"id": uid, "encryption": enc}
    if _q(qs, "flow"):
        user["flow"] = _q(qs, "flow")
    ob = {"tag": "proxy", "protocol": "vless",
          "settings": {"vnext": [{"address": sp.hostname, "port": _port(sp), "users": [user]}]},
          "streamSettings": _stream(qs)}
    return _make_node("vless", unquote(sp.fragment), sp.hostname, _port(sp), ob, uid,
                      extra={"security": ob["streamSettings"]["security"], "network": ob["streamSettings"]["network"]})


def parse_trojan(link):
    sp = urlsplit(link)
    pw = unquote(sp.username or "")
    if not pw or not sp.hostname:
        raise LinkError("trojan: no password/host")
    qs = parse_qs(sp.query, keep_blank_values=True)
    ob = {"tag": "proxy", "protocol": "trojan",
          "settings": {"servers": [{"address": sp.hostname, "port": _port(sp), "password": pw}]},
          "streamSettings": _stream(qs, "tls")}
    return _make_node("trojan", unquote(sp.fragment), sp.hostname, _port(sp), ob, pw,
                      extra={"security": ob["streamSettings"]["security"], "network": ob["streamSettings"]["network"]})


def parse_ss(link):
    rest = link[len("ss://"):]
    frag = ""
    if "#" in rest:
        rest, frag = rest.split("#", 1)
    name = unquote(frag)
    query = ""
    if "?" in rest:
        rest, query = rest.split("?", 1)
    qs = parse_qs(query)
    if qs.get("plugin"):
        raise LinkError("ss plugin is not supported")
    if "@" in rest:                       # SIP002: userinfo@host:port, userinfo base64 or percent-encoded plain
        userinfo, hostport = rest.rsplit("@", 1)
        ui = unquote(userinfo)
        if ":" not in ui:
            ui = _b64(ui).decode("utf-8", "replace")
    else:                                  # legacy: base64(method:password@host:port)
        decoded = _b64(rest).decode("utf-8", "replace")
        if "@" not in decoded:
            raise LinkError("ss: bad legacy form")
        ui, hostport = decoded.rsplit("@", 1)
    if ":" not in ui:
        raise LinkError("ss: no method/password")
    method, password = ui.split(":", 1)
    hostport = hostport.rstrip("/")
    m = re.match(r"^\[?([^\]]+?)\]?:(\d+)$", hostport)
    if not m:
        raise LinkError("ss: bad host:port")
    host, port = m.group(1), int(m.group(2))
    ob = {"tag": "proxy", "protocol": "shadowsocks",
          "settings": {"servers": [{"address": host, "port": port, "method": method, "password": password}]}}
    return _make_node("ss", name, host, port, ob, password, extra={"method": method})


def parse_hysteria2(link):
    link = re.sub(r"^hy2://", "hysteria2://", link)
    sp = urlsplit(link)
    auth = unquote(sp.username or "")
    if sp.password:
        auth = auth + ":" + unquote(sp.password)
    if not auth or not sp.hostname:
        raise LinkError("hysteria2: no auth/host")
    qs = parse_qs(sp.query, keep_blank_values=True)
    port = _port(sp)
    tls = {"alpn": ["h3"]}
    sni = _q(qs, "sni") or sp.hostname
    tls["serverName"] = sni
    if _q(qs, "insecure") in ("1", "true"):
        tls["allowInsecure"] = True
    if _q(qs, "pinSHA256"):
        tls["pinnedPeerCertificateSha256"] = [_q(qs, "pinSHA256").replace(":", "").lower()]
    ss = {"network": "hysteria", "security": "tls", "tlsSettings": tls,
          "hysteriaSettings": {"version": 2, "auth": auth}}
    if _q(qs, "obfs") == "salamander" and _q(qs, "obfs-password"):
        ss["finalmask"] = {"udp": [{"type": "salamander", "settings": {"password": _q(qs, "obfs-password")}}]}
    ob = {"tag": "proxy", "protocol": "hysteria",
          "settings": {"version": 2, "address": sp.hostname, "port": port},
          "streamSettings": ss}
    return _make_node("hysteria2", unquote(sp.fragment), sp.hostname, port, ob, auth, udp=True,
                      extra={"obfs": _q(qs, "obfs") or ""})


_PARSERS = {"vless": parse_vless, "ss": parse_ss, "trojan": parse_trojan,
            "hysteria2": parse_hysteria2, "hy2": parse_hysteria2}


def parse_link(link):
    link = link.strip()
    scheme = link.split("://", 1)[0].lower() if "://" in link else ""
    fn = _PARSERS.get(scheme)
    if not fn:
        raise LinkError("unsupported scheme")
    return fn(link)


# ---------------------------------------------------------------- Xray JSON subscription

_PROXY_PROTOCOLS = ("vless", "vmess", "trojan", "shadowsocks", "hysteria", "wireguard", "socks", "http")
_ROUTING_FIELDS = ("domain", "ip", "port", "network", "protocol")


def _outbound_identity(ob):
    s = ob.get("settings") or {}
    try:
        if "vnext" in s:
            v = s["vnext"][0]
            return v["address"], int(v["port"]), v["users"][0].get("id", "")
        if "servers" in s:
            v = s["servers"][0]
            return v["address"], int(v["port"]), v.get("password", "")
        if "address" in s:
            return s["address"], int(s.get("port", 0)), s.get("id", "") or s.get("password", "")
    except (KeyError, IndexError, TypeError, ValueError):
        pass
    return "", 0, ""


def parse_json_subscription(doc):
    """Xray-JSON subscription -> (nodes, routing_rules). Rules come from the first config that has any."""
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list):
        raise LinkError("json subscription: not a list")
    nodes, skipped, rules = [], 0, []
    for cfg in doc:
        if not isinstance(cfg, dict):
            skipped += 1
            continue
        obs = [o for o in (cfg.get("outbounds") or []) if isinstance(o, dict)]
        main = next((o for o in obs if o.get("tag") == "proxy"), None) \
            or next((o for o in obs if o.get("protocol") in _PROXY_PROTOCOLS), None)
        if not main:
            skipped += 1
            continue
        main = json.loads(json.dumps(main))
        main["tag"] = "proxy"
        addr, port, secret = _outbound_identity(main)
        remarks = str(cfg.get("remarks") or cfg.get("ps") or f"{addr}:{port}")
        proto = main.get("protocol", "")
        nodes.append(_make_node({"hysteria": "hysteria2", "shadowsocks": "ss"}.get(proto, proto), remarks, addr, port, main, secret,
                                udp=proto in ("hysteria", "wireguard"),
                                extra={"network": (main.get("streamSettings") or {}).get("network", ""),
                                       "security": (main.get("streamSettings") or {}).get("security", "")}))
        if not rules:
            for r in ((cfg.get("routing") or {}).get("rules") or []):
                rr = sanitize_rule(r)
                if rr:
                    rules.append(rr)
    return nodes, rules, skipped


def sanitize_rule(rule):
    """Keep only plain matcher fields and the outbound tags we know; anything else is dropped."""
    if not isinstance(rule, dict):
        return None
    tag = rule.get("outboundTag")
    if tag not in ("proxy", "direct", "block"):
        return None
    out = {"type": "field", "outboundTag": tag}
    for k in _ROUTING_FIELDS:
        v = rule.get(k)
        if isinstance(v, (list, str)) and v:
            out[k] = v
    return out if len(out) > 2 else None


# ---------------------------------------------------------------- bodies

def looks_like_json(body):
    b = body.lstrip()
    return b[:1] in ("[", "{")


def parse_subscription_text(body, fmt="auto"):
    """-> {"kind": "links"|"json", "nodes": [...], "rules": [...], "skipped": [reasons]} ; never raises on junk lines."""
    body = body.strip()
    if not body:
        raise LinkError("empty subscription")
    if fmt != "links" and looks_like_json(body):
        try:
            doc = json.loads(body)
        except ValueError as e:
            raise LinkError("invalid json") from e
        nodes, rules, skipped = parse_json_subscription(doc)
        nodes, info = split_placeholders(_dedupe(nodes), _log())
        return {"kind": "json", "nodes": nodes, "rules": rules, "skipped": ["json-entry"] * skipped, "info": info}
    text = body
    if "://" not in text.splitlines()[0]:
        try:
            text = _b64(body).decode("utf-8", "replace")
        except LinkError:
            text = body
    nodes, skipped = [], []
    for line in text.replace("\r", "").split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or "://" not in line:
            continue
        try:
            nodes.append(parse_link(line))
        except LinkError as e:
            skipped.append(str(e))
    nodes, info = split_placeholders(_dedupe(nodes), _log())
    return {"kind": "links", "nodes": nodes, "rules": [], "skipped": skipped, "info": info}


def _log():
    from .xlogshim import log
    return log


# ---------------------------------------------------------------- informational entries and tags

_INFO_NAME = re.compile(
    r"осталось|остаток|остал\w*\s+дн|дн(ей|я|ь)\s+осталось|days?\s+(left|remaining)|remaining|expir|истека|истёк|закончи\w*\s+подписк|"
    r"подписк\w*\s+(закончи|истек|истёк)|трафик|traffic|bandwidth|\bsupport\b|поддержк|\bt\.me/|telegram|обновите\s+подписк|"
    r"[\u2b07\u2b06\u2193\u2191\u2b05\u27a1]|обход\s+глушил",     # section headers like "⬇️ Обход Глушилок ⬇️"
    re.I)
_DUMMY_HOSTS = {"", "0.0.0.0", "127.0.0.1", "::1", "::", "localhost"}
_ZERO_ID = re.compile(r"^[0:\-]+$")


def placeholder_reason(n):
    """Why this entry is an informational placeholder (days left, traffic, support...) and not a server; None = real node."""
    name = str(n.get("rawName") or n.get("name") or "")
    if _INFO_NAME.search(name):
        return "info-name"
    host = str(n.get("address") or "").strip().lower()
    if host in _DUMMY_HOSTS:
        return "dummy-address"
    try:
        port = int(n.get("port") or 0)
    except (TypeError, ValueError):
        port = 0
    if port <= 1:
        return "dummy-port"
    secret = ""
    try:
        s = n["outbound"]["settings"]
        secret = (s.get("vnext") or [{}])[0].get("users", [{}])[0].get("id", "") or ""
    except (KeyError, IndexError, TypeError, AttributeError):
        pass
    if secret and _ZERO_ID.match(secret):
        return "zero-uuid"
    return None


def split_placeholders(nodes, log=None):
    """-> (real nodes, [informational names]). Names only are logged (never addresses)."""
    real, info = [], []
    for n in nodes:
        why = placeholder_reason(n)
        if why:
            info.append(str(n.get("rawName") or n.get("name") or "")[:120])
            if log:
                log.info("subscription entry dropped as informational", name=str(n.get("name"))[:60], why=why)
        else:
            real.append(n)
    return real, info


_LTE = re.compile(r"\blte\b|мобильн|только\s+сот", re.I)
_AUTO = re.compile(r"авто[\s\-]*выбор|auto[\s\-]*select|\bавто\b|\bauto\b", re.I)


def node_tags(n):
    """Hints derived from the name and protocol only. Not a connectivity claim."""
    name = str(n.get("rawName") or n.get("name") or "")
    tags = []
    if _LTE.search(name):
        tags.append("lte")
    if _AUTO.search(name):
        tags.append("auto")
    if n.get("udp") or n.get("protocol") in ("hysteria2", "hysteria"):
        tags.append("udp")
    return tags


def _dedupe(nodes):
    """Drop exact repeats only. Two subscription entries may share one server/credentials under different names
    (e.g. an auto-select entry and the main server): the panel shows both, so we keep both. The first keeps its
    classic id (so a saved selection survives), later same-endpoint entries get an id derived from their name."""
    seen, out = {}, []
    for n in nodes:
        nid = n["id"]
        if nid in seen:
            if seen[nid] == n.get("name"):
                continue                                   # same endpoint and same name: a real duplicate
            nid = hashlib.sha1(f"{n['id']}|{n.get('name', '')}".encode("utf-8")).hexdigest()[:10]
            if nid in seen:
                continue
            n = dict(n)
            n["id"] = nid
        seen[nid] = n.get("name")
        out.append(n)
    return out
