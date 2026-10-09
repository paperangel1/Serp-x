"""Functions = custom nodes (design §2, stage 6): a graph with an input and an output interface node, stored in the
library ~/.config/serpantinum/commands/functions/<id>.fn.json. Same conventions as commands: atomic writes, history
snapshots, trash, `format` versioning. A command may embed a copy of every function it uses (self-contained export)."""
import copy
import glob
import hashlib
import json
import os
import re

from . import paths, schema as S
from .model import CommandError, HISTORY_KEEP, TRASH_KEEP_DAYS, atomic_write, dump, slugify
from .util import read_json, read_text
from .xlogshim import log as xlog

FN_FORMAT = 1
RESERVED_PINS = ("exec", "exec_in", "exec_out")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def functions_dir():
    return os.path.join(paths.commands_dir(), "functions")


def canonical_sha256(fn):
    body = {k: v for k, v in fn.items() if k not in ("id", "imported")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def empty_function(fid, name, has_exec=True):
    return {"format": FN_FORMAT, "kind": "function", "id": fid, "name": name, "description": "", "icon": "function",
            "exec": bool(has_exec), "inputs": [], "outputs": [],
            "nodes": [{"id": S.FN_IN_ID, "type": S.FN_INPUT + "@1", "pos": [60, 60], "props": {}},
                      {"id": S.FN_OUT_ID, "type": S.FN_OUTPUT + "@1", "pos": [700, 60], "props": {}}],
            "wires": [], "variables": [], "comments": []}


def used_function_ids(graph):
    """Function ids called from the nodes of a command / function dict."""
    out = []
    for n in (graph or {}).get("nodes") or []:
        fid = S.fn_id_of(n.get("type", "")) if isinstance(n, dict) else None
        if fid and fid not in out:
            out.append(fid)
    return out


def closure(fids, lookup):
    """Every function reachable from fids (dependencies first), cycle-safe. lookup(fid) -> function dict | None."""
    order, seen = [], set()

    def visit(f):
        if f in seen:
            return
        seen.add(f)
        fn = lookup(f)
        if fn is None:
            return
        for g in used_function_ids(fn):
            visit(g)
        order.append(fn)
    for f in fids:
        visit(f)
    return order


def rewrite_calls(graph, idmap):
    """Point call nodes at other function ids (import conflict resolution)."""
    n_changed = 0
    for n in (graph or {}).get("nodes") or []:
        fid = S.fn_id_of(n.get("type", "")) if isinstance(n, dict) else None
        if fid and idmap.get(fid, fid) != fid:
            n["type"] = S.fn_type(idmap[fid])
            n_changed += 1
    return n_changed


class FnStore:
    def __init__(self, directory=None, history_dir=None, trash_dir=None, clock=None):
        import time
        self.dir = directory or functions_dir()
        self.history_dir, self.trash_dir, self.clock = history_dir, trash_dir, clock or time
        self.fns, self.files, self.errors, self._mtimes = {}, {}, {}, {}

    def load(self):
        self.fns, self.files, self.errors, self._mtimes = {}, {}, {}, {}
        for f in sorted(glob.glob(os.path.join(self.dir, "*.fn.json"))):
            try:
                fn = read_json(f)
                if not isinstance(fn, dict) or not fn.get("name"):
                    raise ValueError("нет поля name")
                fn.setdefault("id", os.path.basename(f)[:-len(".fn.json")])
                if not ID_RE.match(fn["id"]):
                    raise ValueError("недопустимый id функции")
                self.fns[fn["id"]] = fn
                self.files[fn["id"]] = f
                self._mtimes[f] = os.path.getmtime(f)
            except (OSError, ValueError) as e:
                self.errors[f] = str(e)
        return self

    def changed(self):
        return {f: os.path.getmtime(f) for f in glob.glob(os.path.join(self.dir, "*.fn.json"))} != self._mtimes

    def all(self):
        return sorted(self.fns.values(), key=lambda f: f["name"].lower())

    def get(self, fid):
        return self.fns.get(fid)

    def find(self, ref):
        if ref in self.fns:
            return self.fns[ref]
        low = (ref or "").strip().lower()
        exact = [f for f in self.fns.values() if f["name"].lower() == low]
        if len(exact) == 1:
            return exact[0]
        if len(exact) > 1:
            raise CommandError("ambiguous", "Несколько функций с именем «%s»: укажите идентификатор" % ref)
        pref = [f for f in self.fns.values() if f["name"].lower().startswith(low)]
        if len(pref) == 1:
            return pref[0]
        if len(pref) > 1:
            raise CommandError("ambiguous", "Неоднозначно «%s»: %s" % (ref, ", ".join(sorted(f["name"] for f in pref))))
        raise CommandError("not_found", "Функция «%s» не найдена" % ref)

    # ---- names / ids
    def name_taken(self, name, except_id=None):
        low = name.strip().lower()
        return any(f["name"].strip().lower() == low and f["id"] != except_id for f in self.fns.values())

    def unique_name(self, base):
        name, n = base, 2
        while self.name_taken(name):
            name = "%s %d" % (base, n)
            n += 1
        return name

    def new_id(self, name):
        n = 0
        while True:
            fid = "%s-%s" % ((re.sub(r"[^a-z0-9]+", "", slugify(name).lower())[:12] or "fn"),
                             hashlib.sha1(("%s%s%d" % (name, self.clock.time(), n)).encode()).hexdigest()[:6])
            if fid not in self.fns:
                return fid
            n += 1

    # ---- save / history
    def save(self, fn):
        fn = copy.deepcopy(fn)
        fn["format"], fn["kind"] = FN_FORMAT, "function"
        if not fn.get("id"):
            fn["id"] = self.new_id(fn["name"])
        if not ID_RE.match(fn["id"]):
            raise CommandError("bad_id", "Недопустимый идентификатор функции")
        path = self.files.get(fn["id"]) or os.path.join(self.dir, fn["id"] + ".fn.json")
        if os.path.exists(path) and self.history_dir:
            hd = os.path.join(self.history_dir, "functions", fn["id"])
            os.makedirs(hd, exist_ok=True)
            ms = int(self.clock.time() * 1000)
            while os.path.exists(os.path.join(hd, "%d.json" % ms)):
                ms += 1
            atomic_write(os.path.join(hd, "%d.json" % ms), read_text(path))
            for old in sorted(os.listdir(hd))[:-HISTORY_KEEP]:
                os.remove(os.path.join(hd, old))
        atomic_write(path, dump(fn))
        self.fns[fn["id"]], self.files[fn["id"]] = fn, path
        self._mtimes[path] = os.path.getmtime(path)
        xlog.info("function saved", fn=fn["id"], name=fn["name"], nodes=len(fn.get("nodes", [])))
        return fn

    def create(self, name, fn=None):
        name = (name or "").strip()
        if not name:
            raise CommandError("bad_name", "Введите название функции")
        if self.name_taken(name):
            raise CommandError("name_taken", "Функция «%s» уже есть: выберите другое название" % name)
        fid = self.new_id(name)
        d = copy.deepcopy(fn) if fn else empty_function(fid, name)
        d["id"], d["name"] = fid, name
        return self.save(d)

    def rename(self, fn, name, description=None):
        name = (name or "").strip()
        if not name:
            raise CommandError("bad_name", "Введите название функции")
        if self.name_taken(name, except_id=fn["id"]):
            raise CommandError("name_taken", "Функция «%s» уже есть: выберите другое название" % name)
        cur = dict(self.fns[fn["id"]], name=name)
        if description is not None:
            cur["description"] = description
        return self.save(cur)

    def duplicate(self, fn, new_name=None):
        src = self.fns[fn["id"]]
        name = (new_name or "").strip() or self.unique_name("%s (копия)" % src["name"])
        if self.name_taken(name):
            raise CommandError("name_taken", "Функция «%s» уже есть: выберите другое название" % name)
        d = copy.deepcopy(src)
        d["id"], d["name"] = self.new_id(name), name
        d.pop("imported", None)
        return self.save(d)

    # ---- usage / delete
    def usages(self, fid, cmd_store):
        """Commands and other functions that call fid: [{kind, id, name}]."""
        out = []
        for c in cmd_store.all():
            if fid in used_function_ids(c):
                out.append({"kind": "command", "id": c["id"], "name": c["name"]})
        for f in self.all():
            if f["id"] != fid and fid in used_function_ids(f):
                out.append({"kind": "function", "id": f["id"], "name": f["name"]})
        return out

    def delete(self, fn):
        if not self.trash_dir:
            raise CommandError("no_trash", "Корзина недоступна")
        fid, path = fn["id"], self.files.get(fn["id"])
        if not path or not os.path.exists(path):
            raise CommandError("not_found", "Файл функции не найден")
        td = os.path.join(self.trash_dir, "functions")
        os.makedirs(td, exist_ok=True)
        dst = os.path.join(td, "%s.%d.fn.json" % (fid, int(self.clock.time() * 1000)))
        os.replace(path, dst)
        for d in (self.fns, self.files):
            d.pop(fid, None)
        cutoff = self.clock.time() - TRASH_KEEP_DAYS * 86400
        for f in os.listdir(td):
            p = os.path.join(td, f)
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        xlog.info("function deleted", fn=fid, name=fn["name"])
        return {"id": fid, "name": fn["name"], "file": dst}

    # ---- export / import
    def package(self, fn):
        """A .sfn package: the function plus every function it (transitively) calls."""
        body = copy.deepcopy(self.fns[fn["id"]])
        body.pop("imported", None)
        deps = [copy.deepcopy(f) for f in closure(used_function_ids(body), self.fns.get) if f["id"] != body["id"]]
        return {"format": FN_FORMAT, "kind": "serpantinum-function", "name": body["name"], "sha256": canonical_sha256(body),
                "function": body, "deps": deps}

    def export(self, fn, path):
        pkg = self.package(fn)
        path = os.path.abspath(os.path.expanduser(path))
        if os.path.isdir(path):
            path = os.path.join(path, slugify(fn["name"]) + ".sfn")
        atomic_write(path, dump(pkg))
        return {"path": path, "bytes": os.path.getsize(path), "functions": 1 + len(pkg["deps"])}

    def import_functions(self, fns):
        """Merge function dicts into the library without ever replacing a local function (id + content hash):
        same id and same content -> reuse; same id, other content -> imported under a new id and name; same content
        under another id -> reuse that one. Returns (idmap old->library id, report items)."""
        by_id = {f["id"]: f for f in fns if isinstance(f, dict) and f.get("id")}
        idmap, items = {}, []
        for f in closure(list(by_id), by_id.get):
            f = copy.deepcopy(f)
            old = f["id"]
            rewrite_calls(f, idmap)
            h = canonical_sha256(f)
            local = self.fns.get(old)
            if local is not None and canonical_sha256(local) == h:
                idmap[old] = old
                items.append({"id": old, "name": local["name"], "status": "same"})
                continue
            twin = next((x for x in self.fns.values() if canonical_sha256(x) == h), None)
            if twin is not None:
                idmap[old] = twin["id"]
                items.append({"id": twin["id"], "name": twin["name"], "status": "same"})
                continue
            status = "new"
            if local is not None or not ID_RE.match(old):
                f["id"] = self.new_id(f.get("name", "fn"))
                status = "renamed"
            if self.name_taken(f["name"]):
                f["name"] = self.unique_name("%s (импорт)" % f["name"])
                status = "renamed"
            f["imported"] = True
            saved = self.save(f)
            idmap[old] = saved["id"]
            items.append({"id": saved["id"], "name": saved["name"], "status": status, "was": old if status == "renamed" else None})
        xlog.info("functions imported", count=len(items), new=len([i for i in items if i["status"] != "same"]))
        return idmap, items

    def import_package(self, path):
        try:
            data = read_json(path)
        except (OSError, ValueError) as e:
            raise CommandError("bad_file", "Не удалось прочитать файл: %s" % e)
        if isinstance(data, dict) and isinstance(data.get("function"), dict):
            fn, deps, declared = data["function"], data.get("deps") or [], data.get("sha256")
        else:
            fn, deps, declared = data, [], None
        if not isinstance(fn, dict) or not fn.get("name") or not isinstance(fn.get("nodes"), list):
            raise CommandError("bad_file", "Файл не похож на функцию")
        if declared and declared != canonical_sha256({k: v for k, v in fn.items() if k != "imported"}):
            raise CommandError("bad_checksum", "Контрольная сумма пакета не совпадает: файл изменён")
        idmap, items = self.import_functions([fn] + [d for d in deps if isinstance(d, dict)])
        main = idmap.get(fn.get("id"), fn.get("id"))
        return {"id": main, "name": self.fns[main]["name"] if main in self.fns else fn["name"], "functions": items}

    def embed(self, cmd):
        """A copy of the command with every function it uses (transitively) embedded: self-contained export."""
        out = copy.deepcopy(cmd)
        out.pop("functions", None)
        fns = closure(used_function_ids(cmd), self.fns.get)
        if fns:
            out["functions"] = [copy.deepcopy(f) for f in fns]
        return out

    def ingest(self, cmd):
        """Take the embedded functions of a command into the library (conflicts as in import_functions) and return
        (command without `functions` with call nodes remapped, report items)."""
        cmd = copy.deepcopy(cmd)
        embedded = cmd.pop("functions", None) or []
        if not embedded:
            return cmd, []
        idmap, items = self.import_functions(embedded)
        rewrite_calls(cmd, idmap)
        return cmd, items
