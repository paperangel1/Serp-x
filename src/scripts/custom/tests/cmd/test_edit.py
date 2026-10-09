"""Editing support of the engine (stage 3): create / save / rename / duplicate / delete+restore / export+import /
history / revert in the Store, the API guards on save, and the CLI that the editor window drives."""
import json
import os
import subprocess
import sys
import time
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from xcmd import model, schema as S
from xcmd.api import ApiError
from xcmd.model import CommandError, Store


def hello(name="Привет", **kw):
    nodes, wires = notify_chain("Привет, мир")
    return make_cmd(name, nodes, wires, **kw)


class StoreEditTests(unittest.TestCase):
    def setUp(self):
        self.env = C.Env()
        self.addCleanup(self.env.restore)
        self.sch = S.load_schema()
        self.clock = C.xclock.FakeClock() if hasattr(C.xclock, "FakeClock") else time
        self.store = Store(self.env.cmds, history_dir=os.path.join(self.env.state, "history"), clock=time,
                           trash_dir=os.path.join(self.env.state, "trash"))

    def test_create_empty_and_from_template_and_name_rules(self):
        c = self.store.create("Новая", None, self.sch)
        self.assertEqual([n["type"] for n in c["nodes"]], ["event.manual@1"])
        self.assertTrue(os.path.exists(self.store.files[c["id"]]))
        with self.assertRaises(CommandError) as cm:
            self.store.create("новая", None, self.sch)            # same name, any case
        self.assertEqual(cm.exception.code, "name_taken")
        with self.assertRaises(CommandError) as cm:
            self.store.create("   ", None, self.sch)
        self.assertEqual(cm.exception.code, "bad_name")
        tpl = hello("Образец", id="example-x", imported=True)
        c2 = self.store.create("Из образца", tpl, self.sch)
        self.assertNotEqual(c2["id"], "example-x")                # a copy never shares the id of its template
        self.assertEqual(len(c2["nodes"]), 2)
        self.assertNotIn("imported", c2)

    def test_duplicate_is_disabled_and_gets_a_free_name(self):
        c = self.store.save(hello("Привет", id="p1"), self.sch)
        d1 = self.store.duplicate(c, None, self.sch)
        d2 = self.store.duplicate(c, None, self.sch)
        self.assertEqual(d1["name"], "Привет (копия)")
        self.assertEqual(d2["name"], "Привет (копия) 2")
        self.assertFalse(d1["enabled"])
        self.assertNotEqual(d1["id"], c["id"])
        self.assertNotEqual(self.store.files[d1["id"]], self.store.files[c["id"]])
        with self.assertRaises(CommandError):
            self.store.duplicate(c, "Привет", self.sch)

    def test_rename_keeps_file_and_id_and_rejects_taken_names(self):
        a = self.store.save(hello("Первая", id="a"), self.sch)
        self.store.save(hello("Вторая", id="b"), self.sch)
        path = self.store.files["a"]
        r = self.store.rename(a, "Третья", self.sch)
        self.assertEqual((r["id"], r["name"], self.store.files["a"]), ("a", "Третья", path))
        with self.assertRaises(CommandError):
            self.store.rename(r, "вторая", self.sch)
        self.assertEqual(self.store.rename(r, "Третья", self.sch)["name"], "Третья")   # own name is fine

    def test_delete_to_trash_restore_and_purge(self):
        c = self.store.save(hello("Удаляемая", id="del1"), self.sch)
        path = self.store.files["del1"]
        res = self.store.delete(c)
        self.assertFalse(os.path.exists(path))
        self.assertNotIn("del1", self.store.cmds)
        self.assertTrue(os.path.exists(res["file"]))
        items = self.store.trash_list()
        self.assertEqual([i["id"] for i in items], ["del1"])
        # another command takes the name meanwhile: the restored one gets a suffix instead of clobbering
        self.store.save(hello("Удаляемая", id="other"), self.sch)
        back = self.store.restore("del1", self.sch)
        self.assertEqual(back["id"], "del1")
        self.assertEqual(back["name"], "Удаляемая (восстановлена)")
        self.assertEqual(self.store.trash_list(), [])
        with self.assertRaises(CommandError) as cm:
            self.store.restore("nothing")
        self.assertEqual(cm.exception.code, "not_found")
        # purge: entries older than N days go, newer stay
        self.store.delete(back)
        entry = self.store.trash_list()[0]
        old = entry["file"].replace(".cmd.json", "").rsplit(".", 1)[0] + ".%d.cmd.json" % int((time.time() - 40 * 86400) * 1000)
        os.rename(entry["file"], old)
        self.assertEqual(self.store.purge_trash(30), 1)
        self.assertEqual(self.store.trash_list(), [])

    def test_export_and_import_roundtrip_with_checksum(self):
        c = self.store.save(C.approve_all(hello("Экспорт", id="ex1"), self.sch), self.sch)
        out = os.path.join(self.env.root, "out")
        os.makedirs(out)
        res = self.store.export(c, out, self.sch)                 # a directory: file name from the title
        self.assertTrue(res["path"].endswith("экспорт.scmd"))
        with open(res["path"], encoding="utf-8") as f:
            pkg = json.load(f)
        self.assertEqual(pkg["capabilities"], ["notify.show"])
        self.assertNotIn("approved_capabilities", pkg["command"])
        # import into a clean store: disabled, approvals dropped, not trusted
        other = Store(os.path.join(self.env.root, "other"), clock=time).load()
        imp = model.import_package(res["path"], other, self.sch)
        self.assertFalse(imp["enabled"])
        saved = other.find(imp["id"])
        self.assertEqual(saved["approved_capabilities"], [])
        # a tampered package is refused
        pkg["command"]["name"] = "Подделка"
        bad = os.path.join(self.env.root, "bad.scmd")
        with open(bad, "w", encoding="utf-8") as f:
            json.dump(pkg, f, ensure_ascii=False)
        with self.assertRaises(CommandError) as cm:
            model.import_package(bad, other, self.sch)
        self.assertEqual(cm.exception.code, "bad_checksum")

    def test_history_and_revert_keep_flags_and_name_rules(self):
        c = self.store.save(hello("История", id="h1"), self.sch)
        c2 = dict(c)
        c2["description"] = "вторая версия"
        self.store.save(c2, self.sch)
        time.sleep(0.01)
        c3 = dict(c2)
        c3["description"] = "третья версия"
        c3["enabled"] = False
        self.store.save(c3, self.sch)
        hist = self.store.history(c3)
        self.assertGreaterEqual(len(hist), 2)
        first = hist[-1]["name"]                                   # oldest snapshot = version one (no description)
        back = self.store.revert(c3, first, self.sch)
        self.assertEqual(back.get("description", ""), "")
        self.assertFalse(back["enabled"])                          # engine-owned flags stay as they are now
        with self.assertRaises(CommandError):
            self.store.revert(c3, "nope.json", self.sch)
        self.assertEqual(len(self.store.history(back)), len(hist) + 1)   # the revert itself is snapshotted


class ApiEditTests(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    async def test_save_protects_engine_flags_and_names(self):
        api = self.rt.api
        cmd = C.approve_all(hello("Защита", id="g1"), self.rt.sch)
        self.add(cmd, approve=True)
        known = self.rt.store.find("g1")
        self.assertEqual(known["approved_capabilities"], ["notify.show"])
        evil = json.loads(json.dumps(known))
        evil["approved_capabilities"] = ["net.http", "exec.script"]    # a client must not widen its own rights
        evil["imported"] = True
        evil["enabled"] = False
        evil["nodes"].append(node("x", "action.notify@1", title="ещё"))
        res = await api.call("save", {"command": evil})
        saved = self.rt.store.find("g1")
        self.assertEqual(saved["approved_capabilities"], ["notify.show"])
        self.assertNotIn("imported", saved)
        self.assertTrue(saved["enabled"])
        self.assertEqual(len(saved["nodes"]), 3)
        self.assertEqual(res["name"], "Защита")
        # a brand-new command from the client starts with no approvals at all
        fresh = {"name": "Новая из клиента", "nodes": [node("e", "event.manual@1")], "wires": [], "approved_capabilities": ["net.http"]}
        await api.call("save", {"command": fresh})
        self.assertEqual(self.rt.store.find("Новая из клиента")["approved_capabilities"], [])
        # name collision and malformed documents
        with self.assertRaises(ApiError) as cm:
            await api.call("save", {"command": {"name": "защита", "nodes": [], "wires": []}})
        self.assertEqual(cm.exception.code, "name_taken")
        with self.assertRaises(ApiError):
            await api.call("save", {"command": {"name": "", "nodes": [], "wires": []}})
        with self.assertRaises(ApiError):
            await api.call("save", {"command": {"name": "Без списков"}})

    async def test_management_methods(self):
        api = self.rt.api
        r = await api.call("new", {"name": "Создана"})
        self.assertEqual(r["name"], "Создана")
        d = await api.call("duplicate", {"ref": "Создана"})
        self.assertEqual(d["name"], "Создана (копия)")
        r2 = await api.call("rename", {"ref": "Создана (копия)", "name": "Вторая"})
        self.assertEqual(r2["name"], "Вторая")
        res = await api.call("delete", {"ref": "Вторая"})
        self.assertEqual(res["deleted"], "Вторая")
        listing = await api.call("list", {})
        self.assertEqual([c["name"] for c in listing["commands"]], ["Создана"])
        trash = await api.call("trash", {})
        self.assertEqual([i["name"] for i in trash["items"]], ["Вторая"])
        back = await api.call("restore", {"ref": "Вторая"})
        self.assertEqual(back["name"], "Вторая")
        with self.assertRaises(ApiError) as cm:
            await api.call("rename", {"ref": "Вторая", "name": "Создана"})
        self.assertEqual(cm.exception.code, "name_taken")
        hist = await api.call("history", {"ref": "Создана"})
        self.assertIsInstance(hist["versions"], list)
        out = os.path.join(self.env.root, "x.scmd")
        ex = await api.call("export", {"ref": "Создана", "path": out})
        self.assertTrue(os.path.exists(ex["path"]))


class CliEditTests(unittest.TestCase):
    def setUp(self):
        self.env = C.Env()
        self.addCleanup(self.env.restore)
        self.proc_env = self.env.env_for_subprocess()

    def x(self, *args, stdin=None):
        r = subprocess.run([sys.executable, "-m", "xcmd", *args], capture_output=True, text=True, env=self.proc_env,
                           cwd=self.env.root, timeout=60, input=stdin)
        return r.returncode, r.stdout, r.stderr

    def j(self, *args, stdin=None):
        rc, out, err = self.x("--json", *args, stdin=stdin)
        return rc, (json.loads(out) if out.strip() else None), err

    def test_validate_inline_and_save_variants(self):
        cmd = hello("Инлайн")
        rc, rep, _ = self.j("validate", "--cmd-json", json.dumps(cmd))
        self.assertEqual(rc, 0)
        self.assertTrue(rep["ok"])
        bad = json.loads(json.dumps(cmd))
        bad["wires"] = []                                          # the notify node is now unreachable: warning only
        rc, rep, _ = self.j("validate", "--stdin", stdin=json.dumps(bad))
        self.assertEqual(rc, 0)
        self.assertTrue(any(w["code"] == "unreachable" for w in rep["warnings"]))
        broken = {"name": "x", "nodes": [node("e", "event.manual@1"), node("a", "action.notify@1")], "wires": [wire("e", "exec", "a", "nope")]}
        rc, rep, _ = self.j("validate", "--cmd-json", json.dumps(broken))
        self.assertEqual(rc, 1)
        self.assertFalse(rep["ok"])
        rc, res, _ = self.j("save", "--cmd-json", json.dumps(cmd))
        self.assertEqual(rc, 0)
        self.assertTrue(res["report"]["ok"])
        path = os.path.join(self.env.cmds, os.listdir(self.env.cmds)[0])
        self.assertTrue(path.endswith(".cmd.json"))
        # the file written by `save` is what `get` returns
        rc, got, _ = self.j("get", "Инлайн")
        self.assertEqual(got["name"], "Инлайн")
        self.assertEqual(got["format"], 1)
        rc, _, err = self.x("save")
        self.assertEqual(rc, 2)

    def test_new_duplicate_rename_delete_restore_export(self):
        rc, r, _ = self.j("new", "--name", "Первая")
        self.assertEqual(rc, 0)
        rc, d, _ = self.j("duplicate", "Первая")
        self.assertEqual(d["name"], "Первая (копия)")
        rc, _, err = self.x("rename", "Первая", "Первая (копия)")
        self.assertEqual(rc, 1)
        self.assertIn("уже есть", err)
        rc, r, _ = self.j("rename", "Первая (копия)", "Вторая")
        self.assertEqual(r["name"], "Вторая")
        rc, r, _ = self.j("delete", "Вторая")
        self.assertEqual(r["deleted"], "Вторая")
        rc, t, _ = self.j("trash")
        self.assertEqual([i["name"] for i in t["items"]], ["Вторая"])
        rc, r, _ = self.j("restore", "Вторая")
        self.assertEqual(r["name"], "Вторая")
        out = os.path.join(self.env.root, "dl")
        os.makedirs(out)
        rc, r, _ = self.j("export", "Первая", out)
        self.assertTrue(r["path"].endswith("первая.scmd"))
        rc, imp, _ = self.j("import", r["path"])
        self.assertEqual(rc, 0)
        self.assertEqual(imp["command"], "Первая (импорт)")
        rc, _, _ = self.x("purge", "--days", "30")
        self.assertEqual(rc, 0)

    def test_from_template_and_import_candidates(self):
        tpl = os.path.join(self.env.root, "tpl.cmd.json")
        with open(tpl, "w", encoding="utf-8") as f:
            json.dump(hello("Образец", id="tpl"), f, ensure_ascii=False)
        rc, r, _ = self.j("new", "--name", "По образцу", "--from", tpl)
        self.assertEqual(rc, 0)
        rc, got, _ = self.j("get", "По образцу")
        self.assertEqual(len(got["nodes"]), 2)
        dl = os.path.join(self.env.root, "Downloads")
        os.makedirs(dl)
        for fname, body in (("a.scmd", "{}"), ("b.cmd.json", "{}"), ("c.txt", "x")):
            with open(os.path.join(dl, fname), "w") as f:
                f.write(body)
        rc, out, _ = self.x("import-candidates")
        names = sorted(f["name"] for f in json.loads(out)["files"])
        self.assertEqual(names, ["a.scmd", "b.cmd.json", "tpl.cmd.json"])     # HOME itself is scanned too; c.txt is not a command


if __name__ == "__main__":
    unittest.main()
