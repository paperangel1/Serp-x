"""Read-only view data for the Commands window (QML): one JSON document per call.

`ui_list` feeds the list screen, `ui_get` a graph viewer (nodes with resolved schema info, pin rows, geometry,
auto-layout when positions are missing), `ui_schema` the node catalogue (help / palette in later stages).
All geometry constants are shared with src/quickshell/custom/cmd/CK.qml (keep them in sync).
"""
import glob
import os

from . import paths, pins, ptypes, service
from .model import is_risky_cap, approved_ok, compute_capabilities, policy_of
from .runlog import RunLog
from .util import read_json
from .schema import FN_INPUT, FN_OUTPUT
from .validate import validate

NODE_W = 290
HDR = 32
ROW = 26
PAD_TOP = 6
FOOT = 12
NOTE_H = 20
COL_GAP = 90
ROW_GAP = 36
X0 = 40
Y0 = 40

CAP_RU = {
    "notify.show": "уведомления", "clipboard.write": "запись в буфер", "clipboard.read": "чтение буфера",
    "exec.script": "запуск команд", "shell.control": "управление оболочкой", "ui.show": "окна оболочки",
    "audio.control": "звук", "media.control": "медиа", "screen.control": "экран",
    "net.http": "сеть", "ssh.server": "серверы по SSH", "fs.write": "запись файлов", "vpn.control": "управление VPN",
    "trigger.time": "расписание", "trigger.windows": "события окон и мониторов", "trigger.session": "сеанс и бездействие",
    "shell.dnd": "режим «Не беспокоить»", "shell.theme": "тема оболочки", "shell.wallpaper": "обои",
    "audio.volume": "громкость", "audio.output": "устройство вывода звука", "audio.mic": "микрофон",
    "window.manage": "запуск и перемещение окон", "file.write": "запись файлов в домашней папке",
    "file.write.any": "запись файлов ВНЕ домашней папки", "image.convert": "конвертация картинок", "read.selection": "чтение выделения и буфера",
    "trigger.audio": "события наушников", "trigger.clipboard": "слежение за буфером обмена", "trigger.folder": "слежение за папкой",
    "trigger.servers": "события серверов", "trigger.network": "события Wi-Fi", "trigger.usb": "события USB",
    "trigger.notifications": "чтение уведомлений", "net.gemini": "отправка текста в Gemini (Google)", "servers.run": "команды на серверах",
    "servers.run.typed": "самые опасные команды на серверах",
    "shell.bar": "показ и скрытие панели", "window.close": "закрытие окон", "link.open": "открытие ссылок в браузере",
    "screen.capture": "снимки экрана", "trigger.bluetooth": "события Bluetooth", "trigger.vpn": "события VPN",
}
CAP_EN = {
    "notify.show": "notifications", "clipboard.write": "clipboard write", "clipboard.read": "clipboard read",
    "exec.script": "run commands", "shell.control": "shell control", "ui.show": "shell windows",
    "audio.control": "sound", "media.control": "media", "screen.control": "screen",
    "net.http": "network", "ssh.server": "servers over SSH", "fs.write": "file writes", "vpn.control": "VPN control",
    "trigger.time": "schedule", "trigger.windows": "window and monitor events", "trigger.session": "session and idle",
    "shell.dnd": "do-not-disturb mode", "shell.theme": "shell theme", "shell.wallpaper": "wallpaper",
    "audio.volume": "volume", "audio.output": "audio output device", "audio.mic": "microphone",
    "window.manage": "start and move windows", "file.write": "write files in the home folder",
    "file.write.any": "write files OUTSIDE the home folder", "image.convert": "image conversion", "read.selection": "read selection and clipboard",
    "trigger.audio": "headphone events", "trigger.clipboard": "watch the clipboard", "trigger.folder": "watch a folder",
    "trigger.servers": "server events", "trigger.network": "Wi-Fi events", "trigger.usb": "USB events",
    "trigger.notifications": "read notifications", "net.gemini": "send text to Gemini (Google)", "servers.run": "commands on servers",
    "servers.run.typed": "the most dangerous server commands",
    "shell.bar": "show and hide the bar", "window.close": "close windows", "link.open": "open links in the browser",
    "screen.capture": "screenshots", "trigger.bluetooth": "Bluetooth events", "trigger.vpn": "VPN events",
}
# Explicit permission texts shown in the approve dialog for rights that expose private data or send it out.
CAP_WARN_RU = {
    "trigger.clipboard": "Пока команда включена, оболочка читает всё, что вы копируете (ссылки, цвета, телефоны). Содержимое получает только эта команда и нигде не сохраняется.",
    "trigger.notifications": "Пока команда включена, она видит заголовки и текст ВСЕХ уведомлений от приложений. Текст нигде не сохраняется, в журнал идёт только имя приложения.",
    "net.gemini": "Выбранный текст отправляется в сервис Google (Gemini) через ваш прокси или туннель.",
    "net.http": "Команда может отправлять данные по сети на указанные адреса.",
    "servers.run": "Команда может запускать команды на ваших серверах (опасные спросят подтверждение).",
    "servers.run.typed": "Команде разрешены самые опасные действия на серверах (перезагрузка), всё равно с подтверждением.",
    "file.write.any": "Команда может менять файлы за пределами домашней папки.",
    "vpn.control": "Команда может ВКЛЮЧАТЬ, ВЫКЛЮЧАТЬ и переключать ваш VPN без вопросов, в том числе сама, по расписанию или событию. Выключенный VPN открывает трафик напрямую. Happ команда не трогает и не включит наш VPN, пока Happ работает.",
    "window.close": "Команда может закрывать окна ваших программ (несохранённое приложение может потерять).",
    "link.open": "Команда может открывать в браузере ссылки http, https и mailto (другие схемы запрещены).",
    "screen.capture": "Команда может снимать экран и сохранять снимки в «Изображения/Screenshots»; на снимке может оказаться всё, что видно на экране.",
    "trigger.bluetooth": "Пока команда включена, она видит, какие Bluetooth-устройства подключаются и отключаются (имена и адреса нигде не сохраняются).",
}
CAP_WARN_EN = {
    "trigger.clipboard": "While the command is enabled the shell reads everything you copy (links, colours, phone numbers). Only this command gets the content and it is never stored.",
    "trigger.notifications": "While the command is enabled it sees the titles and text of ALL application notifications. The text is never stored; only the app name is logged.",
    "net.gemini": "The selected text is sent to a Google service (Gemini) through your proxy or tunnel.",
    "net.http": "The command can send data over the network to the given addresses.",
    "servers.run": "The command can run commands on your servers (dangerous ones ask for confirmation).",
    "servers.run.typed": "The command may run the most dangerous server actions (reboot), still with confirmation.",
    "file.write.any": "The command can change files outside the home folder.",
    "vpn.control": "The command can TURN ON, TURN OFF and switch your VPN without asking, including by itself on a schedule or an event. With the VPN off traffic goes directly. The command never touches Happ and will not turn our VPN on while Happ is running.",
    "window.close": "The command can close windows of your programs (an app may lose unsaved work).",
    "link.open": "The command can open http, https and mailto links in the browser (other schemes are refused).",
    "screen.capture": "The command can take screenshots and save them in Pictures/Screenshots; a shot may contain everything visible on the screen.",
    "trigger.bluetooth": "While the command is enabled it sees which Bluetooth devices connect and disconnect (names and addresses are never stored).",
}
UNDO_NOTE = {"ru": "откат по завершении", "en": "restored when it ends"}
FN_NOTE = {"ru": "функция · %d узл. внутри · открыть ↗", "en": "function · %d nodes inside · open ↗"}
EXEC_IN = {"ru": "", "en": ""}
EXEC_OUT = {"ru": "Готово", "en": "Done"}


def _tr(d, lang, fallback=""):
    if isinstance(d, dict):
        return d.get(lang) or d.get("ru") or d.get("en") or fallback
    return d if isinstance(d, str) else fallback


def base_type(t, generics=None):
    """Pin type for colours: list<…> -> list, generic T -> its bound (any)."""
    if t in ("T", "U") or (generics and t in generics):
        return (generics or {}).get(t, "any")
    if ptypes.is_list(t):
        return "list"
    return t


def fmt_value(v, t, lang="ru"):
    if v is None:
        return None
    if isinstance(v, bool):
        return ("да" if v else "нет") if lang == "ru" else ("yes" if v else "no")
    if isinstance(v, list):
        return ("список (%d)" if lang == "ru" else "list (%d)") % len(v)
    if isinstance(v, dict):
        return "данные" if lang == "ru" else "data"
    s = str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)
    if s == "":
        return None
    return s if len(s) <= 18 else s[:17] + "…"


def _pin_row(pin, nd, props, linked, lang, is_input):
    label = _tr(pin.label, lang, "")
    if pin.type == "exec" and not label:
        label = EXEC_IN[lang] if is_input else EXEC_OUT[lang]
    row = {"id": pin.id, "n": label, "t": base_type(pin.type, nd.d.get("generics")), "full": pin.type,
           "linked": linked, "required": pin.required}
    if is_input and pin.type != "exec" and not linked:
        if pin.id in props:
            val = props[pin.id]
        elif pin.has_default:
            val = pin.default
        else:
            val = None
        shown = fmt_value(val, pin.type, lang)
        labels = (pin.d.get("choice_labels") or {})
        labels = labels.get(lang) or labels.get("ru") or {}
        if shown is not None and isinstance(val, str) and val in labels:
            shown = labels[val]
        if shown is not None:
            row["v"] = shown
        elif pin.required:
            row["missing"] = True
    return row


def _node_note(nd, props, lang):
    if nd.d.get("function"):
        return FN_NOTE[lang] % nd.d["function"]["nodes"]
    if nd.undo and props.get("restore", nd.undo.get("default", "end")) not in ("never", "off"):
        return UNDO_NOTE[lang]
    return ""


def node_height(n_in, n_out, note):
    return HDR + PAD_TOP + max(n_in, n_out) * ROW + FOOT + (NOTE_H if note else 0)


CHAR_TITLE = 7.4      # px per character of the bold 12px monospace title
CHAR_ROW = 6.7        # px per character of the 11px monospace row text
W_MIN, W_MAX = 230, 340


def node_width(base):
    """Width that fits the title and the widest row (monospace metrics); rounded up to 10 px."""
    w = 36 + len(base["title"]) * CHAR_TITLE + 30
    rows = max(len(base["ins"]), len(base["outs"]))
    for i in range(rows):
        left = right = 0
        if i < len(base["ins"]):
            p = base["ins"][i]
            left = 14 + len(p["n"]) * CHAR_ROW + ((8 + max(34, len(p["v"]) * CHAR_ROW + 14)) if p.get("v") else 0)
        if i < len(base["outs"]):
            right = len(base["outs"][i]["n"]) * CHAR_ROW + 16
        w = max(w, left + right + 36)
    if base.get("note"):
        w = max(w, 28 + len(base["note"]) * 6.2 + 14)
    return int(min(W_MAX, max(W_MIN, -(-w // 10) * 10)))


def build_nodes(cmd, sch, lang):
    wires = cmd.get("wires", [])
    lin, lout = set(), set()
    for w in wires:
        lout.add((w["from"][0], w["from"][1]))
        lin.add((w["to"][0], w["to"][1]))
    out = []
    for n in cmd.get("nodes", []):
        nd, why = sch.get(n.get("type", ""))
        props = n.get("props") or {}
        pos = n.get("pos")
        base = {"id": n["id"], "type": n.get("type", ""), "w": NODE_W,
                "has_pos": isinstance(pos, (list, tuple)) and len(pos) == 2}
        if base["has_pos"]:
            base["x"], base["y"] = float(pos[0]), float(pos[1])
        if nd is None:
            ins = sorted({w["to"][1] for w in wires if w["to"][0] == n["id"]})
            outs = sorted({w["from"][1] for w in wires if w["from"][0] == n["id"]})
            base.update(title=n.get("type", "?"), icon="unknown", cat="unknown", unknown=True, note="",
                        ins=[{"id": i, "n": i, "t": "any", "full": "any", "linked": True} for i in ins],
                        outs=[{"id": o, "n": o, "t": "any", "full": "any", "linked": True} for o in outs])
        else:
            note = _node_note(nd, props, lang)
            base.update(title=_tr(nd.name, lang, nd.id), icon=nd.icon, cat=nd.category, unknown=False, note=note,
                        deferred=nd.stage == "deferred" or nd.planned,
                        ins=[_pin_row(p, nd, props, (n["id"], p.id) in lin, lang, True) for p in nd.inputs],
                        outs=[_pin_row(p, nd, props, (n["id"], p.id) in lout, lang, False) for p in nd.outputs])
        base["h"] = node_height(len(base["ins"]), len(base["outs"]), bool(base["note"]))
        base["w"] = node_width(base)
        out.append(base)
    return out


def auto_layout(nodes, wires):
    """Layered left->right layout: column = longest path from the sources, rows ordered by the barycentre of the
    predecessors; execution-chain nodes first, pure data nodes below. Deterministic."""
    ids = [n["id"] for n in nodes]
    preds = {i: [] for i in ids}
    succs = {i: [] for i in ids}
    for w in wires:
        a, b = w["from"][0], w["to"][0]
        if a in preds and b in preds and a != b:
            preds[b].append(a)
            succs[a].append(b)
    depth = {}
    state = {}

    def visit(i):
        if i in depth:
            return depth[i]
        if state.get(i) == 1:                      # cycle: break it
            return 0
        state[i] = 1
        d = 0
        for p in preds[i]:
            d = max(d, visit(p) + 1)
        state[i] = 2
        depth[i] = d
        return d

    for i in ids:
        visit(i)
    by_id = {n["id"]: n for n in nodes}
    exec_nodes = set()
    for w in wires:
        for nid, pid in ((w["from"][0], w["from"][1]), (w["to"][0], w["to"][1])):
            n = by_id.get(nid)
            if n:
                for p in n["ins"] + n["outs"]:
                    if p["id"] == pid and p["t"] == "exec":
                        exec_nodes.add(nid)
    cols = {}
    for i in ids:
        cols.setdefault(depth[i], []).append(i)
    ypos = {}
    colx = {}
    x = X0
    for d in sorted(cols):
        colx[d] = x
        x += max(by_id[i]["w"] for i in cols[d]) + COL_GAP
    for d in sorted(cols):
        def key(i):
            ps = [ypos[p] for p in preds[i] if p in ypos]
            bary = sum(ps) / len(ps) if ps else 0.0
            return (0 if i in exec_nodes else 1, bary, ids.index(i))
        y = Y0
        for i in sorted(cols[d], key=key):
            n = by_id[i]
            if not n["has_pos"]:
                n["x"] = colx[d]
                n["y"] = y
            ypos[i] = n["y"]
            y = max(y, n["y"]) + n["h"] + ROW_GAP
    return nodes


def bounds(nodes, comments):
    xs0 = [n["x"] for n in nodes] + [c["x"] for c in comments]
    ys0 = [n["y"] for n in nodes] + [c["y"] for c in comments]
    xs1 = [n["x"] + n["w"] for n in nodes] + [c["x"] + c["w"] for c in comments]
    ys1 = [n["y"] + n["h"] for n in nodes] + [c["y"] + c["h"] for c in comments]
    if not xs0:
        return {"x": 0, "y": 0, "w": 0, "h": 0}
    return {"x": min(xs0), "y": min(ys0), "w": max(xs1) - min(xs0), "h": max(ys1) - min(ys0)}


def command_kind(cmd, sch):
    events = [n for n in cmd.get("nodes", []) if n.get("type", "").startswith("event.")]
    return "manual" if events and all(n["type"].startswith("event.manual") for n in events) else ("auto" if events else "manual")


def event_titles(cmd, sch, lang):
    out = []
    for n in cmd.get("nodes", []):
        nd, _ = sch.get(n.get("type", ""))
        if nd and nd.category == "event" and not n["type"].startswith("event.manual"):
            out.append(_tr(nd.name, lang, nd.id))
    return out


def help_for(types, sch, lang):
    out = {}
    for t in types:
        nd, _ = sch.get(t)
        if nd is None:
            continue
        out[t] = node_help(nd, lang)
    return out


def node_help(nd, lang):
    def pins(ps, is_input):
        res = []
        for p in ps:
            lab = _tr(p.label, lang, "") or (EXEC_IN[lang] if p.type == "exec" and is_input else (EXEC_OUT[lang] if p.type == "exec" else p.id))
            if p.type == "exec" and is_input and not _tr(p.label, lang, ""):
                lab = "Выполнить" if lang == "ru" else "Run"
            res.append({"id": p.id, "n": lab, "t": base_type(p.type, nd.d.get("generics")), "full": p.type,
                        "type_name": ptypes.type_name(p.type, lang) if p.type not in ("T",) else ptypes.type_name("any", lang),
                        "required": p.required, "note": _tr(p.d.get("description"), lang, "")})
        return res
    caps = CAP_RU if lang == "ru" else CAP_EN
    return {"id": nd.id, "title": _tr(nd.name, lang, nd.id), "category": nd.category, "icon": nd.icon,
            "description": _tr(nd.description, lang, ""), "example": _tr(nd.example, lang, ""),
            "inputs": pins(nd.inputs, True), "outputs": pins(nd.outputs, False),
            "capabilities": [caps.get(c, c) for c in nd.capabilities],
            "reverts": bool(nd.undo) or bool((nd.d.get("function") or {}).get("reverts")), "deferred": nd.stage == "deferred" or nd.planned, "planned": nd.planned, "danger": nd.danger,
            "function": nd.d.get("function")}


def ui_get(cmd, sch, lang="ru", runs=None, file=None, fn=None):
    """A graph for the canvas. `fn` = the function document when the graph is a function body (its own interface nodes,
    validation as a function, no command flags)."""
    if fn is not None:
        sch = sch.for_function(fn)
    else:
        sch = sch.with_functions(cmd.get("functions"))
    nodes = build_nodes(cmd, sch, lang)
    wires = cmd.get("wires", [])
    auto = not all(n["has_pos"] for n in nodes)
    if auto:
        auto_layout(nodes, wires)
    types = sorted({n["type"] for n in nodes if not n.get("unknown")})
    by = {n["id"]: n for n in nodes}
    wlist = []
    for w in wires:
        a, b = by.get(w["from"][0]), by.get(w["to"][0])
        pin = None
        if a:
            for p in a["outs"]:
                if p["id"] == w["from"][1]:
                    pin = p
        wlist.append({"from": w["from"], "to": w["to"], "t": pin["t"] if pin else "any", "ok": bool(a and b)})
    comments = []
    for i, c in enumerate(cmd.get("comments", [])):
        comments.append({"id": c.get("id", "c%d" % (i + 1)), "x": float(c.get("x", 0)), "y": float(c.get("y", 0)),
                         "w": float(c.get("w", 300)), "h": float(c.get("h", 110)), "title": _tr(c.get("title", ""), lang),
                         "text": _tr(c.get("text", ""), lang), "color": c.get("color", "")})
    caps = compute_capabilities(cmd, sch)
    rep = validate(cmd, sch, fn=fn) if fn is not None else validate(cmd, sch)
    capmap = CAP_RU if lang == "ru" else CAP_EN
    extra = {}
    if fn is not None:
        extra = {"function": {k: fn.get(k) for k in ("id", "name", "description", "exec", "inputs", "outputs")},
                 "iface_catalog": [node_edit(sch.nodes[t], lang) for t in (FN_INPUT, FN_OUTPUT)]}
    return dict(extra, **{"id": cmd["id"], "name": cmd.get("name", cmd["id"]), "description": cmd.get("description", ""), "command": cmd,
            "enabled": cmd.get("enabled", True), "kind": command_kind(cmd, sch),
            "triggers": event_titles(cmd, sch, lang), "file": file, "auto_layout": auto,
            "capabilities": [{"id": c, "n": capmap.get(c, c), "risky": is_risky_cap(c)} for c in caps], "approved": not approved_ok(cmd, caps),
            "variables": cmd.get("variables", []), "nodes": nodes, "wires": wlist, "comments": comments,
            "bounds": bounds(nodes, comments), "help": help_for(types, sch, lang), "runs": runs or [],
            "report": {"errors": len(rep["errors"]), "warnings": len(rep["warnings"]),
                       "items": [{"code": i["code"], "message": i["message"]} for i in rep["errors"] + rep["warnings"]][:20]}})


def ui_fn_get(fn, sch, lang="ru"):
    """Function body for the canvas (breadcrumb «Команда › Функция»)."""
    inner = dict(fn, enabled=True)               # the whole function document: the editor edits and saves it as is
    inner.setdefault("comments", [])
    return ui_get(inner, sch, lang, fn=fn)


def ui_fn_list(be, lang="ru"):
    return be.call("fn_list")


def recent_runs(limit_per_cmd=5):
    """cmd id -> newest-first list of {ts,status,reason,dur,message} read from the run log (read-only)."""
    log = RunLog.__new__(RunLog)
    log.path = os.path.join(paths.state_dir(), "runs.jsonl")
    out = {}
    try:
        entries = RunLog.read(log)
    except OSError:
        entries = []
    for e in reversed(entries):
        cid = e.get("cmd")
        if not cid:
            continue
        lst = out.setdefault(cid, [])
        if len(lst) < limit_per_cmd:
            lst.append({"ts": e.get("end") or e.get("ts") or 0, "status": e.get("status", ""), "reason": e.get("reason", ""),
                        "dur": e.get("dur", 0), "message": e.get("message", "")})
    return out


def load_examples(sch, lang):
    res = []
    for f in sorted(glob.glob(os.path.join(paths.examples_dir(), "*.cmd.json"))):
        try:
            cmd = read_json(f)
        except (OSError, ValueError):
            continue
        res.append(_summary(cmd, sch, lang, file=f, example=True))
    return res


def _summary(cmd, sch, lang, file=None, example=False, state=None, runs=None):
    caps = compute_capabilities(cmd, sch)
    rep = validate(cmd, sch)
    s = {"id": cmd.get("id", ""), "name": cmd.get("name", ""), "description": cmd.get("description", ""),
         "enabled": cmd.get("enabled", True), "imported": bool(cmd.get("imported")), "kind": command_kind(cmd, sch),
         "triggers": event_titles(cmd, sch, lang), "nodes": len(cmd.get("nodes", [])),
         "errors": len(rep["errors"]), "warnings": len(rep["warnings"]), "capabilities": caps,
         "caps": [{"id": c, "n": (CAP_RU if lang == "ru" else CAP_EN).get(c, c), "risky": is_risky_cap(c),
                   "new": c in approved_ok(cmd, caps), "warn": (CAP_WARN_RU if lang == "ru" else CAP_WARN_EN).get(c, "")} for c in caps],
         "approved": not approved_ok(cmd, caps), "example": example, "file": file,
         "icon": _first_icon(cmd, sch), "policy": policy_of(cmd), "keywords": _keywords(cmd, sch, lang)}
    if state is not None:
        s["paused"] = state.is_paused(cmd["id"])
    if runs:
        s["last_run"] = runs[0]
    return s


def _keywords(cmd, sch, lang):
    """Titles of the node types used by a command (palette search: «уведомление», «буфер обмена», ...), unique, at most 16."""
    out = []
    for n in cmd.get("nodes", []):
        nd, _ = sch.get(n.get("type", ""))
        if nd:
            t = _tr(nd.name, lang, nd.id)
            if t and t not in out:
                out.append(t)
    return out[:16]


def _first_icon(cmd, sch):
    for n in cmd.get("nodes", []):
        nd, _ = sch.get(n.get("type", ""))
        if nd and nd.category not in ("event",) and nd.icon:
            return nd.icon
    return "play"


def ui_list(be, sch, lang="ru"):
    res = be.call("list")
    status = be.call("status")
    runs = recent_runs()
    cmds = []
    for c in res["commands"]:
        full = be.call("get", {"ref": c["id"]})
        s = _summary(full, sch, lang, runs=runs.get(c["id"]))
        s["paused"] = c.get("paused", False)
        cmds.append(s)
    pins.mark(cmds)
    try:
        trash = be.call("trash")
    except Exception:                                   # an old daemon without the editing methods
        trash = {"items": [], "keep_days": 30}
    try:
        fns = be.call("fn_list")
    except Exception:                                   # an old daemon without the function methods
        fns = {"functions": []}
    from . import docs as _docs, gallery as _gallery, tutorial as _tutorial
    return {"commands": cmds, "pinned": pins.load(), "functions": fns.get("functions", []), "examples": load_examples(sch, lang),
            "gallery": _gallery.ui_data(sch, lang), "tutorial": _tutorial.ui_data(lang), "docs": _docs.pages(sch, lang), "errors": res.get("errors", {}),
            "paused_all": status.get("paused_all", False), "active": len(status.get("active", [])),
            "mode": getattr(be, "mode", "local"), "service": _service(),
            "trash": trash.get("items", []), "trash_keep_days": trash.get("keep_days", 30)}


def ui_launch(be, sch, lang="ru"):
    """Light variant of ui_list for the launch surfaces (palette, bar menu, widget): the commands only."""
    res = be.call("list")
    status = be.call("status")
    runs = recent_runs(1)
    cmds = []
    for c in res["commands"]:
        s = _summary(be.call("get", {"ref": c["id"]}), sch, lang, runs=runs.get(c["id"]))
        s["paused"] = c.get("paused", False)
        cmds.append(s)
    pins.mark(cmds)
    return {"commands": cmds, "pinned": pins.load(), "paused_all": status.get("paused_all", False),
            "mode": getattr(be, "mode", "local")}


def pulse(be, window_s=900, now=None):
    """Tiny state for the bar button: pause flag and failed runs of the last `window_s` seconds (reads the run log only)."""
    import time as _time
    now = now if now is not None else _time.time()
    status = be.call("status")
    failed, last = 0, None
    for cid, lst in recent_runs(3).items():
        for r in lst:
            if r["status"] in ("error", "invalid") and now - (r["ts"] or 0) <= window_s:
                failed += 1
            if last is None or (r["ts"] or 0) > (last["ts"] or 0):
                last = dict(r, cmd=cid)
    return {"paused_all": status.get("paused_all", False), "failed_recent": failed, "last": last,
            "pinned": len(pins.load()), "mode": getattr(be, "mode", "local")}


def _service():
    try:
        return service.status()
    except Exception:                                   # never break the window because of systemd
        return {"unit_installed": False, "active": False}


KIND = {"ru": {"event": "Событие", "action": "Действие", "logic": "Логика", "data": "Данные", "ui": "Окна", "function": "Функция"},
        "en": {"event": "Event", "action": "Action", "logic": "Logic", "data": "Data", "ui": "Windows", "function": "Function"}}


def _edit_pin(pin, nd, lang, is_input):
    label = _tr(pin.label, lang, "")
    if pin.type == "exec" and not label:
        label = EXEC_IN[lang] if is_input else EXEC_OUT[lang]
    d = {"id": pin.id, "n": label, "t": base_type(pin.type, nd.d.get("generics")), "full": pin.type, "required": pin.required}
    if is_input:
        if pin.has_default:
            d["default"] = pin.default
        for key, val in (("choices", pin.choices), ("min", pin.min), ("max", pin.max)):
            if val is not None:
                d[key] = val
        labels = (pin.d.get("choice_labels") or {})
        if labels:
            d["choice_labels"] = labels.get(lang) or labels.get("ru") or {}
        if pin.literal:
            d["literal"] = True
        if pin.secret:
            d["secret"] = True
        if pin.var_typed:
            d["type_from_var"] = pin.var_typed
    return d


def node_edit(nd, lang):
    """Everything the editor needs to build, search and wire a node of this type (palette + buildView)."""
    caps = CAP_RU if lang == "ru" else CAP_EN
    words = " ".join([nd.id.replace(".", " ").replace("_", " "), _tr(nd.name, "ru", ""), _tr(nd.name, "en", ""),
                      _tr(nd.description, "ru", ""), _tr(nd.description, "en", "")]
                     + nd.keywords.get("ru", []) + nd.keywords.get("en", [])).lower()
    return {"type": nd.type_string, "id": nd.id, "flow": nd.flow, "category": nd.category, "icon": nd.icon,
            "title": _tr(nd.name, lang, nd.id), "kind": KIND[lang].get(nd.category, nd.category),
            "description": _tr(nd.description, lang, ""), "search": words,
            "capabilities": list(nd.capabilities), "cap_names": [caps.get(c, c) for c in nd.capabilities],
            "danger": nd.danger, "deferred": nd.stage == "deferred", "undo": nd.undo or None,
            "converter": nd.converter or None, "generics": list(nd.generics),
            "ins": [_edit_pin(p, nd, lang, True) for p in nd.inputs], "outs": [_edit_pin(p, nd, lang, False) for p in nd.outputs],
            "function": nd.d.get("function")}


def ui_schema(sch, lang="ru"):
    return {"nodes": [node_help(nd, lang) for nd in sorted(sch.all_nodes(), key=lambda n: n.id)],
            "catalog": [node_edit(nd, lang) for nd in sorted(sch.all_nodes(), key=lambda n: n.id)],
            "types": {t: ptypes.type_name(t, lang) for t in ptypes.BASE + ("list",)}}
