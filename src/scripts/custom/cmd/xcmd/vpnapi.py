"""Adapter to the VPN module: the ONLY way the engine touches our VPN. The daemon lives in the user systemd manager (no
logind session), where polkit refuses `systemctl start serp-xray`, so everything goes through the shell's `xvpn` IPC target
(`serpantinum ipc call xvpn connect|disconnect|switchTo|status`; XCMD_SERPANTINUM_BIN overrides the binary in tests).
The shell starts the work and returns at once; we poll `status`. We never stop Happ and never run systemctl ourselves.
Logging: states and results only; node names and addresses are never written to the log."""
import json

from . import shellapi as S
from .errors import NodeError
from .xlogshim import log as xlog

HAPP_MSG = "Сейчас работает Happ: наш VPN не включится, пока он активен. «Команды» никогда не выключают Happ — выключите его сами."
FAIL_REASONS = {
    "happ_active": HAPP_MSG,
    "no_nodes": "В VPN нет узлов: обновите подписку в разделе «VPN»",
    "no_connectivity": "VPN запустился, но интернета через него нет",
    "start_failed": "Не удалось запустить VPN (служба не стартовала): откройте раздел «VPN» и посмотрите причину",
}
STEP_S = 1.0
UP_WAIT_S = 30
DOWN_WAIT_S = 12


async def status(ctx):
    """-> {"state": on|off|starting|switching|failed|unknown, "node": str, "reason": str, "happ": bool}"""
    raw = await S.ipc(ctx, "xvpn", "status", quiet=True)
    try:
        d = json.loads(raw)
    except ValueError:
        raise NodeError("Раздел «VPN» оболочки вернул непонятный ответ: оболочка обновлена до этой версии?")
    return {"state": str(d.get("state") or "unknown"), "node": str(d.get("node") or ""), "reason": str(d.get("reason") or ""),
            "happ": bool(d.get("happ"))}


async def fresh_status(ctx):
    """The shell refreshes its cached state in the background; the first answer may be empty: ask again after a moment."""
    st = await status(ctx)
    if st["state"] == "unknown":
        await ctx.clock.sleep(1.0)
        st = await status(ctx)
    if st["state"] == "unknown":
        raise NodeError("Раздел «VPN» не ответил о своём состоянии: он включён, подписка загружена?")
    return st


async def _wait(ctx, want, seconds):
    """Poll until state is in `want`; a failure of the VPN module ends the wait with its reason."""
    n = int(seconds / STEP_S)
    st = None
    for _ in range(n):
        await ctx.clock.sleep(STEP_S)
        st = await status(ctx)
        if st["state"] in want:
            return st
        if st["state"] == "failed":
            raise NodeError(FAIL_REASONS.get(st["reason"], "VPN не включился (причина: %s)" % (st["reason"] or "неизвестна")))
    raise NodeError("VPN не успел перейти в нужное состояние за %d с" % seconds)


async def connect(ctx, node=""):
    st = await fresh_status(ctx)
    if st["happ"]:
        xlog.warn("vpn refused", why="happ_active")
        raise NodeError(HAPP_MSG)
    if st["state"] == "on" and not node:
        return st
    await S.ipc(ctx, "xvpn", "connect", node, quiet=True)
    out = await _wait(ctx, ("on",), UP_WAIT_S)
    xlog.info("vpn result", state=out["state"])
    return out


async def disconnect(ctx):
    st = await fresh_status(ctx)
    if st["state"] == "off":
        return st
    await S.ipc(ctx, "xvpn", "disconnect", quiet=True)
    out = await _wait(ctx, ("off", "failed"), DOWN_WAIT_S) if st["state"] != "failed" else st
    xlog.info("vpn result", state=out["state"])
    return out


async def switch(ctx, node):
    st = await fresh_status(ctx)
    if st["state"] != "on":
        raise NodeError("VPN выключен: сначала включите его, потом переключайте узел")
    await S.ipc(ctx, "xvpn", "switchTo", node, quiet=True)
    out = await _wait(ctx, ("on",), UP_WAIT_S)
    xlog.info("vpn result", state=out["state"])
    return out
