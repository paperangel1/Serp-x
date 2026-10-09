import json
import os
import time
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from xcmd import model, schema as S
from xcmd.model import CommandError, Store


def cmd(name, **kw):
    nodes, wires = notify_chain("x")
    return make_cmd(name, nodes, wires, **kw)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.env = C.Env()
        self.addCleanup(self.env.restore)
        self.sch = S.load_schema()
        self.store = Store(self.env.cmds, history_dir=os.path.join(self.env.state, "history"), clock=time)

    def test_find_by_id_stem_name_and_prefix(self):
        for name, cid in (("Вечерний режим", "evening"), ("Рабочий режим", "work"), ("Рабочий стол", "desk")):
            self.store.save(cmd(name, id=cid), self.sch)
        self.store.load()
        self.assertEqual(self.store.find("evening")["name"], "Вечерний режим")                     # id
        self.assertEqual(self.store.find("Вечерний режим")["name"], "Вечерний режим")              # name, any case
        self.assertEqual(self.store.find("вечерний РЕЖИМ")["name"], "Вечерний режим")
        self.assertEqual(self.store.find("вечер")["name"], "Вечерний режим")                       # unique prefix
        self.assertEqual(self.store.find("вечерний-режим")["name"], "Вечерний режим")              # file stem
        with self.assertRaises(CommandError) as cm:
            self.store.find("режим")
        self.assertEqual(cm.exception.code, "not_found")
        with self.assertRaises(CommandError) as cm:
            self.store.find("рабочий")
        self.assertEqual(cm.exception.code, "ambiguous")
        self.assertIn("Рабочий стол", cm.exception.message)

    def test_ambiguous_names(self):
        self.store.save(cmd("Дубль", id="a"), self.sch)
        self.store.save(cmd("Дубль", id="b"), self.sch)
        self.store.load()
        self.assertEqual(sorted(os.path.basename(f) for f in self.store.files.values()), ["дубль-2.cmd.json", "дубль.cmd.json"])
        with self.assertRaises(CommandError) as cm:
            self.store.find("Дубль")
        self.assertEqual(cm.exception.code, "ambiguous")

    def test_save_computes_capabilities_and_keeps_history(self):
        saved = self.store.save(cmd("История", id="h"), self.sch)
        self.assertEqual(saved["capabilities"], ["notify.show"])
        self.assertEqual(saved["format"], 1)
        hd = os.path.join(self.env.state, "history", "h")
        for i in range(25):
            c = dict(self.store.cmds["h"], description="v%d" % i)
            self.store.save(c, self.sch)
            time.sleep(0.002)
        self.assertLessEqual(len(os.listdir(hd)), model.HISTORY_KEEP)
        self.store.load()
        self.assertEqual(self.store.cmds["h"]["description"], "v24")

    def test_broken_files_are_reported_not_fatal(self):
        with open(os.path.join(self.env.cmds, "broken.cmd.json"), "w") as f:
            f.write("{ nope")
        with open(os.path.join(self.env.cmds, "noname.cmd.json"), "w") as f:
            f.write("{}")
        self.store.save(cmd("Живая", id="ok"), self.sch)
        self.store.load()
        self.assertEqual([c["name"] for c in self.store.all()], ["Живая"])
        self.assertEqual(len(self.store.errors), 2)

    def test_changed_detects_edits_and_new_files(self):
        self.store.load()
        self.assertFalse(self.store.changed())
        self.env.write_cmd(cmd("Новая", id="n"))
        self.assertTrue(self.store.changed())

    def test_slug_and_policy_defaults(self):
        self.assertEqual(model.slugify("Тёмная  тема!"), "тёмная-тема")
        self.assertEqual(model.slugify("***"), "command")
        self.assertEqual(model.policy_of({"policy": {"max_runs_per_min": 9}})["reentrancy"], "skip")
        self.assertEqual(model.policy_of({"policy": {"max_runs_per_min": 9}})["max_runs_per_min"], 9)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.env = C.Env()
        self.addCleanup(self.env.restore)
        self.sch = S.load_schema()
        self.store = Store(self.env.cmds, history_dir=os.path.join(self.env.state, "history"), clock=time)

    def pkg(self, data):
        p = os.path.join(self.env.root, "in.scmd")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        return p

    def test_import_is_disabled_unapproved_and_recomputes_capabilities(self):
        evil = cmd("Пакет", enabled=True, approved_capabilities=["exec.script", "net.http"], capabilities=[])
        evil["nodes"].append(node("s", "action.shell@1", command="true"))
        evil["wires"].append(wire("n0", "exec_out", "s", "exec_in"))
        res = model.import_package(self.pkg({"command": evil, "capabilities": ["notify.show"],
                                             "sha256": model.canonical_sha256(evil)}), self.store, self.sch)
        saved = self.store.cmds[res["id"]]
        self.assertEqual((saved["enabled"], saved["imported"], saved["approved_capabilities"]), (False, True, []))
        self.assertEqual(res["capabilities"], ["exec.script", "notify.show"])
        self.assertTrue(any("не совпадают" in w for w in res["warnings"]))
        self.assertEqual([s["type"] for s in res["suspicious"]], ["action.shell@1"])

    def test_name_collision_gets_a_suffix(self):
        self.store.save(cmd("Занято", id="a"), self.sch)
        res = model.import_package(self.pkg(cmd("Занято", id="zzz")), self.store, self.sch)
        self.assertEqual(res["command"], "Занято (импорт)")
        self.assertNotEqual(res["id"], "zzz")                       # a foreign id never overwrites ours

    def test_bad_inputs(self):
        with self.assertRaises(CommandError) as cm:
            model.import_package(self.pkg({"name": "x"}), self.store, self.sch)
        self.assertEqual(cm.exception.code, "bad_file")
        with self.assertRaises(CommandError) as cm:
            model.import_package(os.path.join(self.env.root, "missing"), self.store, self.sch)
        self.assertEqual(cm.exception.code, "bad_file")
        good = cmd("С суммой", id="s")
        with self.assertRaises(CommandError) as cm:
            model.import_package(self.pkg({"command": good, "sha256": "0" * 64}), self.store, self.sch)
        self.assertEqual(cm.exception.code, "bad_checksum")

    def test_checksum_ignores_approval_state_but_not_content(self):
        a = cmd("Хеш", id="h")
        b = dict(a, enabled=False, approved_capabilities=["notify.show"], imported=True)
        self.assertEqual(model.canonical_sha256(a), model.canonical_sha256(b))
        c = json.loads(json.dumps(a))
        c["nodes"][1]["props"]["title"] = "другое"
        self.assertNotEqual(model.canonical_sha256(a), model.canonical_sha256(c))


if __name__ == "__main__":
    unittest.main()
