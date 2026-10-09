"""Command line of the VPN module (x_vpn.sh -> python3 -m xvpn). Every command prints one JSON document."""
import json
import os
import stat
import sys
import time

from . import config, control, core, geo, install, links, paths, ping, resolve, subscription, system
from .xlogshim import log


def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    return code


def err(code, detail="", rc=1):
    return out({"ok": False, "error": code, "detail": detail}, rc)


def redact(obj):
    """Copy of a config with credentials hidden (for logs/support output)."""
    secret_keys = {"password", "id", "auth", "publicKey", "shortId", "uuid", "serviceName"}
    if isinstance(obj, dict):
        return {k: ("<hidden>" if k in secret_keys and isinstance(v, str) else redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


# ---------------------------------------------------------------- doctor

def doctor():
    rows = []

    def add(key, level, text):
        rows.append({"key": key, "level": level, "text": text})

    caps = core.capabilities()
    if not caps["exists"]:
        add("xray", "fail", "Ядро Xray не найдено (установите пакет xray)")
    else:
        feats = [n for n in ("tun", "hysteria", "reality") if caps[n]]
        miss = [n for n in ("tun", "hysteria") if not caps[n]]
        add("xray", "warn" if miss else "ok",
            f"Xray {caps['version'] or '?'} ({caps['path']}); нет поддержки: {', '.join(miss)}" if miss
            else f"Xray {caps['version'] or '?'} ({caps['path']}): TUN, Hysteria2, Reality")
    settings = paths.load_settings()
    doc = subscription.load_nodes()
    meta = subscription.load_meta()
    if not subscription.read_url():
        add("subscription", "warn", "Ссылка подписки не задана")
    else:
        age = int(time.time() - meta.get("updated", 0)) if meta.get("updated") else None
        limit = max(settings["updateHours"], 1) * 3 * 3600
        if age is None:
            add("subscription", "warn", "Подписка ещё не загружалась")
        elif age > limit:
            add("subscription", "warn", f"Подписка не обновлялась {age // 3600} ч")
        else:
            add("subscription", "ok", f"Подписка: узлов {meta.get('count', 0)}, обновлена {age // 60} мин назад")
    sf = paths.secret_file()
    if sf.exists():
        mode = stat.S_IMODE(sf.stat().st_mode)
        add("secret_perms", "ok" if mode == 0o600 else "warn", "Права ключа подписки 600" if mode == 0o600 else f"Права ключа подписки {mode:o}, нужно 600")
    nodes = doc.get("nodes", [])
    if nodes and caps["exists"]:
        node = control.selected_node(doc)
        cfg = config.build_config(node, settings, doc.get("rules"), geo_present=core.geo_present())
        ok, msg = core.validate(config.test_variant(cfg), geo_dir=core.geo_dir() if core.geo_present() else None)
        add("config", "ok" if ok else "fail", "Конфиг проходит проверку xray -test" if ok else f"Конфиг не прошёл проверку: {msg[:120]}")
    elif not nodes:
        add("config", "warn", "Нет узлов: нечего проверять")
    if nodes:
        node = control.selected_node(doc)
        doms = resolve.outbound_domains([node["outbound"]])
        if doms:
            boot = resolve.bootstrap(doms, label=node["name"][:50])
            add("server_dns", "fail" if boot["failed"] else "ok",
                "DNS сервера узла: ошибка (не удалось определить адрес сервера)" if boot["failed"] else "DNS сервера узла: ok")
        else:
            add("server_dns", "ok", "DNS сервера узла: ok (адрес задан IP)")
    pok, ptext = ping.selfcheck()
    add("ping", "ok" if pok else "warn", ptext)
    gi = geo.info()
    add("geo", "ok" if gi["present"] else ("warn" if settings["mode"] == "ru-direct" else "ok"),
        "Геобазы РФ на месте" if gi["present"] else "Геобаз РФ нет (режим «Россия напрямую» без списков)")
    for row in install.check():
        level = "info" if row.get("unknown") else ("ok" if row["ok"] else "warn")
        add("root:" + row["name"], level, f"{row['name']}: {'ok' if row['ok'] and not row.get('unknown') else row['detail']}")
    hs = system.happ_state()
    if system.happ_conflict(hs):
        add("happ", "warn", "VPN в Happ включён (работает его ядро или туннель happ-xray): отключите его в приложении Happ, затем повторите")
    else:
        add("happ", "ok", "VPN в Happ не включён" + (" (служба happd работает постоянно, это нормально)" if hs["daemon"] else ""))
    return rows


# ---------------------------------------------------------------- dispatch

_QUIET = {"status", "nodes", "doctor", "watchdog"}     # polled by the UI / timers: debug level only


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd0 = argv[0] if argv else "?"
    t0 = time.monotonic()
    (log.debug if cmd0 in _QUIET else log.info)("cli %s" % cmd0)
    rc = 1
    try:
        rc = _main(argv)
        return rc
    except Exception as e:
        log.exception("cli %s crashed" % cmd0, exc=e)
        raise
    finally:
        (log.debug if cmd0 in _QUIET and rc == 0 else (log.info if rc == 0 else log.warn))(
            "cli %s done" % cmd0, rc=rc, ms=int((time.monotonic() - t0) * 1000))


def _main(argv):
    if not argv:
        return err("usage", "x_vpn.sh {status|nodes|connect|disconnect|toggle|switch|select|next|refresh|set-subscription|"
                            "clear-subscription|geo-update|ping|speed|watchdog|validate|doctor|install|gen-config}", 2)
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "status":
            return out(control.status())
        if cmd == "nodes":
            return out(subscription.public_nodes())
        if cmd == "connect":
            r = control.connect(args[0] if args else None)
            return out(r, 0 if r.get("ok") else 1)
        if cmd == "disconnect":
            return out(control.disconnect())
        if cmd == "toggle":
            r = control.toggle()
            return out(r, 0 if r.get("ok") else 1)
        if cmd == "switch" and args:
            r = control.switch(args[0])
            return out(r, 0 if r.get("ok") else 1)
        if cmd == "select" and args:
            control.find_node(args[0])
            control.write_state(selected=args[0], selectedAuto=False)
            return out({"ok": True, "selected": args[0]})
        if cmd == "next":
            r = control.next_node()
            return out(r, 0 if r.get("ok") else 1)
        if cmd == "refresh":
            try:
                return out(control.refresh(force="--force" in args or "--if-due" not in args))
            except subscription.SubscriptionError as e:
                return err(e.code, e.detail)
        if cmd == "set-subscription":
            url = sys.stdin.readline().strip()
            try:
                url = subscription.validate_url(url)
            except subscription.SubscriptionError as e:
                return err(e.code)
            prev = subscription.read_url()
            subscription.write_url(url)
            try:
                r = control.refresh(force=True)
            except subscription.SubscriptionError as e:
                if prev:
                    subscription.write_url(prev)
                else:
                    subscription.clear_url()
                return err(e.code, e.detail)
            return out(r)
        if cmd == "clear-subscription":
            subscription.clear_url()
            for n in (subscription.NODES, subscription.META):
                try:
                    (paths.state_dir() / n).unlink()
                except OSError:
                    pass
            return out({"ok": True})
        if cmd == "geo-update":
            try:
                return out({"ok": True, **geo.update()})
            except geo.GeoError as e:
                return err(e.code, e.detail)
        if cmd == "ping":
            res = control.ping_all(force="--force" in args)
            return out({"ok": True, "ping": {k: v["ms"] if v["state"] == "ok" else ("na" if v["state"] == "na" else None)
                                             for k, v in res.items()}, "states": {k: v["state"] for k, v in res.items()}})
        if cmd == "speed":
            return out({"ok": True, **control.speedtest()})
        if cmd == "watchdog":
            if "--loop" in args:
                control.watchdog_loop()
                return out({"ok": True})
            return out({"ok": True, "result": control.watchdog_tick()})
        if cmd == "validate":
            doc = subscription.load_nodes()
            node = control.selected_node(doc)
            if not node:
                return err("no_nodes")
            settings = paths.load_settings()
            cfg = config.build_config(node, settings, doc.get("rules"), geo_present=core.geo_present())
            ok, msg = core.validate(config.test_variant(cfg), geo_dir=core.geo_dir() if core.geo_present() else None)
            return out({"ok": ok, "message": msg}, 0 if ok else 1)
        if cmd == "gen-config":
            doc = subscription.load_nodes()
            node = control.selected_node(doc)
            if not node:
                return err("no_nodes")
            cfg = config.build_config(node, paths.load_settings(), doc.get("rules"), geo_present=core.geo_present(),
                                      with_inbounds="--no-inbounds" not in args)
            print(json.dumps(cfg if "--secrets" in args else redact(cfg), ensure_ascii=False, indent=1))
            return 0
        if cmd == "doctor":
            return out(doctor())
        if cmd == "install":
            root = args[args.index("--root") + 1] if "--root" in args else None
            if "--print" in args:
                print(install.print_all())
                return 0
            if "--apply" in args:
                try:
                    return out(install.apply(root=root))
                except PermissionError as e:
                    return err("not_allowed", str(e))
            rows = install.check(root=root)
            return out({"ok": all(r["ok"] for r in rows), "files": rows}, 0 if all(r["ok"] for r in rows) else 1)
    except control.VpnError as e:
        return err(e.code, e.detail)
    return err("usage", f"unknown command: {cmd}", 2)
