"""Command line: `serpantinum-x cmd <sub>` and `serpantinum-x run "Name"` (design §8). Talks to the daemon when its socket
answers, otherwise runs the engine in-process (so it works without the service)."""
import argparse
import asyncio
import json
import os
import re
import shutil
import sys
import time

from . import docs, paths, pins, service
from .api import ApiError
from .build import build
from .engine import BUILTIN_HANDLERS
from .executors import REGISTRY
from .model import CommandError
from .protocol import Client, ClientError
from .schema import load_schema, schema_check
from .validate import validate
from .util import read_json
from .xlogshim import log as xlog


class Backend:
    """call(method, params) -> result, through the daemon or in-process. Connects lazily: commands that only read
    files (validate --cmd-json, import-candidates, docs) never pay for loading the engine."""

    def __init__(self, force_local=False):
        self.force_local = force_local
        self.client, self.rt, self._mode, self._ready = None, None, "local", False

    def _init(self):
        if self._ready:
            return
        self._ready = True
        if not self.force_local:
            c = Client(paths.socket_path(), timeout=330)
            try:
                c.connect()
                self.client, self._mode = c, "daemon"
            except OSError:
                pass
        if self.client is None:
            self.rt = build()

    @property
    def mode(self):
        self._init()
        return self._mode

    def call(self, method, params=None):
        self._init()
        if self.client:
            try:
                return self.client.call(method, params)
            except ClientError as e:
                raise ApiError(e.code, e.message)
        return asyncio.run(self.rt.api.call(method, params))


def _out(args, data, text=None):
    if args.json or text is None:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print(text)


def _fmt_issues(rep):
    lines = []
    for lvl, key in (("ошибка", "errors"), ("предупреждение", "warnings")):
        for i in rep[key]:
            fix = ("\n      → " + i["fix"]["label"]) if i.get("fix") else ""
            lines.append("  %s [%s]: %s%s" % (lvl, i["code"], i["message"], fix))
    return "\n".join(lines)


def cmd_list(args, be):
    res = be.call("list")
    if args.json:
        return _out(args, res), 0
    if not res["commands"]:
        print("Команд пока нет. Примеры: %s" % paths.examples_dir())
    for c in res["commands"]:
        flags = []
        if not c["enabled"]:
            flags.append("выключена")
        if c["paused"]:
            flags.append("на паузе")
        if c["imported"]:
            flags.append("импортирована")
        if not c["approved"]:
            flags.append("права не подтверждены")
        print("%s — %s%s%s" % (c["name"], c["description"] or "без описания",
                              "  [%s]" % ", ".join(flags) if flags else "",
                              "  права: %s" % ", ".join(c["capabilities"]) if c["capabilities"] else ""))
    for f, m in res["errors"].items():
        print("  не прочитана %s: %s" % (f, m), file=sys.stderr)
    return None, 0


def _inline_command(args):
    """A command document given inline: --cmd-json TEXT, --file PATH or --stdin (the editor sends the graph this way)."""
    try:
        if getattr(args, "cmd_json", None):
            return json.loads(args.cmd_json)
        if getattr(args, "file", None):
            return read_json(args.file)
        if getattr(args, "stdin", False):
            return json.loads(sys.stdin.read())
    except (OSError, ValueError) as e:
        raise ApiError("bad_file", "Не удалось прочитать команду: %s" % e)
    return None


def cmd_validate(args, be):
    inline = _inline_command(args)
    if inline is not None:
        rep = validate(inline, load_schema())
    elif args.target and os.path.isfile(args.target):
        try:
            cmd = read_json(args.target)
        except (OSError, ValueError) as e:
            print("Не удалось прочитать файл: %s" % e, file=sys.stderr)
            return None, 2
        rep = validate(cmd, load_schema())
    elif args.target:
        rep = be.call("validate", {"ref": args.target})
    else:
        print("Укажите команду, файл или --cmd-json/--stdin", file=sys.stderr)
        return None, 2
    if args.json:
        _out(args, rep)
    else:
        print("Проверка пройдена" if rep["ok"] else "Есть ошибки")
        if rep["capabilities"]:
            print("  права: %s" % ", ".join(rep["capabilities"]))
        text = _fmt_issues(rep)
        if text:
            print(text)
    return None, 0 if rep["ok"] else 1


def cmd_get(args, be):
    print(json.dumps(be.call("get", {"ref": args.name}), ensure_ascii=False, indent=2))
    return None, 0


def cmd_save(args, be):
    cmd = _inline_command(args)
    if cmd is None:
        print("Нужен --cmd-json, --file или --stdin", file=sys.stderr)
        return None, 2
    res = be.call("save", {"command": cmd})
    _out(args, res, "Сохранено: «%s» (%s)" % (res["name"], "есть ошибки" if not res["report"]["ok"] else "проверка пройдена"))
    return None, 0


def cmd_new(args, be):
    params = {"name": args.name}
    if args.from_file:
        params["from"] = os.path.abspath(args.from_file)
    res = be.call("new", params)
    _out(args, res, "Создана команда «%s»" % res["name"])
    return None, 0


def cmd_rename(args, be):
    res = be.call("rename", {"ref": args.name, "name": args.new_name})
    _out(args, res, "Переименована: «%s»" % res["name"])
    return None, 0


def cmd_duplicate(args, be):
    res = be.call("duplicate", {"ref": args.name, "name": args.new_name})
    _out(args, res, "Копия создана: «%s» (выключена)" % res["name"])
    return None, 0


def cmd_delete(args, be):
    res = be.call("delete", {"ref": args.name})
    _out(args, res, "Удалена «%s» (в корзине %d дн.; вернуть: serpantinum-x cmd restore «%s»)" % (res["deleted"], res["keep_days"], res["deleted"]))
    return None, 0


def cmd_trash(args, be):
    res = be.call("trash")
    if args.json:
        return _out(args, res), 0
    if not res["items"]:
        print("Корзина пуста")
    for it in res["items"]:
        print("%s  %s  [%s]" % (time.strftime("%Y-%m-%d %H:%M", time.localtime(it["deleted_at"])), it["name"], it["id"]))
    return None, 0


def cmd_restore(args, be):
    res = be.call("restore", {"ref": args.name})
    _out(args, res, "Восстановлена «%s»" % res["name"])
    return None, 0


def cmd_purge(args, be):
    res = be.call("purge", {"days": args.days})
    _out(args, res, "Удалено из корзины: %d" % res["removed"])
    return None, 0


def cmd_export(args, be):
    res = be.call("export", {"ref": args.name, "path": args.path})
    _out(args, res, "Экспортировано: %s" % res["path"])
    return None, 0


def cmd_history(args, be):
    res = be.call("history", {"ref": args.name})
    if args.json:
        return _out(args, res), 0
    for v in res["versions"]:
        print("%s  %s  (%d байт)" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(v["ts"])), v["name"], v["bytes"]))
    if not res["versions"]:
        print("Истории пока нет")
    return None, 0


def cmd_revert(args, be):
    res = be.call("revert", {"ref": args.name, "version": args.version})
    _out(args, res, "Возвращена версия %s" % args.version)
    return None, 0


def cmd_import_candidates(args, be):
    """Files that look like commands in the usual download places: the window has no file dialog."""
    home = os.path.expanduser("~")
    found = []
    for d in (os.path.join(home, "Downloads"), os.path.join(home, "Загрузки"), os.path.join(home, "Documents"), os.path.join(home, "Документы"),
              os.path.join(home, "Desktop"), home):
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith((".scmd", ".cmd.json")) and os.path.isfile(os.path.join(d, f)):
                p = os.path.join(d, f)
                found.append({"path": p, "name": f, "dir": d, "mtime": os.path.getmtime(p)})
    found.sort(key=lambda e: -e["mtime"])
    seen, out = set(), []
    for e in found:
        if e["path"] not in seen:
            seen.add(e["path"])
            out.append(e)
    print(json.dumps({"files": out[:30]}, ensure_ascii=False))
    return None, 0


def cmd_run(args, be):
    params = {"ref": args.name, "args": args.arg, "dry_run": args.dry_run, "yes": args.yes}
    if args.rehearse:
        opts = {}
        if args.answer is not None:
            opts["answer"] = _json_arg(args.answer, "--answer")
        evs = []
        for spec in args.sim_event or []:
            etype, _, raw = spec.partition("=")
            evs.append({"type": etype, "data": _json_arg(raw, "--sim-event") if raw else {}})
        params["rehearse"] = dict(opts, events=evs) if (opts or evs) else True
    if args.event:
        params["event"] = {"type": args.event, "data": _json_arg(args.event_data, "--event-data") if args.event_data else {}}
    res = be.call("run", params)
    if args.json:
        _out(args, res)
    else:
        ok = res["status"] == "ok"
        mark = "✓" if ok else "✗"
        print("%s %s — %s%s" % (mark, res.get("name") or args.name, res["status"],
                                (": " + res["message"]) if res.get("message") else ""))
        if args.dry_run or args.rehearse:
            print("  (репетиция: действия не выполнялись)")
        if args.steps or args.dry_run or args.rehearse:
            for s in res.get("steps", []):
                tag = "откат " if s.get("rollback") else ""
                print("  %s%s  %s%s" % (tag, s["node"], s.get("type", ""),
                                        ("  ошибка: " + s["error"]) if s.get("error") else
                                        ("  [не выполнялось]" if s.get("dry_run") else "")))
                if s.get("plan"):
                    print("      → %s%s" % (s["plan"], ("; " + s["would_undo"]) if s.get("would_undo") else ""))
                if s.get("fast_forward"):
                    print("      → ожидание %g с пропущено (время ускорено)" % s["fast_forward"])
        if res.get("run") and res["status"] not in ("invalid", "denied"):
            print("  трасса: serpantinum-x cmd trace %s" % res["run"])
        if be.mode == "local":
            print("  (демон не запущен: выполнено напрямую)", file=sys.stderr)
    return None, 0 if res["status"] in ("ok", "skipped") else 1


def _json_arg(raw, flag):
    try:
        return json.loads(raw)
    except ValueError:
        raise ApiError("bad_params", "%s: ожидался JSON" % flag)


def cmd_trace(args, be):
    """Recorded trace of a run (id, or the last run of a command name)."""
    res = be.call("trace", {"run": args.run} if re.match(r"^[0-9]+-[0-9]+$", args.run) else {"ref": args.run})
    if args.json:
        return _out(args, res), 0
    print("%s  %s  [%s]%s%s" % (res["run"], res.get("name"), res.get("trigger"), "  репетиция" if res.get("rehearse") else "",
                                 "  " + res["status"] if res.get("status") else ""))
    for e in res["events"]:
        ev = e["ev"]
        if args.errors and ev != "error":
            continue
        if ev == "wire" and not args.wires:
            continue
        loc = ("  " + " → ".join(e["fn"]) + ":") if e.get("fn") else ""
        it = ("  #%s" % ".".join(str(i + 1) for i in e["iter"])) if e.get("iter") else ""
        what = e.get("node") or e.get("name") or ""
        extra = e.get("error") or e.get("plan") or (json.dumps(e["pins"], ensure_ascii=False) if e.get("pins") else "")
        print("%7.3f  %-6s %s%s%s  %s" % (e.get("t", 0), ev, what, it, loc, extra))
    if res.get("truncated"):
        print("  (трасса обрезана: слишком много событий)")
    return None, 0


def cmd_traces(args, be):
    res = be.call("traces", {"ref": args.name, "n": args.n} if args.name else {"n": args.n})
    if args.json:
        return _out(args, res), 0
    for r in res["runs"]:
        when = time.strftime("%m-%d %H:%M:%S", time.localtime(r.get("ts") or 0))
        print("%s  %-8s %-11s %s%s" % (r["run"], when, r.get("status", "?"), r.get("name") or r.get("cmd"),
                                       "  (репетиция)" if r.get("rehearse") else ""))
    return None, 0


def cmd_log(args, be):
    res = be.call("log", {"n": args.n, "ref": args.cmd} if args.cmd else {"n": args.n})
    if args.json:
        return _out(args, res), 0
    for r in res["runs"]:
        when = time.strftime("%m-%d %H:%M:%S", time.localtime(r.get("ts", 0)))
        print("%s  %-11s %s  [%s]%s" % (when, r.get("status", "?"), r.get("name") or r.get("cmd") or "?", r.get("trigger", "-"),
                                        ("  " + r["message"]) if r.get("message") else ""))
    return None, 0


def cmd_docs(args, be):
    sch = load_schema()
    if args.write_reference:
        n = docs.write_reference(sch)
        xlog.info("docs reference written", files=n)
        print("Справочник обновлён: %d файлов" % n)
        return None, 0
    if args.check:
        problems = docs.check(sch)
        print("\n".join(problems) if problems else "Документация в порядке")
        return None, 1 if problems else 0
    if args.list:
        print(json.dumps(docs.pages(sch, args.lang), ensure_ascii=False))
        return None, 0
    if args.page:
        text = docs.page(sch, args.lang, args.page)
        if text is None:
            raise ApiError("not_found", "Страницы «%s» нет" % args.page)
        print(text, end="")
        return None, 0
    if args.all:
        if not args.out:
            raise ApiError("usage", "Для --all нужна папка: --out DIR")
        files = docs.write_all(sch, args.lang, args.out)
        xlog.info("docs generated", lang=args.lang, files=len(files))
        print("Записано %d файлов в %s" % (len(files), args.out))
    elif args.out:
        files = docs.write_docs(sch, args.lang, args.out)
        print("Записано %d файлов в %s: %s" % (len(files), args.out, ", ".join(files)))
    else:
        print(docs.render_all(sch, args.lang), end="")
    return None, 0


# ---- gallery and tutorial ------------------------------------------------------------------------------------------
def gallery_list(args, be):
    from . import gallery
    items = gallery.ui_data(load_schema(), args.lang)
    if args.json:
        return _out(args, items), 0
    for g in items:
        state = "готова" if g["ready"] else "ждёт узлов: %s" % ", ".join(g["missing"])
        pk = "  пакеты: %s" % ", ".join(p["name"] + ("" if p["installed"] else " (не установлен)") for p in g["packages"]) if g["packages"] else ""
        print("%-16s %-24s [%s]%s" % (g["id"], g["name"], state, pk))
    return None, 0


def gallery_show(args, be):
    from . import gallery
    sch = load_schema()
    f = gallery.find(args.name)
    if f is None:
        raise ApiError("not_found", "В галерее нет «%s»" % args.name)
    e = gallery.entry_for(f, sch)
    if args.json:
        return _out(args, dict(e, doc=gallery.localize(read_json(f), args.lang))), 0
    pick = lambda d: d.get(args.lang) or d.get("ru") or ""
    print("%s — %s" % (pick(e["name"]), pick(e["description"])))
    print("узлов: %d, комментариев: %d" % (e["nodes"], e["comments"]))
    print("права: %s" % (", ".join(e["capabilities"]) or "нет"))
    print("события: %s" % (", ".join(e["events"]) or "вручную"))
    if e["packages"]:
        print("пакеты: %s" % ", ".join(e["packages"]))
    print("готова" if e["ready"] else "ждёт узлов: %s" % ", ".join(e["missing"]))
    return None, 0


def gallery_add(args, be):
    from . import gallery
    try:
        res = gallery.add(be, args.name, args.lang)
    except KeyError:
        raise ApiError("not_found", "В галерее нет «%s»" % args.name)
    text = "Добавлена команда «%s» (выключена, права не подтверждены)" % res["name"]
    if not res["ready"]:
        text += "\n  Запустить пока нельзя: ждёт узлов %s" % ", ".join(res["missing"])
    _out(args, res, text)
    return None, 0


def gallery_manifest(args, be):
    import io
    from . import gallery
    data = json.dumps(gallery.manifest(load_schema()), ensure_ascii=False, indent=1) + "\n"
    path = os.path.join(paths.gallery_dir(), gallery.MANIFEST)
    if args.write:
        with open(path, "w", encoding="utf-8") as f:
            f.write(data)
        print("Записано: %s" % path)
        return None, 0
    if args.check:
        have = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
        print("gallery.json в порядке" if have == data else "gallery.json устарел (serpantinum-x cmd gallery manifest --write)")
        return None, 0 if have == data else 1
    print(data, end="")
    return None, 0


def gallery_check(args, be):
    from . import gallery
    problems = gallery.check(load_schema())
    if args.json:
        _out(args, {"problems": problems})
    else:
        print("\n".join(problems) if problems else "Галерея в порядке")
    return None, 1 if problems else 0


def tutorial_get(args, be):
    from . import tutorial
    print(json.dumps(tutorial.ui_data(args.lang), ensure_ascii=False))
    return None, 0


def tutorial_set(args, be):
    from . import tutorial
    st = tutorial.set_state(done=None if args.done is None else args.done == "1", skipped=None if args.skipped is None else args.skipped == "1", step=args.step)
    print(json.dumps(st))
    return None, 0


def tutorial_reset(args, be):
    from . import tutorial
    print(json.dumps(tutorial.reset()))
    return None, 0


def tutorial_check(args, be):
    from . import tutorial
    problems = tutorial.check(load_schema())
    print("\n".join(problems) if problems else "Обучение в порядке")
    return None, 1 if problems else 0


# ---- functions (custom nodes): `serpantinum-x cmd fn ...` ---------------------------------------------------------
def _fn_doc(args):
    try:
        if getattr(args, "fn_json", None):
            return json.loads(args.fn_json)
        if getattr(args, "stdin", False):
            return json.loads(sys.stdin.read())
    except ValueError as e:
        raise ApiError("bad_file", "Не удалось прочитать функцию: %s" % e)
    return None


def fn_list(args, be):
    res = be.call("fn_list")
    if args.json:
        return _out(args, res), 0
    if not res["functions"]:
        print("Функций пока нет. Выделите узлы в редакторе и нажмите «Свернуть в узел».")
    for f in res["functions"]:
        pins = "%s → %s" % (", ".join("%s:%s" % (p["id"], p["type"]) for p in f["inputs"]) or "-",
                            ", ".join("%s:%s" % (p["id"], p["type"]) for p in f["outputs"]) or "-")
        print("%s [%s] — %d узл., %s%s%s" % (f["name"], f["id"], f["nodes"], pins, "  права: %s" % ", ".join(f["capabilities"]) if f["capabilities"] else "",
                                          "" if f["ok"] else "  [есть ошибки]"))
    for p, m in res["errors"].items():
        print("  не прочитана %s: %s" % (p, m), file=sys.stderr)
    return None, 0


def fn_show(args, be):
    fn = be.call("fn_get", {"ref": args.name})
    print(json.dumps(fn, ensure_ascii=False, indent=2))
    return None, 0


def fn_validate(args, be):
    if args.target and os.path.isfile(args.target):
        try:
            fn = read_json(args.target)
        except (OSError, ValueError) as e:
            print("Не удалось прочитать файл: %s" % e, file=sys.stderr)
            return None, 2
        fn = fn.get("function", fn) if isinstance(fn, dict) else fn
        from .validate import validate_function
        rep = validate_function(fn, load_schema())
    elif args.target:
        rep = be.call("fn_validate", {"ref": args.target})
    else:
        fn = _fn_doc(args)
        if fn is None:
            print("Укажите функцию, файл или --fn-json/--stdin", file=sys.stderr)
            return None, 2
        rep = be.call("fn_validate", {"function": fn})
    if args.json:
        _out(args, rep)
    else:
        print("Функция в порядке" if rep["ok"] and not rep["warnings"] else _fmt_issues(rep) or "Функция в порядке")
    return None, 0 if rep["ok"] else 1


def fn_export(args, be):
    res = be.call("fn_export", {"ref": args.name, "path": args.path})
    _out(args, res, "Экспортировано: %s (функций в пакете: %d)" % (res["path"], res["functions"]))
    return None, 0


def fn_import(args, be):
    res = be.call("fn_import", {"path": args.path})
    lines = ["Импортирована «%s»" % res["name"]] + ["  %s: %s" % (i["name"], {"new": "добавлена", "same": "уже есть такая же", "renamed": "конфликт: сохранена как новая"}[i["status"]]) for i in res["functions"]]
    _out(args, res, "\n".join(lines))
    return None, 0


def fn_delete(args, be):
    res = be.call("fn_delete", {"ref": args.name, "force": args.force})
    _out(args, res, "Функция «%s» удалена (в корзине %d дн.)" % (res["deleted"], res["keep_days"]))
    return None, 0


def fn_create(args, be):
    fn = _fn_doc(args)
    res = be.call("fn_create", {"name": args.name or (fn or {}).get("name", ""), "function": fn})
    _out(args, res, "Создана функция «%s»" % res["name"])
    return None, 0


def fn_save(args, be):
    fn = _fn_doc(args)
    if fn is None:
        raise ApiError("bad_file", "Нужен документ функции: --fn-json или --stdin")
    res = be.call("fn_save", {"function": fn})
    _out(args, res, "Сохранена функция «%s»" % res["name"])
    return None, 0


def fn_rename(args, be):
    res = be.call("fn_rename", {"ref": args.name, "name": args.new_name})
    _out(args, res, "Функция переименована: «%s»" % res["name"])
    return None, 0


def fn_duplicate(args, be):
    res = be.call("fn_duplicate", {"ref": args.name, "name": args.new_name})
    _out(args, res, "Копия функции: «%s»" % res["name"])
    return None, 0


def fn_usages(args, be):
    res = be.call("fn_usages", {"ref": args.name})
    _out(args, res, "\n".join("%s «%s»" % ("команда" if u["kind"] == "command" else "функция", u["name"]) for u in res["usages"]) or "Нигде не используется")
    return None, 0


def cmd_ui_fn_get(args, be):
    from . import uiview
    sch = load_schema()
    fn = be.call("fn_get", {"ref": args.target})
    print(json.dumps(uiview.ui_fn_get(fn, sch, args.lang), ensure_ascii=False))
    return None, 0


def cmd_ui_fn_list(args, be):
    res = be.call("fn_list")
    print(json.dumps(res, ensure_ascii=False))
    return None, 0


def _simple(method, ok_text):
    def fn(args, be):
        res = be.call(method, {"ref": getattr(args, "name", None)} if getattr(args, "name", None) else {})
        if args.json:
            _out(args, res)
        else:
            print(ok_text(res, args))
        return None, 0
    return fn


def cmd_pin(args, be):
    on = args.sub == "pin"
    c = be.call("get", {"ref": args.name})
    changed = pins.set_pinned(c["id"], on)
    xlog.info("pin" if on else "unpin", name=c.get("name"), changed=changed)
    if args.json:
        return _out(args, {"id": c["id"], "name": c["name"], "pinned": on, "changed": changed}), 0
    print("%s «%s»" % ("Закреплена" if on else "Откреплена", c["name"]) + ("" if changed else " (уже так было)"))
    return None, 0


def cmd_pinned(args, be):
    res = be.call("list")
    ids = pins.load()
    by = {c["id"]: c for c in res["commands"]}
    items = [{"id": i, "name": by[i]["name"], "kind": by[i].get("kind", "")} for i in ids if i in by]
    if args.json:
        return _out(args, {"pinned": items}), 0
    for it in items:
        print(it["name"])
    return None, 0


def cmd_status(args, be):
    svc = service.status()
    st = be.call("status")
    data = {"service": svc, "daemon": be.mode == "daemon", "engine": st}
    if args.json:
        return _out(args, data), 0
    print("Служба: %s%s" % ("установлена" if svc["unit_installed"] else "не установлена",
                            ", включена" if svc["enabled"] else "") + (", запущена" if svc["active"] else ""))
    print("Демон на сокете: %s" % ("отвечает" if be.mode == "daemon" else "нет (команды выполняются напрямую)"))
    print("Команд: %d, активных запусков: %d, пауза всех: %s" % (st["commands"], len(st["active"]), "да" if st["paused_all"] else "нет"))
    for cid, p in st["paused"].items():
        print("  на паузе: %s (%s)" % (cid, p.get("reason")))
    tr = st.get("triggers") or {}
    if tr.get("running"):
        print("Триггеры: подписок %d" % len(tr.get("subscriptions", [])))
        for name in tr.get("active", []):
            s = tr["sources"][name]
            print("  источник %-9s %-8s событий: %d%s" % (name, s["state"], s["events"], ("  — " + s["error"]) if s["error"] else ""))
            for k, e in (s.get("errors") or {}).items():
                print("    %s: %s" % (k, e))
    return None, 0


def cmd_emit(args, be):
    """Inject a synthetic event: into the running daemon (real runs) or, without a daemon, as a dry run."""
    try:
        data = json.loads(args.data) if args.data else {}
    except ValueError:
        raise ApiError("bad_params", "JSON с данными события не разобран")
    if be.mode == "daemon":
        res = be.call("emit", {"type": args.type, "data": data, "origin": "cli"})
        return _out(args, res, "Событие %s отправлено демону, запущено команд: %d" % (res["type"], res["started"])), 0
    from .triggers import TriggerManager

    async def go():
        m = TriggerManager(be.rt.engine, be.rt.clock, sources={})
        m.subs = m.collect()
        event = {"type": args.type, "ts": be.rt.clock.now(), "data": data}
        return [await task for task in m.dispatch(event, dry_run=True)]
    runs = asyncio.run(go())
    if args.json:
        return _out(args, {"dry_run": True, "runs": runs}), 0
    print("(демон не запущен: репетиция, действия не выполнялись)")
    for r in runs:
        print("  %-12s %s" % (r.get("status"), r.get("name") or r.get("cmd")))
    if not runs:
        print("  ни одна включённая и подтверждённая автоматизация не слушает событие «%s»" % args.type)
    return None, 0


def cmd_events(args, be):
    """Stream normalized events of the running daemon (debugging)."""
    c = Client(paths.socket_path(), timeout=None)
    try:
        c.connect()
    except OSError:
        raise ApiError("no_daemon", "Демон не запущен: события видны только когда он работает")
    c.call("subscribe", {"topics": ["event"]})
    print("Слушаю события (Ctrl+C — выход)…", file=sys.stderr)
    for msg in c.events():
        if args.json:
            print(json.dumps(msg, ensure_ascii=False), flush=True)
        else:
            ev = msg.get("event") or msg
            print("%s  %-14s %s" % (time.strftime("%H:%M:%S", time.localtime(ev.get("ts", time.time()))), ev.get("type", "?"),
                                    json.dumps(ev.get("data", {}), ensure_ascii=False)), flush=True)
    return None, 0


def cmd_ui_list(args, be):
    from . import uiview
    print(json.dumps(uiview.ui_list(be, load_schema(), args.lang), ensure_ascii=False))
    return None, 0


def cmd_ui_launch(args, be):
    from . import uiview
    print(json.dumps(uiview.ui_launch(be, load_schema(), args.lang), ensure_ascii=False))
    return None, 0


def cmd_pulse(args, be):
    from . import uiview
    print(json.dumps(uiview.pulse(be), ensure_ascii=False))
    return None, 0


def cmd_ui_get(args, be):
    from . import uiview
    sch = load_schema()
    if os.path.isfile(args.target):
        cmd, file = read_json(args.target), os.path.abspath(args.target)
    else:
        cmd, file = be.call("get", {"ref": args.target}), None
    runs = uiview.recent_runs().get(cmd.get("id", ""), [])
    print(json.dumps(uiview.ui_get(cmd, sch, args.lang, runs, file), ensure_ascii=False))
    return None, 0


def cmd_ui_schema(args, be):
    from . import uiview
    print(json.dumps(uiview.ui_schema(load_schema(), args.lang), ensure_ascii=False))
    return None, 0


def cmd_import(args, be):
    if be.mode == "daemon":
        res = be.call("import", {"path": os.path.abspath(args.path)})
    else:
        res = be.call("import", {"path": args.path})
    if args.json:
        return _out(args, res), 0
    print("Импортирована команда «%s» (выключена, права не подтверждены)." % res["command"])
    print("  права: %s" % (", ".join(res["capabilities"]) or "нет"))
    for s in res["suspicious"]:
        print("  внимание: узел «%s» (%s)" % (s["name"], s["type"]))
    for w in res["warnings"]:
        print("  " + w)
    print("  Просмотрите её и подтвердите: serpantinum-x cmd approve «%s»" % res["command"])
    return None, 0


def cmd_approve(args, be):
    cmd = be.call("get", {"ref": args.name})
    rep = be.call("validate", {"ref": args.name})
    caps = rep["capabilities"]
    if not args.yes and not args.json:
        print("Команда «%s» сможет: %s" % (cmd["name"], ", ".join(caps) or "ничего особенного"))
        if not sys.stdin.isatty():
            print("Подтвердите ключом --yes.", file=sys.stderr)
            return None, 1
        if input("Подтвердить? [y/N] ").strip().lower() not in ("y", "yes", "д", "да"):
            print("Отменено")
            return None, 1
    res = be.call("approve", {"ref": args.name})
    _out(args, res, "Права подтверждены: %s" % (", ".join(res["approved_capabilities"]) or "—"))
    return None, 0


def cmd_install(args, be):
    if args.check:
        res = service.check()
        if args.json:
            _out(args, res)
        else:
            print("Служба актуальна" if res["current"] else ("Служба устарела (выполните: serpantinum-x cmd install)" if res["installed"] else "Служба не установлена"))
        return None, 0 if res["current"] else 1
    res = service.install(print_only=args.print_only)
    if args.json:
        return _out(args, res), 0
    if args.print_only:
        print("\n".join(res["plan"]))
        print("\n" + res["unit"])
    else:
        print("Служба установлена: %s" % ("успешно" if res["ok"] else "с ошибками (см. --json)"))
    return None, 0 if args.print_only or res["ok"] else 1


def cmd_uninstall(args, be):
    res = service.uninstall(print_only=args.print_only)
    _out(args, res, "\n".join(res["plan"]) if args.print_only else "Служба удалена")
    return None, 0


def cmd_daemon(args, be):
    from .daemon import main as daemon_main
    daemon_main()
    return None, 0


def cmd_schema_check(args, be):
    problems = schema_check(load_schema(), REGISTRY, BUILTIN_HANDLERS)
    if args.json:
        _out(args, {"problems": problems})
    else:
        print("\n".join(problems) if problems else "Схема в порядке")
    return None, 1 if problems else 0


def _read_pins_raw(path):
    try:
        return read_json(path)
    except (OSError, ValueError):
        return None


def cmd_doctor(args, be):
    checks = []

    def add(level, text):
        checks.append({"level": level, "text": text})

    problems = schema_check(load_schema(), REGISTRY, BUILTIN_HANDLERS)
    add("fail" if problems else "ok", ("схема узлов: %d проблем (%s)" % (len(problems), problems[0])) if problems else "схема узлов в порядке")
    try:
        res = be.call("list")
        bad = [c["name"] for c in res["commands"] if not validate(be.call("get", {"ref": c["id"]}), load_schema())["ok"]]
        add("warn" if bad or res["errors"] else "ok", "команд: %d, с ошибками: %d" % (len(res["commands"]), len(bad) + len(res["errors"])))
        pending = [c["name"] for c in res["commands"] if not c["approved"]]
        if pending:
            add("warn", "права не подтверждены у: %s" % ", ".join(pending))
    except ApiError as e:
        add("warn", "список команд недоступен: %s" % e.message)
    svc = service.status()
    if not svc["unit_installed"]:
        add("warn", "служба serpantinum-cmdd не установлена: автоматизации работать не будут (serpantinum-x cmd install)")
    else:
        add("ok" if svc["active"] else "warn", "служба serpantinum-cmdd: %s" % ("запущена" if svc["active"] else "установлена, но не запущена"))
    add("ok" if be.mode == "daemon" else "warn", "демон на сокете: %s" % ("отвечает" if be.mode == "daemon" else "не отвечает"))
    # Commands window (read-only UI): the QML host must be installed and the view data provider must answer.
    host = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "quickshell", "custom", "cmd", "XCmdHost.qml")
    host = os.path.normpath(host)
    if not os.path.isfile(host):
        add("warn", "окно «Команды»: файлы интерфейса не найдены (%s)" % os.path.basename(host))
    else:
        try:
            from . import uiview
            data = uiview.ui_list(be, load_schema(), "ru")
            add("ok", "окно «Команды»: данные списка готовы (%d команд, %d примеров)" % (len(data.get("commands", [])), len(data.get("examples", []))))
        except Exception as e:  # doctor must never crash
            add("warn", "окно «Команды»: данные списка недоступны (%s)" % e)
    # Editor (stage 3): the QML logic files must be installed, the command and trash folders must be writable.
    qdir = os.path.dirname(host)
    missing = [f for f in ("XEdit.qml", "EditorLogic.js", "NodePalette.qml", "ValueEditor.qml", "CmdDialogs.qml") if not os.path.isfile(os.path.join(qdir, f))]
    add("warn" if missing else "ok", ("редактор команд: не найдены файлы %s" % ", ".join(missing)) if missing else "редактор команд: файлы на месте")
    # launch surfaces (palette, bar button, widget): QML files in place, pin file readable
    lmiss = [f for f in ("XCmdLaunch.qml", "XCmdLaunchHost.qml", "CmdPalette.qml", "CmdPaletteView.qml", "CmdFace.qml", "SideCmdFace.qml", "CmdMenu.qml", "CmdWidgetView.qml", "LaunchLogic.js") if not os.path.isfile(os.path.join(qdir, f))]
    pf = pins.path()
    pin_bad = os.path.exists(pf) and not isinstance(_read_pins_raw(pf), (dict, list))
    if lmiss:
        add("warn", "палитра, кнопка на панели и виджет: не найдены файлы %s" % ", ".join(lmiss))
    elif pin_bad:
        add("warn", "закреплённые команды: файл %s повреждён (будет перезаписан при следующем закреплении)" % os.path.basename(pf))
    else:
        add("ok", "палитра, кнопка на панели и виджет: файлы на месте, закреплено команд: %d" % len(pins.load()))
    for label, d in (("папка команд", paths.commands_dir()), ("корзина", os.path.join(paths.state_dir(), "trash"))):
        probe = d if os.path.isdir(d) else os.path.dirname(d)
        add("ok" if os.access(probe, os.W_OK) or not os.path.exists(probe) else "warn", "%s: %s" % (label, "доступна для записи" if os.access(probe, os.W_OK) or not os.path.exists(probe) else "нет прав на запись (%s)" % d))
    # >>> triggers doctor (stage 4)
    try:
        tr = be.call("status").get("triggers") or {}
        if tr.get("running"):
            for name, s in sorted((tr.get("sources") or {}).items()):
                if name in tr.get("active", []):
                    add("fail" if s["state"] == "failed" else ("warn" if s["state"] == "waiting" else "ok"),
                        "источник событий «%s»: %s%s" % (name, s["state"], (" — " + s["error"]) if s["error"] else ""))
                for k, e in (s.get("errors") or {}).items():
                    add("warn", "триггер %s: %s" % (k, e))
        else:
            add("ok", "источники событий: демон не запущен, подписок нет")
    except ApiError as e:
        add("warn", "источники событий недоступны: %s" % e.message)
    for tool, what in (("busctl", "блокировка/разблокировка"), ("hyprctl", "события окон")):
        add("ok" if shutil.which(tool) else "warn", "%s: %s" % (tool, ("есть (%s)" % what) if shutil.which(tool) else "не найден — %s не будет работать" % what))
    # <<< triggers doctor
    for tool in ("notify-send", "wl-copy", "wl-paste"):
        add("ok" if shutil.which(tool) else "warn", "%s: %s" % (tool, "есть" if shutil.which(tool) else "не найден"))
    # documentation, gallery and tutorial (stage 8)
    from . import gallery, tutorial
    sch = load_schema()
    for name, probs in (("документация", docs.check(sch)), ("галерея примеров", gallery.check(sch)), ("обучение", tutorial.check(sch))):
        add("fail" if probs else "ok", ("%s: %d проблем (%s)" % (name, len(probs), probs[0])) if probs else "%s в порядке" % name)
    print(json.dumps({"checks": checks}, ensure_ascii=False))
    return None, 1 if any(c["level"] == "fail" for c in checks) else 0


def build_parser():
    ap = argparse.ArgumentParser(prog="serpantinum-x cmd", description="Команды: визуальное программирование автоматизаций")
    ap.add_argument("--json", action="store_true", help="вывод в JSON")
    ap.add_argument("--local", action="store_true", help="не использовать демон, выполнить в этом процессе")
    sub = ap.add_subparsers(dest="sub", required=True)

    def add(name, fn, help_):
        p = sub.add_parser(name, help=help_)
        p.set_defaults(fn=fn)
        return p

    def inline_args(p):
        g = p.add_mutually_exclusive_group()
        g.add_argument("--cmd-json", help="документ команды в JSON (так редактор передаёт граф)")
        g.add_argument("--file", help="файл с документом команды")
        g.add_argument("--stdin", action="store_true", help="документ команды со стандартного ввода")

    for nm, h in (("pin", "закрепить команду в палитре, на панели и в виджете"), ("unpin", "открепить команду")):
        q = add(nm, cmd_pin, h)
        q.add_argument("name", help="название или id команды")
    add("pinned", cmd_pinned, "закреплённые команды")

    pf = add("fn", lambda a, b: (_ for _ in ()).throw(ApiError("usage", "Подкоманды: list show validate export import delete")),
             "функции (свои узлы): list|show|validate|export|import|delete|create|save|rename|duplicate|usages")
    fsub = pf.add_subparsers(dest="fn_sub", required=True)

    def fadd(name, fn, help_):
        q = fsub.add_parser(name, help=help_)
        q.set_defaults(fn=fn)
        return q
    fadd("list", fn_list, "список функций")
    q = fadd("show", fn_show, "документ функции (JSON)")
    q.add_argument("name")
    q = fadd("validate", fn_validate, "проверить функцию (имя, файл или --fn-json/--stdin)")
    q.add_argument("target", nargs="?")
    q.add_argument("--fn-json")
    q.add_argument("--stdin", action="store_true")
    q = fadd("export", fn_export, "экспортировать функцию (и вызываемые ею) в файл .sfn")
    q.add_argument("name")
    q.add_argument("path")
    q = fadd("import", fn_import, "импортировать функции из .sfn (локальные никогда не перезаписываются)")
    q.add_argument("path")
    q = fadd("delete", fn_delete, "удалить функцию в корзину (если её не используют)")
    q.add_argument("name")
    q.add_argument("--force", action="store_true", help="удалить, даже если используется")
    q = fadd("create", fn_create, "создать функцию из документа (--fn-json/--stdin)")
    q.add_argument("--name")
    q.add_argument("--fn-json")
    q.add_argument("--stdin", action="store_true")
    q = fadd("save", fn_save, "сохранить отредактированную функцию")
    q.add_argument("--fn-json")
    q.add_argument("--stdin", action="store_true")
    q = fadd("rename", fn_rename, "переименовать функцию")
    q.add_argument("name")
    q.add_argument("new_name")
    q = fadd("duplicate", fn_duplicate, "копия функции")
    q.add_argument("name")
    q.add_argument("--name", dest="new_name", default=None)
    q = fadd("usages", fn_usages, "где используется функция")
    q.add_argument("name")
    add("list", cmd_list, "список команд")
    p = add("validate", cmd_validate, "проверить команду (имя, файл или документ из --cmd-json/--stdin)")
    p.add_argument("target", nargs="?")
    inline_args(p)
    p = add("get", cmd_get, "документ команды (JSON)")
    p.add_argument("name")
    p = add("save", cmd_save, "сохранить отредактированную команду")
    inline_args(p)
    p = add("new", cmd_new, "создать команду (пустую или по образцу)")
    p.add_argument("--name", required=True)
    p.add_argument("--from", dest="from_file", help="файл-образец (например, пример из галереи)")
    p = add("rename", cmd_rename, "переименовать команду")
    p.add_argument("name")
    p.add_argument("new_name")
    p = add("duplicate", cmd_duplicate, "сделать копию (выключенную)")
    p.add_argument("name")
    p.add_argument("--name", dest="new_name", default=None)
    p = add("delete", cmd_delete, "удалить команду в корзину")
    p.add_argument("name")
    add("trash", cmd_trash, "корзина")
    p = add("restore", cmd_restore, "вернуть команду из корзины")
    p.add_argument("name")
    p = add("purge", cmd_purge, "очистить старые записи корзины")
    p.add_argument("--days", type=int, default=30)
    p = add("export", cmd_export, "экспортировать команду в файл .scmd")
    p.add_argument("name")
    p.add_argument("path")
    p = add("history", cmd_history, "сохранённые версии команды")
    p.add_argument("name")
    p = add("revert", cmd_revert, "вернуть сохранённую версию")
    p.add_argument("name")
    p.add_argument("version", help="имя файла из `history`")
    add("import-candidates", cmd_import_candidates, "найти файлы команд в Загрузках и Документах (JSON)")
    p = add("run", cmd_run, "запустить команду по имени")
    p.add_argument("name")
    p.add_argument("--dry-run", action="store_true", help="простой пробный запуск без побочных эффектов")
    p.add_argument("--rehearse", action="store_true", help="репетиция: действия только описываются, время ускорено")
    p.add_argument("--answer", help="JSON-ответ на вопросы в репетиции, например '{\"index\": 1}' или '\"да\"'")
    p.add_argument("--event", help="начать с события этого типа (window.open, workspace…) вместо «Вручную»")
    p.add_argument("--event-data", help="данные события в JSON (для --event)")
    p.add_argument("--sim-event", action="append", help="TYPE[=JSON]: событие для узла «Ждать событие» в репетиции")
    p.add_argument("--yes", action="store_true", help="подтвердить опасные узлы заранее")
    p.add_argument("--arg", default="", help="аргумент события «Вручную»")
    p.add_argument("--steps", action="store_true", help="показать шаги")
    p = add("trace", cmd_trace, "трасса запуска (id запуска или имя команды: последний запуск)")
    p.add_argument("run")
    p.add_argument("--errors", action="store_true", help="только ошибки")
    p.add_argument("--wires", action="store_true", help="показать и провода")
    p = add("traces", cmd_traces, "последние сохранённые трассы")
    p.add_argument("name", nargs="?")
    p.add_argument("-n", type=int, default=20)
    p = add("log", cmd_log, "журнал запусков")
    p.add_argument("-n", type=int, default=20)
    p.add_argument("-c", "--cmd", help="только запуски этой команды (с отметкой, есть ли трасса)")
    p = add("docs", cmd_docs, "документация: справочник узлов из схемы, понятия, рецепты")
    p.add_argument("--lang", choices=("ru", "en"), default="ru")
    p.add_argument("--out", help="папка для файлов (без неё — в stdout)")
    p.add_argument("--all", action="store_true", help="вся документация (понятия, справочник, рецепты) в --out")
    p.add_argument("--write-reference", action="store_true", help="обновить закоммиченный справочник из схемы")
    p.add_argument("--check", action="store_true", help="проверить, что справочник и понятия актуальны (для CI)")
    p.add_argument("--list", action="store_true", help="страницы для окна «Команды» (JSON)")
    p.add_argument("--page", help="одна страница в Markdown (для окна «Команды»)")
    pg = add("gallery", lambda a, b: (_ for _ in ()).throw(ApiError("usage", "Подкоманды: list show add manifest check")),
             "галерея примеров: list|show|add|manifest|check")
    gsub = pg.add_subparsers(dest="gallery_sub", required=True)

    def gadd(name, fn, help_, lang=True):
        q = gsub.add_parser(name, help=help_)
        q.set_defaults(fn=fn)
        if lang:
            q.add_argument("--lang", choices=("ru", "en"), default="ru")
        return q
    gadd("list", gallery_list, "список примеров, готовность, нужные узлы и пакеты")
    q = gadd("show", gallery_show, "описание одного примера")
    q.add_argument("name")
    q = gadd("add", gallery_add, "добавить пример в мои команды (выключенным)")
    q.add_argument("name")
    q = gadd("manifest", gallery_manifest, "gallery.json из файлов галереи", lang=False)
    q.add_argument("--write", action="store_true")
    q.add_argument("--check", action="store_true")
    gadd("check", gallery_check, "проверить файлы галереи (для CI)", lang=False)
    pt = add("tutorial", lambda a, b: (_ for _ in ()).throw(ApiError("usage", "Подкоманды: get set reset check")),
             "обучение при первом запуске: get|set|reset|check")
    tsub = pt.add_subparsers(dest="tutorial_sub", required=True)
    q = tsub.add_parser("get", help="шаги и прогресс (JSON)")
    q.set_defaults(fn=tutorial_get)
    q.add_argument("--lang", choices=("ru", "en"), default="ru")
    q = tsub.add_parser("set", help="сохранить прогресс")
    q.set_defaults(fn=tutorial_set)
    q.add_argument("--done", choices=("0", "1"))
    q.add_argument("--skipped", choices=("0", "1"))
    q.add_argument("--step", type=int)
    tsub.add_parser("reset", help="начать обучение заново").set_defaults(fn=tutorial_reset)
    tsub.add_parser("check", help="проверить tutorial.json").set_defaults(fn=tutorial_check)
    add("status", cmd_status, "служба, демон, паузы, источники событий")
    p = add("emit", cmd_emit, "отправить событие (отладка автоматизаций; без демона — репетиция)")
    p.add_argument("type", help="например window.open, workspace, time.at, session.lock, idle.start")
    p.add_argument("data", nargs="?", help="данные события в JSON")
    add("events", cmd_events, "поток событий демона (отладка)")
    for name, fn, help_ in (("ui-list", cmd_ui_list, "данные списка для окна «Команды» (JSON)"),
                            ("ui-launch", cmd_ui_launch, "команды для палитры, кнопки на панели и виджета (JSON)"),
                            ("ui-get", cmd_ui_get, "данные графа одной команды для окна (JSON)"),
                            ("ui-schema", cmd_ui_schema, "каталог узлов для окна (JSON)"),
                            ("ui-fn-get", cmd_ui_fn_get, "данные графа функции для окна (JSON)")):
        p = add(name, fn, help_)
        p.add_argument("--lang", choices=("ru", "en"), default="ru")
        if name in ("ui-get", "ui-fn-get"):
            p.add_argument("target", help="имя/id команды (функции) или путь к файлу")
    add("pulse", cmd_pulse, "состояние для кнопки на панели: пауза и недавние ошибки (JSON)")
    for name, text in (("pause", "поставить на паузу все автоматизации или одну команду"),
                       ("resume", "снять паузу")):
        p = add(name, _simple(name, lambda r, a, n=name: "%s: все автоматизации %s" % (
            "Пауза" if n == "pause" else "Возобновлено", "на паузе" if r["paused_all"] else "работают")), text)
        p.add_argument("name", nargs="?")
    for name, word in (("enable", "включена"), ("disable", "выключена")):
        p = add(name, _simple(name, lambda r, a, w=word: "Команда «%s» %s" % (r["name"], w)), "%s команду" % name)
        p.add_argument("name")
    p = add("approve", cmd_approve, "подтвердить права команды")
    p.add_argument("name")
    p.add_argument("--yes", action="store_true")
    p = add("import", cmd_import, "импортировать команду (выключенной)")
    p.add_argument("path")
    p = add("install", cmd_install, "установить службу systemd --user")
    p.add_argument("--print", dest="print_only", action="store_true", help="только показать, что будет сделано")
    p.add_argument("--check", action="store_true", help="ничего не менять: код 0, если установленная служба совпадает с шаблоном")
    p = add("uninstall", cmd_uninstall, "удалить службу")
    p.add_argument("--print", dest="print_only", action="store_true")
    add("daemon", cmd_daemon, "запустить демон на переднем плане (для systemd)")
    add("schema-check", cmd_schema_check, "проверить схему узлов")
    add("doctor", cmd_doctor, "проверки для serpantinum-x doctor (JSON)")
    return ap


_QUIET_SUBS = {"tutorial", "gallery", "trace", "traces", "list", "ui-list", "ui-launch", "pulse", "pinned", "ui-get", "ui-fn-get", "ui-schema", "log", "status", "docs", "doctor", "schema-check", "events"}


def main(argv):
    args = build_parser().parse_args(argv)
    t0 = time.monotonic()
    # every state-changing / run request leaves a line (name of the command only, never values)
    quiet = args.sub in _QUIET_SUBS
    (xlog.debug if quiet else xlog.info)("cli %s" % args.sub, name=getattr(args, "name", None) or None,
                                         local=bool(args.local) or None, dry=bool(getattr(args, "dry_run", False)) or None)
    rc = 1
    try:
        be = None if args.sub in ("daemon", "install", "uninstall", "schema-check", "docs") else Backend(args.local)
        _res, rc = args.fn(args, be)
        return rc
    except ApiError as e:
        xlog.warn("cli %s failed" % args.sub, code=e.code, message=str(e.message)[:200])
        print(json.dumps({"status": "error", "code": e.code, "message": e.message}, ensure_ascii=False) if args.json
              else "Ошибка: %s" % e.message, file=sys.stderr)
        return 1
    except CommandError as e:
        xlog.warn("cli %s failed" % args.sub, message=str(e.message)[:200])
        print("Ошибка: %s" % e.message, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    except Exception as e:
        xlog.exception("cli %s crashed" % args.sub, exc=e)
        raise
    finally:
        (xlog.debug if quiet else xlog.info)("cli %s done" % args.sub, rc=rc, ms=int((time.monotonic() - t0) * 1000))
