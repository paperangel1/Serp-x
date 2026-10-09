"""Command files (~/.config/serpantinum/commands/*.cmd.json): load, save with history, capabilities, import."""
import copy
import glob
import hashlib
import json
import os
import re
import time

from . import paths, schema as S
from .util import read_json, read_text

FORMAT = 1
HISTORY_KEEP = 20
TRASH_KEEP_DAYS = 30
DEFAULT_POLICY = {"reentrancy": "skip", "max_runs_per_min": 5, "timeout_s": 600, "hold_max_h": 24}
SUSPICIOUS_CAPS = ("exec.script", "net.http", "ssh.server", "fs.write", "clipboard.read", "vpn.control", "file.write", "file.write.any",
                   "trigger.clipboard", "trigger.notifications", "net.gemini", "servers.run", "servers.run.typed",
                   "window.close", "link.open", "screen.capture")


def is_risky_cap(c):
    return c in SUSPICIOUS_CAPS or c.startswith(("fs.write", "file.write"))


class CommandError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def slugify(name):
    s = re.sub(r"[^\w-]+", "-", name.strip().lower(), flags=re.UNICODE).strip("-")
    return s or "command"


def policy_of(cmd):
    p = dict(DEFAULT_POLICY)
    p.update(cmd.get("policy") or {})
    return p


def compute_capabilities(cmd, sch):
    caps = set()
    sch = sch.with_functions(cmd.get("functions"))          # embedded copies of functions count too
    for n in cmd.get("nodes", []):
        nd, err = sch.get(n.get("type", ""))
        if nd and not nd.planned:                      # a planned node grants nothing: it cannot run yet
            caps.update(nd.capabilities)
            for pin, extra in nd.capabilities_if.items():
                if (n.get("props") or {}).get(pin):
                    caps.update(extra)
    return sorted(caps)


def canonical_sha256(cmd):
    body = {k: v for k, v in cmd.items() if k not in ("enabled", "approved_capabilities", "imported")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def dump(cmd):
    return json.dumps(cmd, ensure_ascii=False, indent=2) + "\n"


class Store:
    """All command files of one directory; found by id, name or file stem."""

    def __init__(self, directory=None, history_dir=None, clock=time, trash_dir=None):
        self.dir = directory or paths.commands_dir()
        self.history_dir = history_dir
        self.trash_dir = trash_dir
        self.clock = clock
        self.cmds = {}          # id -> command dict
        self.files = {}         # id -> path
        self.errors = {}        # path -> message
        self._mtimes = {}

    def load(self):
        self.cmds, self.files, self.errors, self._mtimes = {}, {}, {}, {}
        for f in sorted(glob.glob(os.path.join(self.dir, "*.cmd.json"))):
            try:
                cmd = read_json(f)
                if not isinstance(cmd, dict) or not cmd.get("name"):
                    raise ValueError("нет поля name")
                cmd.setdefault("id", os.path.basename(f)[:-len(".cmd.json")])
                self.cmds[cmd["id"]] = cmd
                self.files[cmd["id"]] = f
                self._mtimes[f] = os.path.getmtime(f)
            except (OSError, ValueError) as e:
                self.errors[f] = str(e)
        return self

    def changed(self):
        cur = {f: os.path.getmtime(f) for f in glob.glob(os.path.join(self.dir, "*.cmd.json"))}
        return cur != self._mtimes

    def all(self):
        return sorted(self.cmds.values(), key=lambda c: c["name"].lower())

    def find(self, ref):
        """By id, file stem, exact name (any case) or a unique name prefix."""
        if ref in self.cmds:
            return self.cmds[ref]
        low = ref.strip().lower()
        for cid, f in self.files.items():
            if os.path.basename(f)[:-len(".cmd.json")] == ref:
                return self.cmds[cid]
        exact = [c for c in self.cmds.values() if c["name"].lower() == low]
        if len(exact) == 1:
            return exact[0]
        if len(exact) > 1:
            raise CommandError("ambiguous", "Несколько команд с именем «%s»: укажите идентификатор" % ref)
        pref = [c for c in self.cmds.values() if c["name"].lower().startswith(low)]
        if len(pref) == 1:
            return pref[0]
        if len(pref) > 1:
            raise CommandError("ambiguous", "Неоднозначно «%s»: %s" % (ref, ", ".join(sorted(c["name"] for c in pref))))
        raise CommandError("not_found", "Команда «%s» не найдена" % ref)

    def path_for(self, cmd):
        """A command keeps its file; a new one never overwrites another command that has the same name."""
        known = self.files.get(cmd.get("id"))
        if known:
            return known
        base = slugify(cmd["name"])
        path, n = os.path.join(self.dir, base + ".cmd.json"), 2
        while os.path.exists(path):
            path = os.path.join(self.dir, "%s-%d.cmd.json" % (base, n))
            n += 1
        return path

    def save(self, cmd, sch=None):
        cmd = copy.deepcopy(cmd)
        cmd["format"] = FORMAT
        if not cmd.get("id"):
            cmd["id"] = hashlib.sha1(("%s%s" % (cmd["name"], self.clock.time())).encode()).hexdigest()[:12]
        if sch is not None:
            cmd["capabilities"] = compute_capabilities(cmd, sch)
        path = self.path_for(cmd)
        if os.path.exists(path) and self.history_dir:
            hd = os.path.join(self.history_dir, cmd["id"])
            os.makedirs(hd, exist_ok=True)
            ms = int(self.clock.time() * 1000)
            snap = os.path.join(hd, "%d.json" % ms)
            while os.path.exists(snap):          # two saves within one millisecond must not overwrite a snapshot
                ms += 1
                snap = os.path.join(hd, "%d.json" % ms)
            atomic_write(snap, read_text(path))
            for old in sorted(os.listdir(hd))[:-HISTORY_KEEP]:
                os.remove(os.path.join(hd, old))
        atomic_write(path, dump(cmd))
        self.cmds[cmd["id"]] = cmd
        self.files[cmd["id"]] = path
        self._mtimes[path] = os.path.getmtime(path)
        return cmd

    def set_flag(self, cmd, **kv):
        cmd = dict(self.cmds[cmd["id"]])
        cmd.update(kv)
        return self.save(cmd)

    # ---- editing support: names, create / duplicate / rename, trash, export, history ----------------------------
    def name_taken(self, name, except_id=None):
        low = name.strip().lower()
        return any(c["name"].strip().lower() == low and c["id"] != except_id for c in self.cmds.values())

    def unique_name(self, base):
        name, n = base, 2
        while self.name_taken(name):
            name = "%s %d" % (base, n)
            n += 1
        return name

    def _new_id(self, name):
        return hashlib.sha1(("%s%s%s" % (name, self.clock.time(), len(self.cmds))).encode()).hexdigest()[:12]

    def create(self, name, template=None, sch=None):
        """A new command: empty (one «Вручную» event node) or a copy of a template command (example file)."""
        name = (name or "").strip()
        if not name:
            raise CommandError("bad_name", "Введите название команды")
        if self.name_taken(name):
            raise CommandError("name_taken", "Команда «%s» уже есть: выберите другое название" % name)
        if template is None:
            cmd = {"format": FORMAT, "name": name, "description": "", "enabled": True,
                   "nodes": [{"id": "n1", "type": "event.manual@1", "pos": [60, 60], "props": {}}], "wires": [],
                   "comments": [], "variables": [], "approved_capabilities": []}
        else:
            cmd = copy.deepcopy(template)
            cmd["name"] = name
            cmd["enabled"] = bool(template.get("enabled", True))      # a gallery copy stays disabled until approved
            cmd.pop("imported", None)
            cmd.pop("gallery", None)
        cmd["id"] = self._new_id(name)
        return self.save(cmd, sch)

    def duplicate(self, cmd, new_name=None, sch=None):
        src = self.cmds[cmd["id"]]
        name = (new_name or "").strip() or self.unique_name("%s (копия)" % src["name"])
        if self.name_taken(name):
            raise CommandError("name_taken", "Команда «%s» уже есть: выберите другое название" % name)
        dup = copy.deepcopy(src)
        dup["id"] = self._new_id(name)
        dup["name"] = name
        dup["enabled"] = False          # a copy must never double-fire an automation before the user turns it on
        dup.pop("imported", None)
        return self.save(dup, sch)

    def rename(self, cmd, new_name, sch=None):
        new_name = (new_name or "").strip()
        if not new_name:
            raise CommandError("bad_name", "Введите название команды")
        if self.name_taken(new_name, except_id=cmd["id"]):
            raise CommandError("name_taken", "Команда «%s» уже есть: выберите другое название" % new_name)
        cur = dict(self.cmds[cmd["id"]])
        cur["name"] = new_name
        return self.save(cur, sch)

    def _trash_entries(self):
        out = []
        if self.trash_dir and os.path.isdir(self.trash_dir):
            for f in os.listdir(self.trash_dir):
                if not f.endswith(".cmd.json"):
                    continue
                stem = f[:-len(".cmd.json")]
                cid, _, ts = stem.rpartition(".")
                try:
                    data = read_json(os.path.join(self.trash_dir, f))
                    out.append({"id": cid, "name": data.get("name", cid), "deleted_at": int(ts) / 1000.0,
                                "file": os.path.join(self.trash_dir, f), "nodes": len(data.get("nodes", []))})
                except (OSError, ValueError):
                    continue
        return sorted(out, key=lambda e: -e["deleted_at"])

    def trash_list(self):
        return self._trash_entries()

    def delete(self, cmd):
        """Move the command file to the trash (restorable for TRASH_KEEP_DAYS days); returns the trash entry."""
        if not self.trash_dir:
            raise CommandError("no_trash", "Корзина недоступна")
        cid = cmd["id"]
        path = self.files.get(cid)
        if not path or not os.path.exists(path):
            raise CommandError("not_found", "Файл команды не найден")
        os.makedirs(self.trash_dir, exist_ok=True)
        dst = os.path.join(self.trash_dir, "%s.%d.cmd.json" % (cid, int(self.clock.time() * 1000)))
        os.replace(path, dst)
        for d in (self.cmds, self.files):
            d.pop(cid, None)
        self.purge_trash()
        return {"id": cid, "name": cmd["name"], "file": dst}

    def restore(self, ref, sch=None):
        """Bring a deleted command back (by id or exact name; the newest deletion wins). A taken name gets a suffix."""
        low = (ref or "").strip().lower()
        entries = [e for e in self._trash_entries() if e["id"] == ref or e["name"].lower() == low]
        if not entries:
            raise CommandError("not_found", "В корзине нет «%s»" % ref)
        e = entries[0]
        cmd = read_json(e["file"])
        if cmd.get("id") in self.cmds:
            cmd["id"] = self._new_id(cmd.get("name", "restored"))
        if self.name_taken(cmd["name"]):
            cmd["name"] = self.unique_name("%s (восстановлена)" % cmd["name"])
        saved = self.save(cmd, sch)
        os.remove(e["file"])
        return saved

    def purge_trash(self, days=TRASH_KEEP_DAYS):
        cutoff = self.clock.time() - days * 86400
        removed = 0
        for e in self._trash_entries():
            if e["deleted_at"] < cutoff:
                try:
                    os.remove(e["file"])
                    removed += 1
                except OSError:
                    pass
        return removed

    def export(self, cmd, path, sch, fnstore=None):
        """Write a .scmd package: command (+ embedded copies of its functions) + declared rights + sha256 (design §2)."""
        body = copy.deepcopy(self.cmds[cmd["id"]])
        if fnstore is not None:
            body = fnstore.embed(body)
        for k in ("approved_capabilities", "imported"):
            body.pop(k, None)
        pkg = {"format": FORMAT, "kind": "serpantinum-command", "name": body["name"], "capabilities": compute_capabilities(body, sch),
               "sha256": canonical_sha256(body), "command": body}
        path = os.path.abspath(os.path.expanduser(path))
        if os.path.isdir(path):
            path = os.path.join(path, slugify(body["name"]) + ".scmd")
        atomic_write(path, dump(pkg))
        return {"path": path, "bytes": os.path.getsize(path)}

    def history(self, cmd):
        hd = os.path.join(self.history_dir or "", cmd["id"])
        out = []
        if self.history_dir and os.path.isdir(hd):
            for f in sorted(os.listdir(hd), reverse=True):
                try:
                    out.append({"ts": int(f[:-len(".json")]) / 1000.0, "name": f, "bytes": os.path.getsize(os.path.join(hd, f))})
                except (ValueError, OSError):
                    continue
        return out

    def revert(self, cmd, ts_name, sch=None):
        """Make an older snapshot the current version (the current one is snapshotted by save())."""
        hd = os.path.join(self.history_dir or "", cmd["id"])
        snap = os.path.join(hd, os.path.basename(ts_name))
        if not self.history_dir or not os.path.isfile(snap):
            raise CommandError("not_found", "Такой версии нет в истории")
        old = read_json(snap)
        old["id"] = cmd["id"]
        cur = self.cmds[cmd["id"]]
        if self.name_taken(old.get("name", ""), except_id=cmd["id"]):
            old["name"] = cur["name"]
        for k in ("enabled", "approved_capabilities", "imported"):
            if k in cur:
                old[k] = cur[k]
        return self.save(old, sch)


def approved_ok(cmd, caps):
    """Capabilities not yet approved by the user (empty list = may run)."""
    return sorted(set(caps) - set(cmd.get("approved_capabilities") or []))


def import_package(path, store, sch, fnstore=None):
    """Import a command / .scmd package: recomputed capabilities, disabled, approvals dropped."""
    try:
        data = read_json(path)
    except (OSError, ValueError) as e:
        raise CommandError("bad_file", "Не удалось прочитать файл: %s" % e)
    pkg_sha, declared = None, None
    if isinstance(data, dict) and "command" in data and isinstance(data["command"], dict):
        pkg_sha, declared, cmd = data.get("sha256"), data.get("capabilities"), data["command"]
    else:
        cmd = data
    if not isinstance(cmd, dict) or not cmd.get("name") or not isinstance(cmd.get("nodes"), list):
        raise CommandError("bad_file", "Файл не похож на команду")
    warnings = []
    if pkg_sha and pkg_sha != canonical_sha256(cmd):
        raise CommandError("bad_checksum", "Контрольная сумма пакета не совпадает: файл изменён")
    actual = compute_capabilities(cmd, sch)
    fn_report = []
    if declared is not None and sorted(declared) != actual:
        warnings.append("Заявленные права %s не совпадают с реальными %s" % (sorted(declared), actual))
    suspicious = []
    osch = sch.with_functions(cmd.get("functions"))
    for n in cmd["nodes"]:
        nd, _ = osch.get(n.get("type", ""))
        if nd and (nd.danger != "none" or any(is_risky_cap(c) for c in nd.capabilities)):
            suspicious.append({"node": n.get("id"), "type": nd.type_string, "name": nd.label("ru")})
    cmd = copy.deepcopy(cmd)
    if cmd.get("functions") and fnstore is not None:        # embedded functions go to the library, never over local ones
        cmd, fn_report = fnstore.ingest(cmd)
        sch.set_functions(list(fnstore.fns.values()))
        for it in fn_report:
            if it["status"] == "renamed":
                warnings.append("Функция «%s» уже была в библиотеке с другим содержимым: импортирована как «%s»" % (it.get("was"), it["name"]))
    names = {c["name"].lower() for c in store.cmds.values()}
    if cmd["name"].lower() in names:
        cmd["name"] += " (импорт)"
        warnings.append("Имя занято: команда сохранена как «%s»" % cmd["name"])
    cmd.pop("id", None)
    cmd.update({"enabled": False, "imported": True, "approved_capabilities": []})
    saved = store.save(cmd, sch)
    return {"command": saved["name"], "id": saved["id"], "capabilities": actual, "suspicious": suspicious,
            "warnings": warnings, "enabled": False, "functions": fn_report}
