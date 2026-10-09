"""Subscription: secret URL storage, fetching, parsing into nodes.json / meta.json.

The URL is a credential: it is stored only in secrets/vpn_subscription (mode 600), never logged,
never echoed, never written to nodes.json/meta.json/events.
"""
import base64
import ipaddress
import os
import re
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from . import links, paths
from .xlogshim import log

NODES = "nodes.json"
META = "meta.json"
MAX_BYTES = 5_000_000
UA_CANDIDATES = ["serpantinum-x/1 (xray)", "v2rayN/7.0", "Happ/4"]


class SubscriptionError(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


def validate_url(url):
    url = (url or "").strip()
    sp = urlsplit(url)
    if sp.scheme not in ("http", "https") or not sp.hostname:
        raise SubscriptionError("bad_url")
    if sp.scheme == "http" and os.environ.get("XVPN_ALLOW_HTTP") != "1":
        host = sp.hostname
        try:
            loop = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loop = host == "localhost"
        if not loop:
            raise SubscriptionError("http_not_allowed")
    return url


def read_url():
    try:
        return paths.secret_file().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def write_url(url):
    paths.ensure_dir(paths.secrets_dir())
    paths.atomic_write(paths.secret_file(), url + "\n", 0o600)


def clear_url():
    try:
        paths.secret_file().unlink()
    except OSError:
        pass


def fetch(url, ua, timeout=20, opener=None):
    """-> (text, headers dict lower-cased). The URL never appears in error details."""
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept": "*/*"})
    op = opener or urllib.request.urlopen
    try:
        with op(req, timeout=timeout) as r:
            raw = r.read(MAX_BYTES + 1)
            hdrs = {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        e.close()
        raise SubscriptionError("http_error", str(e.code)) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise SubscriptionError("network", e.__class__.__name__) from None
    if len(raw) > MAX_BYTES:
        raise SubscriptionError("too_large")
    return raw.decode("utf-8", "replace"), hdrs


def parse_userinfo(h):
    """subscription-userinfo: upload=0; download=123; total=200; expire=1789000000"""
    if not h:
        return None
    out = {}
    for part in h.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                out[k.strip().lower()] = int(float(v.strip()))
            except ValueError:
                pass
    if "total" not in out and "expire" not in out:
        return None
    used = out.get("upload", 0) + out.get("download", 0)
    return {"used": used, "total": out.get("total", 0), "expire": out.get("expire", 0)}


def parse_title(h):
    if not h:
        return ""
    if h.lower().startswith("base64:"):
        try:
            s = h[7:]
            s += "=" * (-len(s) % 4)
            return base64.b64decode(s).decode("utf-8", "replace")[:80]
        except (ValueError, base64.binascii.Error):
            return ""
    return h[:80]


def _uas(settings, meta):
    first = settings.get("userAgent") or (meta or {}).get("ua") or ""
    seen, out = set(), []
    for ua in ([first] if first else []) + UA_CANDIDATES:
        if ua and ua not in seen:
            seen.add(ua)
            out.append(ua)
    return out


def refresh(settings=None, opener=None, now=None):
    """Fetch + parse + store. -> meta dict. Keeps the previous nodes when anything fails."""
    settings = settings or paths.load_settings()
    url = read_url()
    if not url:
        log.warn("subscription refresh: no subscription link configured")
        raise SubscriptionError("no_subscription")
    old_meta = paths.read_json(paths.state_dir() / META, {}) or {}
    fmt = settings.get("format", "auto")
    best = None
    last_err = None
    uas = _uas(settings, old_meta)
    if fmt != "auto" or settings.get("userAgent"):
        uas = uas[:1]
    for ua in uas:
        try:
            text, hdrs = fetch(url, ua, opener=opener)
            parsed = links.parse_subscription_text(text, fmt)
        except (SubscriptionError, links.LinkError) as e:
            last_err = e
            log.warn("subscription fetch/parse failed", ua=ua, error=type(e).__name__, detail=str(e)[:80])
            continue
        if not parsed["nodes"]:
            last_err = SubscriptionError("no_nodes")
            continue
        cand = {"parsed": parsed, "hdrs": hdrs, "ua": ua}
        if best is None or (parsed["kind"] == "json" and best["parsed"]["kind"] != "json"):
            best = cand
        if parsed["kind"] == "json" or fmt == "links":
            break
    if best is None:
        log.error("subscription refresh failed (previous nodes kept)", last_error=type(last_err).__name__ if last_err else None)
        if isinstance(last_err, SubscriptionError):
            raise last_err
        raise SubscriptionError("parse_error", str(last_err)[:80])
    p, h = best["parsed"], best["hdrs"]
    now = int(now or time.time())
    doc = {"version": 1, "updated": now, "kind": p["kind"], "nodes": p["nodes"], "rules": p["rules"], "info": p.get("info", [])}
    paths.write_json(paths.state_dir() / NODES, doc, 0o600)
    meta = {
        "updated": now,
        "kind": p["kind"],
        "count": len(p["nodes"]),
        "skipped": len(p["skipped"]),
        "info": p.get("info", []),
        "title": parse_title(h.get("profile-title", "")),
        "userinfo": parse_userinfo(h.get("subscription-userinfo", "")),
        "intervalHours": _int(h.get("profile-update-interval")),
        "support": (h.get("support-url") or "")[:200],
        "ua": best["ua"],
        "notified": old_meta.get("notified", {}),
    }
    paths.write_json(paths.state_dir() / META, meta, 0o600)
    paths.append_event("vpn.subscription_updated", count=meta["count"], kind=meta["kind"])
    log.info("subscription entries kept: " + "; ".join(str(n.get("name"))[:50] for n in p["nodes"]),
             kept=len(p["nodes"]), informational=len(p.get("info", [])), unusable=len(p["skipped"]))
    log.info("subscription updated", nodes=meta["count"], skipped=meta["skipped"], kind=meta["kind"], ua=best["ua"],
             has_userinfo=bool(meta["userinfo"]), rules=len(p.get("rules") or []))
    return meta


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return 0


def load_nodes():
    doc = paths.read_json(paths.state_dir() / NODES, None)
    if not isinstance(doc, dict) or not isinstance(doc.get("nodes"), list):
        return {"nodes": [], "rules": [], "kind": "", "updated": 0, "info": []}
    # filter again on load: nodes.json written before the filter existed still holds the placeholders
    real, info = links.split_placeholders(doc["nodes"])
    doc = dict(doc, nodes=real, info=list(dict.fromkeys(list(doc.get("info") or []) + info)))
    return doc


def load_meta():
    return paths.read_json(paths.state_dir() / META, {}) or {}


def due(settings=None, now=None):
    settings = settings or paths.load_settings()
    meta = load_meta()
    if not meta.get("updated"):
        return bool(read_url())
    hours = settings.get("updateHours") or meta.get("intervalHours") or 6
    return (now or time.time()) - meta["updated"] >= hours * 3600


def public_nodes(doc=None):
    """Nodes without outbounds/credentials (what the UI and status JSON may see)."""
    doc = doc or load_nodes()
    out = []
    for n in doc.get("nodes", []):
        out.append({k: n[k] for k in ("id", "name", "flag", "cc", "protocol", "udp") if k in n}
                   | {"address_hint": _mask_host(n.get("address", "")), "tags": links.node_tags(n)})
    return out


def _mask_host(h):
    """Show only the registrable tail of a host (the full address is a server's identity)."""
    if not h:
        return ""
    if re.match(r"^[\d.:a-fA-F]+$", h):
        return "ip"
    parts = h.split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else h
