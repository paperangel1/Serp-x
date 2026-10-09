"""Executors of stage 9c: bar visibility, close window, open link, screenshot, VPN. Every external tool goes through
shellapi (stub-able); undo = capture/restore pairs. Privacy: links, window titles and VPN node names are never logged."""
import os
import re
import time
from urllib.parse import urlsplit

from . import paths, shellapi as S, vpnapi
from .actions import _hypr_json, _dispatch
from .errors import NodeError
from .executors import REGISTRY
from .xlogshim import log as xlog


def act(name):
    """Register an executor with a uniform log line (op, node, duration, failure); parameters are never logged."""
    def deco(fn):
        async def wrapped(ctx, node, arg):
            t0 = time.monotonic()
            try:
                out = await fn(ctx, node, arg)
            except BaseException as e:
                xlog.warn("action failed", op=name, node=node.get("id"), err=type(e).__name__, ms=int((time.monotonic() - t0) * 1000))
                raise
            xlog.info("action", op=name, node=node.get("id"), ms=int((time.monotonic() - t0) * 1000))
            return out
        REGISTRY[name] = wrapped
        return fn
    return deco


# ------------------------------------------------------------------------------------------------------- bar
@act("shell_bar")
async def shell_bar(ctx, node, inputs):
    await S.ipc(ctx, "xcmd", "setBar", inputs["mode"])
    return {}


@act("bar_capture")
async def bar_capture(ctx, node, inputs):
    return {"value": await S.ipc(ctx, "xcmd", "getBar")}


@act("bar_restore")
async def bar_restore(ctx, node, value):
    if value and value.get("value"):
        await S.ipc(ctx, "xcmd", "setBar", value["value"])


# ----------------------------------------------------------------------------------------------- close window
@act("window_close")
async def window_close(ctx, node, inputs):
    from .triggers import text_filter
    mode = inputs.get("mode") or "active"
    if mode == "active":
        w = await _hypr_json(ctx, "activewindow")
        if not isinstance(w, dict) or not w.get("address"):
            raise NodeError("Сейчас нет активного окна")
        targets = [w["address"]]
    else:
        cf, tf = str(inputs.get("class_filter") or ""), str(inputs.get("title_filter") or "")
        if not cf and not tf:
            raise NodeError("Укажите класс или заголовок окна: без этого непонятно, какие окна закрывать")
        wins = [c for c in await _hypr_json(ctx, "clients") if c.get("mapped", True) and c.get("address")
                and text_filter(cf, c.get("class")) and text_filter(tf, c.get("title"))]
        wins.sort(key=lambda c: c.get("focusHistoryID", 99))            # the most recently used first
        targets = [c["address"] for c in wins] if inputs.get("all") else [c["address"] for c in wins[:1]]
    for addr in targets:
        await _dispatch(ctx, "closewindow", "address:" + addr)
    return {"closed": len(targets)}


# ---------------------------------------------------------------------------------------------------- link
LINK_SCHEMES = ("http", "https", "mailto")


def check_link(url):
    """-> cleaned URL or NodeError. Only http, https and mailto; no spaces / control characters / leading dash."""
    u = str(url or "").strip()
    if not u or any(ord(ch) < 32 or ch.isspace() for ch in u) or len(u) > 4000:
        raise NodeError("Ссылка пустая или содержит пробелы и служебные символы")
    scheme = urlsplit(u).scheme.lower()
    if scheme not in LINK_SCHEMES:
        raise NodeError("Открываются только ссылки http, https и mailto, а не «%s:»" % (scheme or "?"))
    if scheme in ("http", "https") and not urlsplit(u).hostname:
        raise NodeError("В ссылке нет адреса сайта")
    return u


@act("open_link")
async def open_link(ctx, node, inputs):
    u = check_link(inputs["url"])
    res = await S.tool(ctx, ["xdg-open", u], timeout=10, capture=False)
    if res.rc != 0:
        raise NodeError("xdg-open не смог открыть ссылку (код %s): настроен ли браузер по умолчанию?" % res.rc)
    xlog.info("link opened", scheme=urlsplit(u).scheme.lower())
    return {}


# ------------------------------------------------------------------------------------------------- screenshot
GEOM_RE = re.compile(r"^-?\d{1,5},-?\d{1,5} \d{1,5}x\d{1,5}$")


def shots_dir():
    return os.path.join(os.environ.get("XDG_PICTURES_DIR") or os.path.join(os.path.expanduser("~"), "Pictures"), "Screenshots")


def _listing():
    try:
        return {f: os.path.getmtime(os.path.join(shots_dir(), f)) for f in os.listdir(shots_dir()) if f.lower().endswith(".png")}
    except OSError:
        return {}


@act("screenshot")
async def screenshot(ctx, node, inputs):
    mode, copy = inputs.get("mode") or "full", inputs.get("copy", True)
    argv = [paths.serpantinum_bin(), "screenshot"]
    if mode == "full":
        argv.append("--full")
    elif mode == "window":
        w = await _hypr_json(ctx, "activewindow")
        try:
            (x, y), (ww, hh) = w["at"], w["size"]
        except (KeyError, TypeError, ValueError):
            raise NodeError("Сейчас нет активного окна для снимка")
        argv += ["--geometry", "%d,%d %dx%d" % (x, y, ww, hh)]
    else:
        g = str(inputs.get("geometry") or "").strip()
        if g:
            if not GEOM_RE.match(g):
                raise NodeError("Область задаётся как «x,y ШxВ», например «100,100 800x600»")
            argv += ["--geometry", g]
    interactive = mode == "area" and len(argv) == 2           # the shell's own selection overlay: the user picks the area
    prev = None
    if not copy and not interactive:
        prev = await _clip_text(ctx)
    before = _listing()
    res = await S.tool(ctx, argv, timeout=30, capture=False)
    if res.rc != 0:
        raise NodeError("Инструмент снимков экрана вернул код %s (нужны grim и satty, оболочка запущена?)" % res.rc)
    if interactive:
        return {"path": ""}
    new = sorted((m, f) for f, m in _listing().items() if f not in before or m > before[f])
    path = os.path.join(shots_dir(), new[-1][1]) if new else ""
    if not copy:
        await _clip_put(ctx, prev)
    if not path:
        raise NodeError("Снимок не появился в папке «%s»" % shots_dir())
    return {"path": path}


async def _clip_text(ctx):
    """Current clipboard text, or None when it is empty / not text (an image is never read)."""
    types = await S.tool(ctx, ["wl-paste", "--list-types"], timeout=5)
    kinds = [t.strip() for t in types.out.splitlines()] if types.rc == 0 else []
    if any(k.startswith("image/") for k in kinds) or not any(k.startswith("text/") or k in ("UTF8_STRING", "STRING") for k in kinds):
        return None
    res = await ctx.proc.run(["wl-paste", "--no-newline"], timeout=5)
    return res.out if res.rc == 0 else None


async def _clip_put(ctx, text):
    from .sources_b import mark_own_copy
    mark_own_copy()
    if text is None:
        await ctx.proc.run(["wl-copy", "--clear"], timeout=5, capture=False)
    else:
        await ctx.proc.run(["wl-copy"], timeout=5, stdin=text, capture=False)


# -------------------------------------------------------------------------------------------------------- VPN
@act("vpn_set")
async def vpn_set(ctx, node, inputs):
    mode, name = inputs.get("mode") or "on", str(inputs.get("node") or "").strip()
    if mode == "toggle":
        st = await vpnapi.fresh_status(ctx)
        mode = "off" if st["state"] in ("on", "starting", "switching") else "on"
    if mode == "on":
        st = await vpnapi.connect(ctx, name)
    elif mode == "off":
        st = await vpnapi.disconnect(ctx)
    elif mode == "switch":
        if not name:
            raise NodeError("Для переключения укажите узел (имя или id)")
        st = await vpnapi.switch(ctx, name)
    else:
        raise NodeError("Режим VPN: on, off, toggle или switch")
    on = st["state"] == "on"
    return {"connected": on, "node_name": st["node"] if on else ""}


@act("vpn_capture")
async def vpn_capture(ctx, node, inputs):
    st = await vpnapi.fresh_status(ctx)
    return {"on": st["state"] == "on", "node": st["node"]}


@act("vpn_restore")
async def vpn_restore(ctx, node, value):
    """Best effort: undo must never raise out of the rollback, and it never touches Happ."""
    v = value or {}
    try:
        st = await vpnapi.fresh_status(ctx)
        if v.get("on") and st["state"] != "on":
            await vpnapi.connect(ctx, v.get("node") or "")
        elif not v.get("on") and st["state"] in ("on", "starting", "switching"):
            await vpnapi.disconnect(ctx)
    except NodeError as e:
        xlog.warn("vpn undo skipped", err=str(e)[:120])
