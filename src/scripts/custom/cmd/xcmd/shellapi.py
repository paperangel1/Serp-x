"""Adapter: the only place where executors talk to the running shell (IPC targets) and to system tools.
Every call is logged through xlog (tool, exit code, duration). Tests stub the world with fake binaries on PATH
(`serpantinum`, hyprctl, wpctl, pactl, playerctl, wl-paste, magick) and XCMD_SERPANTINUM_BIN."""
import os
import time

from . import paths
from .errors import NodeError
from .xlogshim import log as xlog


async def tool(ctx, argv, timeout=10, log_args=True, **kw):
    """Run an external tool through ctx.proc and log it (`log_args=False`: only the tool name, for private arguments)."""
    t0 = time.monotonic()
    res = await ctx.proc.run(argv, timeout=timeout, **kw)
    xlog.info("tool", tool=os.path.basename(argv[0]), args=" ".join(str(a) for a in argv[1:])[:160] if log_args else "…", rc=res.rc,
              ms=int((time.monotonic() - t0) * 1000))
    return res


async def ipc(ctx, target, fn, *args, quiet=False):
    """`serpantinum ipc call <target> <fn> args…` -> printed value. A value starting with `err:` is an error from the QML side."""
    argv = [paths.serpantinum_bin(), "ipc", "call", target, fn] + [("true" if a is True else "false" if a is False else str(a)) for a in args]
    res = await tool(ctx, argv, timeout=8, log_args=not quiet)
    if res.rc != 0:
        raise NodeError("Цель «%s» оболочки не отвечает: оболочка запущена и обновлена до этой версии?" % target)
    out = res.out.strip()
    if out.startswith("err:"):
        raise NodeError(out[4:].strip() or "Оболочка отказалась выполнить действие")
    return out


async def brightness_get(ctx):
    res = await tool(ctx, [paths.serpantinum_bin(), "brightness", "get"], timeout=10)
    try:
        return max(0, min(100, int(float(res.out.strip().split()[0]))))
    except (ValueError, IndexError):
        raise NodeError("Не удалось узнать яркость: у экрана нет управляемой подсветки (ни backlight, ни DDC)")


async def brightness_set(ctx, percent):
    res = await tool(ctx, [paths.serpantinum_bin(), "brightness", "set", str(int(percent))], timeout=20)
    if res.rc != 0:
        raise NodeError("Не удалось поменять яркость: скрипт яркости вернул код %s" % res.rc)
