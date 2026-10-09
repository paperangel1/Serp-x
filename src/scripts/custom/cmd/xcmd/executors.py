"""Executors of `py`/`ipc` nodes. Every external tool goes through ctx.proc so tests can stub it via PATH."""
import json

from . import paths, shellapi, ptypes as T
from .errors import NodeError
from .procs import clean_env

REGISTRY = {}
MAX_OUT = 65536


def reg(name):
    def deco(fn):
        REGISTRY[name] = fn
        return fn
    return deco


def to_text(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "да" if value else "нет"
    if isinstance(value, float):
        return ("%g" % value) if value == int(value) or abs(value) < 1e15 else repr(value)
    if isinstance(value, (list, tuple)):
        return ", ".join(to_text(v) for v in value)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def _fail(res, what):
    tail = (res.err or res.out or "").strip().splitlines()[-1:] or [""]
    raise NodeError("%s: код выхода %s%s" % (what, res.rc, (" — " + tail[0]) if tail[0] else ""))


@reg("notify")
async def notify(ctx, node, inputs):
    argv = ["notify-send", "-a", "Serpantinum", "--", inputs["title"]]
    if inputs.get("body"):
        argv.append(inputs["body"])
    res = await ctx.proc.run(argv, timeout=10, capture=True)
    if res.rc != 0:
        _fail(res, "notify-send")
    return {}


@reg("clipboard_set")
async def clipboard_set(ctx, node, inputs):
    from .sources_b import mark_own_copy
    mark_own_copy()                                  # our own copy must not fire «link copied» triggers
    res = await ctx.proc.run(["wl-copy"], timeout=5, stdin=inputs["text"], capture=False)
    if res.rc != 0:
        _fail(res, "wl-copy")
    return {}


@reg("clipboard_capture")
async def clipboard_capture(ctx, node, inputs):
    res = await ctx.proc.run(["wl-paste", "--no-newline"], timeout=5)
    return {"text": res.out if res.rc == 0 else None}


@reg("clipboard_restore")
async def clipboard_restore(ctx, node, value):
    from .sources_b import mark_own_copy
    mark_own_copy()
    if value is None or value.get("text") is None:
        await ctx.proc.run(["wl-copy", "--clear"], timeout=5, capture=False)
    else:
        await ctx.proc.run(["wl-copy"], timeout=5, stdin=value["text"], capture=False)


@reg("shell")
async def shell(ctx, node, inputs):
    res = await ctx.proc.run(["bash", "-c", inputs["command"], "serpantinum", inputs.get("arg") or ""], timeout=float(inputs.get("timeout") or 10),
                             env=clean_env(), cwd=paths._home())
    if res.timed_out:
        raise NodeError("Команда не уложилась в %s с и была остановлена" % inputs.get("timeout"))
    if res.rc != 0:
        _fail(res, "Команда оболочки")
    out = res.out[:MAX_OUT]
    return {"stdout": out[:-1] if out.endswith("\n") else out, "exit_code": res.rc}


@reg("show_result")
async def show_result(ctx, node, inputs):
    text, title = to_text(inputs["value"]), inputs.get("title") or ""
    answer = await ctx.ui.request("show", {"title": title, "text": text}, timeout=3.0)
    if answer is None:
        argv = ["notify-send", "-a", "Serpantinum", "--", title or "Результат", text]
        res = await ctx.proc.run(argv, timeout=10)
        if res.rc != 0:
            _fail(res, "notify-send")
    return {}


async def ipc_call(ctx, target, fn, args=()):
    argv = [paths.serpantinum_bin(), "ipc", "call", target, fn] + [_ipc_arg(a) for a in args]
    return await shellapi.tool(ctx, argv, timeout=5)


def _ipc_arg(a):
    if isinstance(a, bool):
        return "true" if a else "false"
    return str(a)


async def ipc_execute(ctx, node, nd, inputs):
    ex = nd.executor
    args = [inputs[p.id] for p in nd.inputs if p.type != "exec" and p.id in inputs]
    res = await ipc_call(ctx, ex["target"], ex["fn"], args)
    if res.rc != 0:
        raise NodeError("Цель «%s» оболочки не отвечает: оболочка запущена и обновлена до этой версии?" % ex["target"])
    return {}


async def ipc_capture(ctx, nd):
    ex = nd.executor
    res = await ipc_call(ctx, ex["target"], nd.undo["capture"])
    if res.rc != 0:
        raise NodeError("Не удалось запомнить прежнее значение: цель «%s» не отвечает" % ex["target"])
    raw = res.out.strip()
    return {"value": raw}


async def ipc_restore(ctx, nd, value):
    raw = (value or {}).get("value", "")
    await ipc_call(ctx, nd.executor["target"], nd.undo["restore"], [raw])


from . import actions  # noqa: E402,F401  (registers the stage 9a executors)
from . import actions_b  # noqa: E402,F401  (stage 9b executors)
from . import actions_c  # noqa: E402,F401  (stage 9c: bar, close window, link, screenshot, VPN)
