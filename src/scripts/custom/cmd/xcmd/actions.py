"""Executors of stage 9a: shell / audio / media / window / file action nodes and the selection data nodes.
System side effects only go through shellapi.tool / shellapi.ipc (stub-able); undo = capture/restore pairs."""
import asyncio
import configparser
import glob
import json
import os
import re
import shlex
import shutil
import time
from urllib.parse import unquote, urlparse

from . import paths, shellapi as S
from .errors import NodeError
from .executors import REGISTRY, MAX_OUT
from .procs import clean_env
from .xlogshim import log as xlog


def act(name):
    """Register an executor (or undo capture/restore) with a uniform log line: op, node, params, duration, failure."""
    def deco(fn):
        async def wrapped(ctx, node, arg):
            t0 = time.monotonic()
            try:
                out = await fn(ctx, node, arg)
            except BaseException as e:
                xlog.warn("action failed", op=name, node=node.get("id"), err=str(e)[:200], ms=int((time.monotonic() - t0) * 1000))
                raise
            xlog.info("action", op=name, node=node.get("id"), params=json.dumps(arg, ensure_ascii=False, default=str)[:200],
                      ms=int((time.monotonic() - t0) * 1000))
            return out
        REGISTRY[name] = wrapped
        return fn
    return deco


def _clamp(v, lo, hi):
    return max(lo, min(hi, int(v)))


# ------------------------------------------------------------------ shell (xcmd IPC target, wallpaper target, scripts)
THEME_SCHEMES = {"tonal-spot", "content", "expressive", "fidelity", "fruit-salad", "monochrome", "neutral", "rainbow", "vibrant"}


@act("shell_theme")
async def shell_theme(ctx, node, inputs):
    spec = inputs["mode"]
    scheme = inputs.get("scheme") or "keep"
    if scheme != "keep":
        if scheme not in THEME_SCHEMES:
            raise NodeError("Неизвестная схема цветов «%s»" % scheme)
        spec += ":scheme-" + scheme
    await S.ipc(ctx, "xcmd", "setTheme", spec)
    return {}


@act("theme_capture")
async def theme_capture(ctx, node, inputs):
    return {"value": await S.ipc(ctx, "xcmd", "getTheme")}


@act("theme_restore")
async def theme_restore(ctx, node, value):
    if value and value.get("value"):
        await S.ipc(ctx, "xcmd", "setTheme", value["value"])


IMG_EXT = (".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".tif", ".tiff", ".avif", ".heic")


def _expand(p):
    return os.path.expanduser(str(p or "").strip())


@act("shell_wallpaper")
async def shell_wallpaper(ctx, node, inputs):
    p = _expand(inputs["path"])
    if os.path.isdir(p):
        pics = sorted(f for f in glob.glob(os.path.join(glob.escape(p), "*")) if f.lower().endswith(IMG_EXT) and os.path.isfile(f))
        if not pics:
            raise NodeError("В папке «%s» нет картинок для обоев" % p)
        import random
        p = random.choice(pics)
    elif not os.path.isfile(p):
        raise NodeError("Файл обоев не найден: %s" % p)
    await S.ipc(ctx, "wallpaper", "setWallpaper", "all", os.path.abspath(p), "fade")
    return {"chosen": os.path.abspath(p)}


@act("wallpaper_capture")
async def wallpaper_capture(ctx, node, inputs):
    return {"path": await S.ipc(ctx, "wallpaper", "getWallpaperPath", "")}


@act("wallpaper_restore")
async def wallpaper_restore(ctx, node, value):
    p = (value or {}).get("path") or ""
    if p and os.path.isfile(p):
        await S.ipc(ctx, "wallpaper", "setWallpaper", "all", p, "fade")


@act("shell_night_filter")
async def shell_night_filter(ctx, node, inputs):
    t = int(inputs.get("temperature") or 0)
    if 0 < t < 1000:
        raise NodeError("Температура ночного фильтра от 1000 до 10000 К (0 = как в настройках), а не %d" % t)
    if inputs["enabled"]:
        await S.ipc(ctx, "xcmd", "setNightFilter", "on:%d" % t if t else "on")
    else:
        await S.ipc(ctx, "xcmd", "setNightFilter", "off")
    return {}


@act("night_capture")
async def night_capture(ctx, node, inputs):
    return {"value": await S.ipc(ctx, "xcmd", "getNightFilter")}


@act("night_restore")
async def night_restore(ctx, node, value):
    if value and value.get("value"):
        await S.ipc(ctx, "xcmd", "setNightFilter", value["value"])


@act("shell_brightness")
async def shell_brightness(ctx, node, inputs):
    if inputs.get("mode") == "delta":
        target = await S.brightness_get(ctx) + int(inputs.get("delta") or 0)
    else:
        target = int(inputs["percent"])
    target = _clamp(target, 1, 100)
    await S.brightness_set(ctx, target)
    return {"result": target}


@act("brightness_capture")
async def brightness_capture(ctx, node, inputs):
    return {"percent": await S.brightness_get(ctx)}


@act("brightness_restore")
async def brightness_restore(ctx, node, value):
    if value and value.get("percent"):
        await S.brightness_set(ctx, _clamp(value["percent"], 1, 100))


# ------------------------------------------------------------------ audio (wpctl / pactl, as the shell's volume script does)
SINK, SRC = "@DEFAULT_AUDIO_SINK@", "@DEFAULT_AUDIO_SOURCE@"


async def _volume(ctx, target, what):
    res = await S.tool(ctx, ["wpctl", "get-volume", target], timeout=5)
    m = re.match(r"Volume:\s*([0-9.]+)(.*)", res.out.strip())
    if res.rc != 0 or not m:
        raise NodeError("%s не найден: PipeWire не отвечает или устройства нет" % what)
    return int(round(float(m.group(1)) * 100)), "MUTED" in m.group(2)


async def _wpctl(ctx, *args):
    res = await S.tool(ctx, ["wpctl"] + list(args), timeout=5)
    if res.rc != 0:
        raise NodeError("wpctl %s: код выхода %s" % (args[0], res.rc))


@act("audio_volume")
async def audio_volume(ctx, node, inputs):
    mode = inputs.get("mode", "set")
    await _volume(ctx, SINK, "Выход звука")                      # a clear error before anything is changed
    if mode == "set":
        await _wpctl(ctx, "set-volume", "-l", "1.0", SINK, "%d%%" % _clamp(inputs["volume"], 0, 100))
    elif mode == "change":
        d = _clamp(inputs.get("delta") or 0, -100, 100)
        if d:
            await _wpctl(ctx, "set-volume", "-l", "1.0", SINK, "%d%%%s" % (abs(d), "+" if d > 0 else "-"))
    elif mode in ("mute", "unmute", "toggle_mute"):
        await _wpctl(ctx, "set-mute", SINK, {"mute": "1", "unmute": "0", "toggle_mute": "toggle"}[mode])
    level, muted = await _volume(ctx, SINK, "Выход звука")
    return {"level": level, "muted": muted}


@act("volume_capture")
async def volume_capture(ctx, node, inputs):
    level, muted = await _volume(ctx, SINK, "Выход звука")
    return {"level": level, "muted": muted}


@act("volume_restore")
async def volume_restore(ctx, node, value):
    if value:
        await _wpctl(ctx, "set-volume", "-l", "1.0", SINK, "%d%%" % _clamp(value.get("level", 40), 0, 100))
        await _wpctl(ctx, "set-mute", SINK, "1" if value.get("muted") else "0")


async def _sinks(ctx):
    """[(name, description)] of the audio outputs."""
    res = await S.tool(ctx, ["pactl", "-f", "json", "list", "sinks"], timeout=8)
    if res.rc == 0:
        try:
            return [(s["name"], s.get("description") or "") for s in json.loads(res.out)]
        except (ValueError, KeyError, TypeError):
            pass
    res = await S.tool(ctx, ["pactl", "list", "short", "sinks"], timeout=8)
    if res.rc != 0:
        raise NodeError("Не удалось получить список устройств звука (pactl)")
    return [(l.split("\t")[1], "") for l in res.out.splitlines() if l.count("\t") >= 1]


@act("audio_output")
async def audio_output(ctx, node, inputs):
    q = str(inputs["device"]).strip().lower()
    sinks = await _sinks(ctx)
    hit = (next((s for s in sinks if s[0].lower() == q), None) or next((s for s in sinks if s[1].lower() == q), None)
           or next((s for s in sinks if q and q in s[1].lower()), None) or next((s for s in sinks if q and q in s[0].lower()), None))
    if hit is None:
        raise NodeError("Устройство вывода «%s» не найдено. Доступные: %s" % (inputs["device"], ", ".join(s[1] or s[0] for s in sinks) or "нет"))
    res = await S.tool(ctx, ["pactl", "set-default-sink", hit[0]], timeout=8)
    if res.rc != 0:
        raise NodeError("Не удалось переключить звук на «%s»: код выхода %s" % (hit[1] or hit[0], res.rc))
    return {"name": hit[0]}


@act("output_capture")
async def output_capture(ctx, node, inputs):
    res = await S.tool(ctx, ["pactl", "get-default-sink"], timeout=5)
    return {"name": res.out.strip() if res.rc == 0 else ""}


@act("output_restore")
async def output_restore(ctx, node, value):
    name = (value or {}).get("name") or ""
    if name:
        await S.tool(ctx, ["pactl", "set-default-sink", name], timeout=8)


@act("audio_mic")
async def audio_mic(ctx, node, inputs):
    _, was = await _volume(ctx, SRC, "Микрофон")
    want = (not was) if inputs.get("mode") == "toggle" else bool(inputs["muted"])
    await _wpctl(ctx, "set-mute", SRC, "1" if want else "0")
    return {"is_muted": want}


@act("mic_capture")
async def mic_capture(ctx, node, inputs):
    _, muted = await _volume(ctx, SRC, "Микрофон")
    return {"muted": muted}


@act("mic_restore")
async def mic_restore(ctx, node, value):
    if value and "muted" in value:
        await _wpctl(ctx, "set-mute", SRC, "1" if value["muted"] else "0")


# ------------------------------------------------------------------ media (MPRIS through playerctl)
PLAYERCTL = {"play": "play", "pause": "pause", "toggle": "play-pause", "next": "next", "previous": "previous", "stop": "stop"}


def _pl(player, *args):
    return ["playerctl"] + (["-p", player] if player else []) + list(args)


async def _media_state(ctx, player):
    res = await S.tool(ctx, _pl(player, "status"), timeout=5)
    return res.out.strip().lower() if res.rc == 0 and res.out.strip() else "none"


@act("media_control")
async def media_control(ctx, node, inputs):
    player = (inputs.get("player") or "").strip()
    res = await S.tool(ctx, _pl(player, PLAYERCTL[inputs["command"]]), timeout=8)
    if res.rc != 0 and "No player" not in (res.err + res.out) and "No players" not in (res.err + res.out):
        raise NodeError("playerctl: код выхода %s%s" % (res.rc, (" — " + res.err.strip().splitlines()[-1]) if res.err.strip() else ""))
    state = await _media_state(ctx, player)
    title = ""
    if state != "none":
        t = await S.tool(ctx, _pl(player, "metadata", "title"), timeout=5)
        title = t.out.strip() if t.rc == 0 else ""
    return {"state": state, "title": title}


@act("media_capture")
async def media_capture(ctx, node, inputs):
    if inputs.get("command") in ("next", "previous"):
        return {"state": "none", "player": ""}
    p = (inputs.get("player") or "").strip()
    return {"state": await _media_state(ctx, p), "player": p}


@act("media_restore")
async def media_restore(ctx, node, value):
    st, p = (value or {}).get("state"), (value or {}).get("player") or ""
    if st in ("playing", "paused") and await _media_state(ctx, p) != st:
        await S.tool(ctx, _pl(p, "play" if st == "playing" else "pause"), timeout=8)


# ------------------------------------------------------------------ windows (hyprctl)
async def _hypr_json(ctx, what):
    res = await S.tool(ctx, ["hyprctl", what, "-j"], timeout=5)
    try:
        if res.rc != 0:
            raise ValueError(res.err)
        return json.loads(res.out)
    except ValueError:
        raise NodeError("Hyprland не отвечает (hyprctl %s): оболочка запущена не под Hyprland?" % what)


async def _dispatch(ctx, *args):
    res = await S.tool(ctx, ["hyprctl", "dispatch"] + [str(a) for a in args], timeout=5)
    if res.rc != 0 or (res.out.strip() and not res.out.strip().startswith("ok")):
        raise NodeError("Hyprland отказал в команде «%s»: %s" % (args[0], (res.out or res.err).strip()[:120] or "код %s" % res.rc))


def _desktop_exec(app):
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", app):
        return None
    name = app if app.endswith(".desktop") else app + ".desktop"
    home = os.path.expanduser("~")
    dirs = [os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")] + \
           [d for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]
    for d in dirs:
        p = os.path.join(d, "applications", name)
        if os.path.isfile(p):
            cp = configparser.RawConfigParser(interpolation=None, strict=False)
            try:
                cp.read(p, encoding="utf-8")
                line = cp.get("Desktop Entry", "Exec")
            except (configparser.Error, OSError, UnicodeDecodeError):
                continue
            return re.sub(r"\s+", " ", re.sub(r"%[fFuUdDnNickvm]", "", line.replace("%%", "\0"))).replace("\0", "%").strip()
    return None


def _which(cmd):
    if "/" in cmd:
        return os.path.isfile(cmd) and os.access(cmd, os.X_OK)
    return shutil.which(cmd, path=clean_env().get("PATH")) is not None


@act("window_open_app")
async def window_open_app(ctx, node, inputs):
    app = str(inputs["app"]).strip()
    if not app:
        raise NodeError("Не указано приложение")
    command = _desktop_exec(app)
    if command is None:
        try:
            first = shlex.split(app)[0]
        except (ValueError, IndexError):
            raise NodeError("Не удалось разобрать команду «%s»" % app)
        if not _which(first):
            raise NodeError("Приложение «%s» не найдено: нет ни ярлыка .desktop с таким именем, ни команды в PATH" % app)
        command = app
    ws = _clamp(inputs.get("workspace") or 1, 1, 20)
    wait = _clamp(inputs.get("wait") or 0, 0, 60)
    before = {c["address"] for c in await _hypr_json(ctx, "clients")} if wait else set()
    await _dispatch(ctx, "exec", "[workspace %d silent] %s" % (ws, command))
    addr = ""
    waited = 0.0
    while wait:
        await ctx.clock.sleep(0.5)
        waited += 0.5
        new = [c for c in await _hypr_json(ctx, "clients") if c["address"] not in before]
        if new:
            addr = new[0]["address"]
            break
        if waited >= wait:
            raise NodeError("Окно приложения «%s» не появилось за %d с" % (app, wait))
    return {"address": addr}


def _split_apps(text):
    return [a.strip().lower() for a in str(text or "").split(",") if a.strip()]


def _match(cls, wanted):
    cls = (cls or "").lower()
    return any(w == cls or w in cls for w in wanted)


async def _windows(ctx, wanted):
    return [c for c in await _hypr_json(ctx, "clients")
            if c.get("mapped", True) and not c.get("hidden") and c.get("workspace", {}).get("id", 0) > 0
            and (not wanted or _match(c.get("class"), wanted))]


@act("window_arrange")
async def window_arrange(ctx, node, inputs):
    layout = inputs.get("layout", "by_monitor")
    entries = _split_apps(inputs.get("apps"))
    ws_map = {}
    if layout == "workspaces":
        for e in entries:
            cls, _, n = e.rpartition(":")
            if not cls or not n.strip().isdigit():
                raise NodeError("Для схемы «workspaces» нужен список «приложение:номер», а не «%s»" % e)
            ws_map[cls.strip()] = _clamp(n, 1, 20)
        wanted = list(ws_map)
    else:
        wanted = entries
    wins = await _windows(ctx, wanted)
    moved = 0
    if layout in ("by_monitor", "tile", "stack"):
        target = _clamp(inputs.get("workspace") or 0, 0, 20)
        if layout == "by_monitor":
            mons = await _hypr_json(ctx, "monitors")
            name = (inputs.get("monitor") or "").strip()
            mon = next((m for m in mons if m.get("name") == name), None) if name else next((m for m in mons if m.get("focused")), mons[0] if mons else None)
            if mon is None:
                raise NodeError("Монитор «%s» не найден. Подключены: %s" % (name, ", ".join(m.get("name", "?") for m in mons) or "нет"))
            target = target or int(mon["activeWorkspace"]["id"])
        elif not target:
            mons = await _hypr_json(ctx, "monitors")
            mon = next((m for m in mons if m.get("focused")), mons[0] if mons else None)
            target = int(mon["activeWorkspace"]["id"]) if mon else 1
        for w in wins:
            await _dispatch(ctx, "movetoworkspacesilent", "%d,address:%s" % (target, w["address"]))
            moved += 1
        if layout == "tile" and wins:
            for w in wins:
                if w.get("floating"):
                    await _dispatch(ctx, "settiled", "address:" + w["address"])
            if len(wins) >= 2:
                active = (await _hypr_json(ctx, "activewindow")) or {}
                await _dispatch(ctx, "focuswindow", "address:" + wins[0]["address"])
                await _dispatch(ctx, "movewindow", "l")
                await _dispatch(ctx, "focuswindow", "address:" + wins[1]["address"])
                await _dispatch(ctx, "movewindow", "r")
                if active.get("address"):
                    await _dispatch(ctx, "focuswindow", "address:" + active["address"])
    else:
        for w in wins:
            for cls, n in ws_map.items():
                if _match(w.get("class"), [cls]):
                    await _dispatch(ctx, "movetoworkspacesilent", "%d,address:%s" % (n, w["address"]))
                    moved += 1
                    break
    return {"moved": moved}


@act("arrange_capture")
async def arrange_capture(ctx, node, inputs):
    wanted = _split_apps(inputs.get("apps")) if inputs.get("layout") != "workspaces" else \
        [e.rpartition(":")[0].strip() for e in _split_apps(inputs.get("apps"))]
    return {"windows": {w["address"]: w["workspace"]["id"] for w in await _windows(ctx, wanted)}}


@act("arrange_restore")
async def arrange_restore(ctx, node, value):
    alive = {c["address"] for c in await _hypr_json(ctx, "clients")}
    for addr, ws in ((value or {}).get("windows") or {}).items():
        if addr in alive:
            await _dispatch(ctx, "movetoworkspacesilent", "%s,address:%s" % (ws, addr))


# ------------------------------------------------------------------ files
def _home():
    return os.path.realpath(paths._home())


def _inside_home(p):
    h = _home()
    r = os.path.realpath(p)
    return r != h and (r + os.sep).startswith(h + os.sep)


def _safe(ctx, node, p, what):
    """Safe-path rule: everything under $HOME; outside it only with the literal «allow_outside_home» AND the approved right file.write.any."""
    if _inside_home(p):
        return
    approved = "file.write.any" in ((getattr(ctx, "cmd", None) or {}).get("approved_capabilities") or [])
    if (node.get("props") or {}).get("allow_outside_home") and approved:
        if os.path.realpath(p) in ("/", _home()):
            raise NodeError("%s: эту папку трогать нельзя" % what)
        return
    raise NodeError("%s «%s» лежит вне домашней папки. Включите у узла «Разрешить вне домашней папки» и подтвердите право file.write.any" % (what, p))


def _unique(directory, name):
    if not os.path.lexists(os.path.join(directory, name)):
        return name
    stem, ext = os.path.splitext(name)
    if name.startswith(".") and not ext:
        stem, ext = name, ""
    i = 1
    while os.path.lexists(os.path.join(directory, "%s (%d)%s" % (stem, i, ext))):
        i += 1
    return "%s (%d)%s" % (stem, i, ext)


def _plan_move(ctx, node, inputs):
    src = os.path.abspath(_expand(inputs["path"]))
    folder = os.path.abspath(_expand(inputs["folder"]))
    if not os.path.lexists(src):
        raise NodeError("Файл не найден: %s" % src)
    _safe(ctx, node, src, "Файл")
    _safe(ctx, node, folder, "Папка")
    if os.path.isdir(src) and (os.path.realpath(folder) + os.sep).startswith(os.path.realpath(src) + os.sep):
        raise NodeError("Нельзя переместить папку «%s» внутрь неё самой" % src)
    mode = inputs.get("mode", "move")
    plan = {"src": src, "mode": mode, "dst": "", "skip": False}
    same_dir = os.path.realpath(os.path.dirname(src)) == os.path.realpath(folder)
    if same_dir and mode == "move":
        plan.update(dst=src, skip=True)
        return plan, folder
    name = os.path.basename(src)
    if os.path.lexists(os.path.join(folder, name)):
        policy = inputs.get("on_exists", "rename")
        if policy == "skip":
            plan.update(skip=True)
            return plan, folder
        if policy == "fail":
            raise NodeError("В папке «%s» уже есть «%s»" % (folder, name))
        name = _unique(folder, name)
    plan["dst"] = os.path.join(folder, name)
    return plan, folder


@act("file_move")
async def file_move(ctx, node, inputs):
    plan, folder = _plan_move(ctx, node, inputs)
    if plan["skip"]:
        return {"new_path": plan["dst"]}
    if not os.path.isdir(folder):
        if not inputs.get("create_folder", True):
            raise NodeError("Папки «%s» нет, а создание папки выключено" % folder)
        os.makedirs(folder, exist_ok=True)
    try:
        if plan["mode"] == "copy":
            (shutil.copytree if os.path.isdir(plan["src"]) and not os.path.islink(plan["src"]) else shutil.copy2)(plan["src"], plan["dst"])
        else:
            shutil.move(plan["src"], plan["dst"])
    except OSError as e:
        raise NodeError("Не удалось %s файл: %s" % ("скопировать" if plan["mode"] == "copy" else "переместить", e.strerror or e))
    xlog.info("file op", mode=plan["mode"], src=plan["src"], dst=plan["dst"])
    return {"new_path": plan["dst"]}


@act("move_capture")
async def move_capture(ctx, node, inputs):
    return _plan_move(ctx, node, inputs)[0]


@act("move_restore")
async def move_restore(ctx, node, value):
    v = value or {}
    if v.get("mode") != "move" or v.get("skip") or not v.get("dst"):
        return
    src, dst = v["src"], v["dst"]
    if os.path.lexists(dst) and not os.path.lexists(src):
        _safe(ctx, node, src, "Файл")
        os.makedirs(os.path.dirname(src), exist_ok=True)
        shutil.move(dst, src)
        xlog.info("file op", mode="undo-move", src=dst, dst=src)


FORMATS = {"webp": ".webp", "png": ".png", "jpg": ".jpg"}


@act("file_convert_image")
async def file_convert_image(ctx, node, inputs):
    srcs = ([inputs["path"]] if (inputs.get("path") or "").strip() else []) + [p for p in (inputs.get("paths") or []) if str(p).strip()]
    if not srcs:
        raise NodeError("Не указано, какие картинки конвертировать")
    ext = FORMATS[inputs.get("format", "webp")]
    width, quality = _clamp(inputs.get("max_width") or 1600, 16, 16000), _clamp(inputs.get("quality") or 85, 1, 100)
    out_dir = os.path.abspath(_expand(inputs.get("folder"))) if (inputs.get("folder") or "").strip() else ""
    done, failed = [], []
    for raw in srcs:
        src = os.path.abspath(_expand(raw))
        try:
            if not os.path.isfile(src):
                raise NodeError("файл не найден")
            if not src.lower().endswith(IMG_EXT):
                raise NodeError("это не картинка")
            d = out_dir or os.path.dirname(src)
            _safe(ctx, node, d, "Папка результата")
            os.makedirs(d, exist_ok=True)
            stem = os.path.splitext(os.path.basename(src))[0]
            name = stem + ext
            if os.path.join(d, name) == src:
                name = stem + "-converted" + ext
            dst = os.path.join(d, _unique(d, name))
            res = await S.tool(ctx, ["magick", src + "[0]", "-auto-orient", "-strip", "-resize", "%dx>" % width, "-quality", str(quality), dst], timeout=120)
            if res.rc != 0:
                raise NodeError("ImageMagick вернул код %s%s" % (res.rc, (": " + res.err.strip().splitlines()[-1][:100]) if res.err.strip() else ""))
            done.append(dst)
        except NodeError as e:
            failed.append("%s: %s" % (os.path.basename(src), e))
    if failed:
        raise NodeError("Не удалось конвертировать %d из %d: %s" % (len(failed), len(srcs), "; ".join(failed[:3])))
    return {"new_path": done[-1], "new_paths": done}


# ------------------------------------------------------------------ selection data nodes (pure, read-only)
@act("selected_text")
async def selected_text(ctx, node, inputs):
    for source, argv in (("primary", ["wl-paste", "--primary", "--no-newline"]), ("clipboard", ["wl-paste", "--no-newline"])):
        res = await S.tool(ctx, argv, timeout=5)
        if res.rc == 0 and res.out.strip():
            return {"text": res.out[:MAX_OUT], "source": source}
    return {"text": "", "source": "none"}


def _parse_uris(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line in ("copy", "cut"):
            continue
        if line.startswith("file://"):
            line = unquote(urlparse(line).path)
        if os.path.isabs(line) and os.path.exists(line):
            out.append(line)
    return out


@act("selected_files")
async def selected_files(ctx, node, inputs):
    arg = (inputs.get("arg") or "").strip() or str((getattr(ctx, "event_data", None) or {}).get("arg") or "").strip()
    if arg:
        files = _parse_uris(arg)
    else:
        files = []
        types = await S.tool(ctx, ["wl-paste", "--list-types"], timeout=5)
        have = types.out.split() if types.rc == 0 else []
        for mime in ("text/uri-list", "x-special/gnome-copied-files", "text/plain"):
            if mime in have or (mime == "text/plain" and not have):
                res = await S.tool(ctx, ["wl-paste", "--no-newline", "--type", mime], timeout=5)
                files = _parse_uris(res.out) if res.rc == 0 else []
                if files:
                    break
    seen, uniq = set(), []
    for f in files:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    return {"files": uniq, "count": len(uniq)}
