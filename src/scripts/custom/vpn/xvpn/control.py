"""State machine: off -> starting -> on -> switching -> on | failed -> off(reason).

All privileged work is done by the root service (see system/); this module only writes the user-side
config, asks systemd (via the narrow polkit rule) to start/stop OUR unit, and watches the result.
Nothing here ever stops or touches Happ.
"""
import fcntl
import os
import socket
import subprocess
import sys
import time
from urllib.parse import urlsplit

from .xlogshim import log

from . import config, core, geo, links, metrics, notify, paths, ping, resolve, subscription, system


class VpnError(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


# replaceable in tests
_sleep = time.sleep
_now = time.time

WAIT_START_SECONDS = 15
VERIFY_SECONDS = 15
VERIFY_INTERVAL = 1.0
PROBE_TIMEOUT = 2
WATCHDOG_INTERVAL = 10


# ---------------------------------------------------------------- persisted state

def read_state():
    return paths.read_json(paths.state_dir() / "state.json", {}) or {}


def write_state(**kw):
    st = read_state()
    prev = st.get("state")
    st.update(kw)
    paths.write_json(paths.state_dir() / "state.json", st, 0o600)
    if "state" in kw and kw["state"] != prev:       # transitions only (not the watchdog's failure counters)
        (log.warn if kw["state"] == "failed" else log.info)("state %s -> %s" % (prev or "?", kw["state"]),
                                                            reason=kw.get("reason") or None)
    return st


def default_node(nodes, cache=None):
    """-> (node, why). Never silently hysteria2 (UDP, cannot be pre-checked) or an LTE-only node when
    anything else exists. why: best_ping | first_tcp | only_udp_or_lte."""
    cache = cache if cache is not None else metrics.load_cache()
    tags = {n["id"]: links.node_tags(n) for n in nodes}
    ok = [n for n in nodes if "udp" not in tags[n["id"]] and "lte" not in tags[n["id"]]]
    measured = [n for n in ok if (cache.get(n["id"]) or {}).get("ping")]
    if measured:
        return min(measured, key=lambda n: cache[n["id"]]["ping"]), "best_ping"
    if ok:
        return ok[0], "first_tcp"
    tcp = [n for n in nodes if "udp" not in tags[n["id"]]]
    return (tcp or nodes)[0], "only_udp_or_lte"


def selected_node(doc=None, with_why=False):
    doc = doc or subscription.load_nodes()
    nodes = doc.get("nodes", [])
    if not nodes:
        return (None, "") if with_why else None
    sel = read_state().get("selected")
    for n in nodes:
        if n["id"] == sel:
            st = read_state()
            return (n, (st.get("selectedWhy") or "auto") if st.get("selectedAuto") else "user") if with_why else n
    n, why = default_node(nodes)
    return (n, why) if with_why else n


def find_node(node_id, doc=None):
    doc = doc or subscription.load_nodes()
    for n in doc.get("nodes", []):
        if n["id"] == node_id:
            return n
    raise VpnError("unknown_node")


# ---------------------------------------------------------------- status

def _display_url():
    u = subscription.read_url()
    if not u:
        return ""
    sp = urlsplit(u)
    return f"{sp.scheme}://{sp.hostname}/" + "•" * 12


def status(now=None):
    now = now or _now()
    settings = paths.load_settings()
    st = read_state()
    svc = system.unit_active()
    tun = system.tun_present()
    doc = subscription.load_nodes()
    meta = subscription.load_meta()
    caps = core.capabilities()
    cache = metrics.load_cache()

    hs = system.happ_state()
    happ = system.happ_conflict(hs)
    state, reason = "off", ""
    busy = st.get("state") in ("starting", "switching") and st.get("busyUntil", 0) > now
    if svc and tun:
        state = "switching" if (st.get("state") == "switching" and busy) else "on"
    elif svc or busy:
        state = st.get("state") if st.get("state") in ("starting", "switching") else "starting"
    elif st.get("state") == "failed":
        state, reason = "failed", st.get("reason", "")
        if reason == "happ_active" and not happ:       # the user switched Happ off: "check again" must clear it
            state, reason = "off", ""
    rx, tx = system.counters()

    node = None
    cur, sel_why = selected_node(doc, with_why=True)
    if cur:
        node = {k: cur[k] for k in ("id", "name", "flag", "cc", "protocol") if k in cur}
    degraded = []
    if not system.unit_installed():
        degraded.append("service_missing")
    elif system.polkit_state() is False:                # None (unreadable directory) is not a defect
        degraded.append("polkit_missing")
    if not caps["exists"]:
        degraded.append("xray_missing")
    elif not caps["tun"]:
        degraded.append("tun_unsupported")
    if settings["mode"] == "ru-direct" and not core.geo_present():
        degraded.append("geo_missing")
    if state == "off" and happ:
        degraded.append("happ_active")

    nodes = []
    pkey = ping.cache_key(settings)
    busy_ping = st.get("pingBusyUntil", 0) > now
    for n in subscription.public_nodes(doc):
        c = cache.get(n["id"], {})
        mine = c.get("pingKey") == pkey                 # a result made with another method/URL is not shown
        fresh = mine and c.get("pingTs") and now - c["pingTs"] < PING_TTL
        n["pingMs"] = c.get("ping") if mine else None
        if _node_na(n, settings["pingMethod"]):
            n["pingState"] = "na"
        elif busy_ping and (st.get("pingForce") or not fresh):
            n["pingState"] = "measuring"
        else:
            n["pingState"] = (c.get("pingState") or ("ok" if c.get("ping") else "timeout")) if mine and c.get("pingTs") else "none"
        n["pingAge"] = int(now - c["pingTs"]) if mine and c.get("pingTs") else None
        n["speedMbps"] = c.get("speed")
        n["speedAge"] = int(now - c["speedTs"]) if c.get("speedTs") else None
        nodes.append(n)

    return {
        "state": state,
        "reason": reason,
        "reasonNode": st.get("reasonNode", "") if state == "failed" else "",
        "phase": st.get("phase", "") if state in ("starting", "switching") else "",
        "node": node,
        "since": st.get("since", 0) if state == "on" else 0,
        "mode": settings["mode"],
        "killSwitch": settings["killSwitch"],
        "blockIPv6": settings["blockIPv6"],
        "autoDisable": settings["autoDisable"],
        "nodes": nodes,
        "measuring": busy_ping,
        "ping": {"method": settings["pingMethod"], "display": settings["pingDisplay"],
                 "timeout": settings["pingTimeout"], "url": settings["pingUrl"]},
        "selection": sel_why,
        "traffic": meta.get("userinfo"),
        "subscription": {
            "configured": bool(subscription.read_url()),
            "display": _display_url(),
            "updated": meta.get("updated", 0),
            "count": meta.get("count", 0),
            "kind": meta.get("kind", ""),
            "title": meta.get("title", ""),
            "info": doc.get("info") or meta.get("info") or [],
            "intervalHours": settings["updateHours"],
        },
        "geo": geo.info(),
        "core": {"path": caps["path"], "version": caps["version"], "exists": caps["exists"],
                 "tun": caps["tun"], "hysteria": caps["hysteria"]},
        "service": {"installed": system.unit_installed(), "active": svc, "polkit": system.polkit_state(),
                    "unit": paths.UNIT},
        "happActive": happ,
        "happ": dict(hs, conflict=happ),
        "rxBytes": rx, "txBytes": tx, "ts": int(now),
        "degraded": degraded,
    }


# ---------------------------------------------------------------- actions

def _resolve_bypass(nodes, extra=(), net=None):
    """IPs of every node server (so the root layer keeps them off the tunnel). System resolver, parallel, 3 s cap."""
    net = net or resolve.all_nodes_net(nodes)
    return list(dict.fromkeys(list(extra) + list(net["ips"])))[:256]


def write_runtime(settings, doc, boot=None, net=None):
    paths.write_json(paths.state_dir() / "runtime.json", {
        "killSwitch": bool(settings["killSwitch"]),
        "blockIPv6": bool(settings["blockIPv6"]),
        "bypassIps": _resolve_bypass(doc.get("nodes", []), resolve.server_ips(boot) if boot else (), net),
    }, 0o600)


def build_and_write(node, settings, doc, boot=None):
    """Generate + validate (inbound-less variant) + write the user-side config the root service will pick up.
    ALL nodes' server IPs go into the direct rule, so node measurement keeps working while connected."""
    net = resolve.all_nodes_net(doc.get("nodes", []), boot)
    cfg = config.build_config(node, settings, doc.get("rules"), geo_present=core.geo_present(), boot=boot, all_nodes=net)
    ok, msg = core.validate(config.test_variant(cfg), geo_dir=core.geo_dir() if core.geo_present() else None)
    if not ok:
        raise VpnError("config_invalid", msg)
    config.check_root_safe(cfg)
    paths.write_json(paths.state_dir() / "config.json", cfg, 0o600)
    write_runtime(settings, doc, boot, net)
    return cfg


def _wait_up(settings, seconds=WAIT_START_SECONDS):
    t0 = _now()
    while _now() - t0 < seconds:
        if system.unit_active() and system.tun_present():
            return True
        if system.unit_state() == "failed":
            return False
        _sleep(0.5)
    return False


def _classify_failure(domains, since):
    """Why the probes failed, from the core's own journal (best effort, never raises). -> reason code."""
    text = system.journal_tail(since)
    low = text.lower()
    if any(d in low for d in domains) and ("app/dns" in low or "lookup" in low or "dns" in low):
        return "server_dns"
    if any(k in low for k in ("connection refused", "i/o timeout", "network is unreachable", "no route to host", "handshake")) and "dial" in low:
        return "proxy_unreachable"
    return "no_connectivity"


def _verify(settings, domains=(), seconds=VERIFY_SECONDS):
    """Poll once a second; the first passing probe wins. -> (True, "") | (False, reason)."""
    t0 = _now()
    while True:
        if metrics.probe_via_socks(int(settings["socksPort"]), timeout=PROBE_TIMEOUT):
            log.info("connectivity ok", ms=int((_now() - t0) * 1000))
            return True, ""
        if _now() - t0 >= seconds:
            break
        _sleep(VERIFY_INTERVAL)
    reason = _classify_failure(list(domains), int(t0))
    log.warn("connectivity check failed", reason=reason, seconds=int(_now() - t0))
    return False, reason


def _fail(reason, detail=""):
    log.error("connect failed", reason=reason, detail=(detail or None) and str(detail)[:200])
    write_state(state="failed", reason=reason, busyUntil=0, failedAt=int(_now()), phase="",
                reasonNode=detail if reason == "server_dns" else "")
    paths.append_event("vpn.failed", reason=reason)
    return {"ok": False, "state": "failed", "error": reason, "detail": detail}


def connect(node_id=None, switching=False):
    log.info("connect requested", switching=switching or None, node_given=bool(node_id))
    settings = paths.load_settings()
    hs = system.happ_state()
    if system.happ_conflict(hs):                    # never both at once, never stop Happ ourselves
        return _fail("happ_active", "core=%s iface=%s default_route=%s" % (hs["core"], hs["iface"], hs["defaultRoute"]))
    if not system.unit_installed():
        return _fail("service_missing")
    doc = subscription.load_nodes()
    if not doc.get("nodes"):
        return _fail("no_nodes")
    try:
        node = find_node(node_id, doc) if node_id else selected_node(doc)
    except VpnError as e:
        return _fail(e.code)
    auto = not node_id and read_state().get("selected") != node["id"]
    why = read_state().get("selectedWhy", "")
    if auto:
        why = selected_node(doc, with_why=True)[1]
        log.info("no node chosen by the user: default picked", node=node["name"][:50], protocol=node.get("protocol"), why=why)
    write_state(state="switching" if switching else "starting", busyUntil=int(_now()) + 50, selected=node["id"], reason="",
                selectedAuto=auto or (not node_id and bool(read_state().get("selectedAuto"))), selectedWhy=why if not node_id else "")
    boot = None
    domains = resolve.outbound_domains([node["outbound"]])
    if domains:
        write_state(phase="resolving")
        boot = resolve.bootstrap(domains, label=node["name"][:50])
        if boot["failed"]:
            return _fail("server_dns", node["name"])
    try:
        build_and_write(node, settings, doc, boot)
    except VpnError as e:
        return _fail(e.code, e.detail)
    write_state(phase="starting")
    rc = system.restart() if switching else system.start()
    if rc != 0:
        return _fail("start_failed")
    if not _wait_up(settings):
        system.stop()
        return _fail("start_timeout")
    write_state(phase="checking")
    ok, why_not = _verify(settings, domains)
    if not ok:
        system.stop()
        return _fail(why_not, node["name"])
    write_state(state="on", reason="", phase="", reasonNode="", busyUntil=0, since=int(_now()), failures=0)
    paths.append_event("vpn.node_changed" if switching else "vpn.connected", node=node["name"], cc=node.get("cc", ""))
    ensure_watchdog()
    log.info("connected", node=node["name"], cc=node.get("cc") or None, switching=switching or None)
    return {"ok": True, "state": "on", "node": node["name"]}


def disconnect():
    rc = system.stop()
    log.info("disconnect", rc=rc)
    write_state(state="off", reason="", busyUntil=0, failures=0)
    paths.append_event("vpn.disconnected")
    return {"ok": rc == 0, "state": "off"}


def switch(node_id):
    """Connected -> rewrite config + reload the core; off -> only remember the choice."""
    find_node(node_id)
    if system.unit_active():
        return connect(node_id, switching=True)
    write_state(selected=node_id, selectedAuto=False)
    return {"ok": True, "state": "off", "selected": node_id}


def toggle():
    return disconnect() if (system.unit_active() or system.tun_present()) else connect()


def next_node():
    doc = subscription.load_nodes()
    nodes = doc.get("nodes", [])
    if not nodes:
        return _fail("no_nodes")
    cur = selected_node(doc)
    i = next((k for k, n in enumerate(nodes) if n["id"] == cur["id"]), -1)
    return switch(nodes[(i + 1) % len(nodes)]["id"])


# ---------------------------------------------------------------- watchdog

def watchdog_tick(now=None, probe=None):
    """One probe. Returns "idle" | "ok" | "warn" | "disabled". After autoDisableSeconds of failures the
    tunnel is stopped (routes are removed by the service's ExecStopPost) so internet always comes back."""
    now = now or _now()
    settings = paths.load_settings()
    if not system.unit_active():
        write_state(failures=0)
        return "idle"
    ok = (probe or (lambda: metrics.probe_via_socks(int(settings["socksPort"]), timeout=4)))()
    st = read_state()
    if ok:
        write_state(failures=0)
        return "ok"
    failures = int(st.get("failures", 0)) + 1
    log.warn("watchdog: probe failed", failures=failures)
    write_state(failures=failures)
    limit = max(2, int(settings["autoDisableSeconds"]) // WATCHDOG_INTERVAL + 1)
    if settings["autoDisable"] and failures >= limit:
        system.stop()
        log.error("watchdog: no connectivity, tunnel stopped (auto-disable)", failures=failures, limit=limit)
        write_state(state="failed", reason="no_connectivity", failures=0, busyUntil=0, failedAt=int(now))
        paths.append_event("vpn.failed", reason="no_connectivity")
        notify.notify("VPN отключён: нет связи с узлом", "Интернет возвращён напрямую.", "critical")
        return "disabled"
    return "warn"


def _pidfile():
    return paths.state_dir() / "watchdog.pid"


def watchdog_alive():
    try:
        pid = int(_pidfile().read_text())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def ensure_watchdog():
    """Spawn the detached watchdog loop unless one is running (a user timer is unnecessary)."""
    if watchdog_alive() or os.environ.get("XVPN_NO_WATCHDOG") == "1":
        return False
    try:
        p = subprocess.Popen([sys.executable, "-m", "xvpn", "watchdog", "--loop"], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             env={**os.environ, "PYTHONPATH": os.path.dirname(os.path.dirname(os.path.abspath(__file__)))})
        paths.atomic_write(_pidfile(), str(p.pid), 0o600)
        return True
    except OSError:
        return False


def watchdog_loop(max_ticks=None):
    paths.atomic_write(_pidfile(), str(os.getpid()), 0o600)
    idle = 0
    ticks = 0
    while True:
        r = watchdog_tick()
        idle = idle + 1 if r == "idle" else 0
        ticks += 1
        if idle >= 2 or (max_ticks and ticks >= max_ticks):
            break
        _sleep(WATCHDOG_INTERVAL)
    try:
        _pidfile().unlink()
    except OSError:
        pass


# ---------------------------------------------------------------- measurements / refresh

PING_TTL = 120


def _node_na(n, method):
    """Not measurable with this method: UDP-based nodes by TCP/ICMP."""
    return method in ("tcp", "icmp") and bool(n.get("udp") or "udp" in links.node_tags(n))


def ping_all(force=False):
    """Latency of every node by settings.vpn.pingMethod (see ping.py). Results younger than PING_TTL and made with
    the same method/URL are reused unless force. -> {id: {"ms", "state"}}. Logs counts and reasons, never addresses."""
    settings = paths.load_settings()
    method = settings["pingMethod"]
    key = ping.cache_key(settings)
    doc = subscription.load_nodes()
    nodes = doc.get("nodes", [])
    cache = metrics.load_cache()
    ts = int(_now())
    fresh, stale = {}, []
    for n in nodes:
        c = cache.get(n["id"]) or {}
        if not force and c.get("pingTs") and ts - c["pingTs"] < PING_TTL and c.get("pingKey") == key:
            fresh[n["id"]] = {"ms": c.get("ping"), "state": c.get("pingState") or ("ok" if c.get("ping") else "timeout")}
        else:
            stale.append(n)
    if not stale:
        log.info("node measurement served from cache", method=method, nodes=len(nodes))
        return fresh
    lock = open(paths.ensure_dir(paths.state_dir()) / "ping.lock", "a")
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:                                  # another measurement is running: do not start a second instance
            log.info("node measurement already running", method=method)
            return {n["id"]: fresh.get(n["id"]) or {"ms": None, "state": "measuring"} for n in nodes}
        write_state(pingBusyUntil=ts + settings["pingTimeout"] + 25, pingForce=bool(force))
        t0 = time.monotonic()
        try:
            res = ping.measure(stale, settings)
        finally:
            write_state(pingBusyUntil=0, pingForce=False)
    finally:
        lock.close()
    for n in stale:
        v = res.get(n["id"]) or {"ms": None, "state": "error", "reason": "internal"}
        c = cache.setdefault(n["id"], {})
        c["ping"], c["pingState"], c["pingTs"], c["pingKey"] = v["ms"], v["state"], ts, key
    metrics.save_cache(cache)
    out = {nid: {"ms": v["ms"], "state": v["state"]} for nid, v in res.items()}
    out.update(fresh)
    counts, reasons = {}, {}
    for v in res.values():
        counts[v["state"]] = counts.get(v["state"], 0) + 1
        if v["state"] != "ok" and v.get("reason"):
            reasons[v["reason"]] = reasons.get(v["reason"], 0) + 1
    log.info("node measurement done", method=method, timeout=settings["pingTimeout"], nodes=len(nodes),
             measured=len(stale), cached=len(fresh), ms=int((time.monotonic() - t0) * 1000),
             **{"n_" + k: v for k, v in counts.items()}, **{"why_" + k: v for k, v in reasons.items()})
    return out


def speedtest():
    settings = paths.load_settings()
    if not system.unit_active():
        raise VpnError("not_connected")
    cur = selected_node()
    mbps = metrics.download_mbps(int(settings["socksPort"]))
    cache = metrics.load_cache()
    c = cache.setdefault(cur["id"], {})
    c["speed"], c["speedTs"] = mbps, int(_now())
    metrics.save_cache(cache)
    return {"id": cur["id"], "mbps": mbps}


def check_expiry(meta, now=None):
    """Notify (once a day per kind) when traffic < 10 % left or the subscription expires in < 7 days."""
    now = int(now or _now())
    ui = meta.get("userinfo") or {}
    sent = meta.setdefault("notified", {})
    day = now // 86400
    out = []
    total, used, exp = ui.get("total", 0), ui.get("used", 0), ui.get("expire", 0)
    if total and (total - used) < total * 0.10 and sent.get("traffic") != day:
        sent["traffic"] = day
        out.append(("Трафик подписки почти закончился", f"Осталось меньше 10 %"))
    if exp and 0 < exp - now < 7 * 86400 and sent.get("expire") != day:
        sent["expire"] = day
        out.append(("Подписка скоро закончится", f"Осталось меньше 7 дней"))
    for t, b in out:
        notify.notify(t, b, "normal")
    return out


def refresh(force=False):
    settings = paths.load_settings()
    if not force and not subscription.due(settings):
        return {"ok": True, "skipped": True}
    log.info("subscription refresh requested", force=force or None)
    meta = subscription.refresh(settings)
    check_expiry(meta)
    paths.write_json(paths.state_dir() / subscription.META, meta, 0o600)
    return {"ok": True, "count": meta["count"], "kind": meta["kind"]}
