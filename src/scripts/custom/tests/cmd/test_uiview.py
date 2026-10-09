"""Data for the Commands window: ui-list / ui-get / ui-schema, geometry and the auto-layout."""
import copy
import glob
import json
import os
import subprocess
import sys
import time
import unittest

import common as C
from common import node, wire, make_cmd
from xcmd import paths, schema as S, uiview

GOLDEN = os.path.join(C.HERE, "golden", "ui_layout_foreach.json")
EXAMPLES = sorted(glob.glob(os.path.join(C.CMD_DIR, "examples", "*.cmd.json")))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def overlaps(nodes):
    bad = []
    for i, a in enumerate(nodes):
        for b in nodes[i + 1:]:
            if a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"] and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"]:
                bad.append((a["id"], b["id"]))
    return bad


def stripped(cmd):
    cmd = copy.deepcopy(cmd)
    for n in cmd["nodes"]:
        n.pop("pos", None)
    return cmd


class GeometryTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_examples_have_positions_and_do_not_overlap(self):
        self.assertEqual(len(EXAMPLES), 7)
        for f in EXAMPLES:
            v = uiview.ui_get(load(f), self.sch)
            self.assertFalse(v["auto_layout"], f)
            self.assertEqual(overlaps(v["nodes"]), [], f)
            for n in v["nodes"]:
                self.assertIn("x", n)
                self.assertGreaterEqual(n["w"], uiview.W_MIN)
                self.assertLessEqual(n["w"], uiview.W_MAX)

    def test_node_height_matches_rows(self):
        v = uiview.ui_get(load(EXAMPLES[1]), self.sch)
        foreach = next(n for n in v["nodes"] if n["type"].startswith("logic.foreach"))
        self.assertEqual(foreach["h"], uiview.HDR + uiview.PAD_TOP + max(len(foreach["ins"]), len(foreach["outs"])) * uiview.ROW + uiview.FOOT)

    def test_pins_wires_and_inline_values(self):
        v = uiview.ui_get(load(next(f for f in EXAMPLES if "foreach" in f)), self.sch)
        by = {n["id"]: n for n in v["nodes"]}
        fe = by["n2"]
        self.assertEqual([p["t"] for p in fe["outs"]], ["exec", "any", "int", "exec"])      # generic T -> any
        self.assertEqual(fe["ins"][1]["t"], "list")
        self.assertEqual(fe["ins"][1]["v"], "список (3)")
        n3 = by["n3"]
        self.assertTrue(all(p["linked"] for p in n3["ins"]))                                  # all wired -> no inline values
        self.assertTrue(all("v" not in p for p in n3["ins"]))
        n4 = by["n4"]
        self.assertEqual({p["id"]: p.get("v") for p in n4["ins"]}, {"exec_in": None, "title": "Готово", "body": "Список закончился"})
        self.assertTrue(all(w["ok"] for w in v["wires"]))
        self.assertIn("exec", {w["t"] for w in v["wires"]})
        self.assertEqual(v["kind"], "manual")
        self.assertEqual(v["capabilities"], [{"id": "notify.show", "n": "уведомления", "risky": False}])

    def test_help_is_generated_from_the_schema(self):
        v = uiview.ui_get(load(EXAMPLES[2]), self.sch)
        h = v["help"]["action.notify@1"]
        self.assertEqual(h["title"], "Уведомление")
        self.assertIn("заголовком", h["description"])
        self.assertEqual([p["id"] for p in h["inputs"]], ["exec_in", "title", "body"])
        self.assertEqual(h["inputs"][1]["type_name"], "текст")
        self.assertTrue(h["inputs"][1]["required"])
        self.assertEqual(h["capabilities"], ["уведомления"])

    def test_deferred_and_undo_nodes(self):
        cmd = make_cmd("d", [node("e", "event.manual@1"), node("s", "action.test.deferred@1", on=True)], [wire("e", "exec", "s", "exec_in")])
        v = uiview.ui_get(cmd, C.schema_with_deferred())
        dnd = v["nodes"][1]
        self.assertTrue(dnd["deferred"])
        self.assertEqual(dnd["note"], "откат по завершении")
        self.assertEqual(dnd["h"], uiview.node_height(len(dnd["ins"]), len(dnd["outs"]), True))
        self.assertIn(dnd["ins"][1]["v"], ("да",))                                           # literal from props

    def test_unknown_node_is_shown_not_dropped(self):
        cmd = make_cmd("u", [node("e", "event.manual@1"), node("x", "action.nope@1")], [wire("e", "exec", "x", "exec_in")])
        v = uiview.ui_get(cmd, self.sch)
        x = next(n for n in v["nodes"] if n["id"] == "x")
        self.assertTrue(x["unknown"])
        self.assertEqual([p["id"] for p in x["ins"]], ["exec_in"])
        self.assertGreaterEqual(v["report"]["errors"], 1)

    def test_comments_pass_through(self):
        cmd = load(EXAMPLES[2])
        cmd["comments"] = [{"x": 10, "y": 200, "w": 300, "h": 90, "title": "Как это работает", "text": "…"}]
        v = uiview.ui_get(cmd, self.sch)
        self.assertEqual(v["comments"][0]["title"], "Как это работает")
        self.assertGreaterEqual(v["bounds"]["h"], 250)


class LayoutTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_layout_is_layered_without_overlap(self):
        for f in EXAMPLES:
            v = uiview.ui_get(stripped(load(f)), self.sch)
            self.assertTrue(v["auto_layout"])
            self.assertEqual(overlaps(v["nodes"]), [], f)
            by = {n["id"]: n for n in v["nodes"]}
            for w in v["wires"]:
                if w["t"] == "exec":                                                         # exec chains flow left to right
                    self.assertLess(by[w["from"][0]]["x"], by[w["to"][0]]["x"], (f, w))

    def test_layout_is_deterministic_and_matches_golden(self):
        v = uiview.ui_get(stripped(load(next(f for f in EXAMPLES if "foreach" in f))), self.sch)
        got = {n["id"]: [n["x"], n["y"], n["w"], n["h"]] for n in v["nodes"]}
        if os.environ.get("UPDATE_GOLDEN"):
            with open(GOLDEN, "w") as f:
                json.dump(got, f, indent=1, sort_keys=True)
        self.assertEqual(got, load(GOLDEN))
        v2 = uiview.ui_get(stripped(load(next(f for f in EXAMPLES if "foreach" in f))), self.sch)
        self.assertEqual(got, {n["id"]: [n["x"], n["y"], n["w"], n["h"]] for n in v2["nodes"]})

    def test_cycle_does_not_hang(self):
        nodes = [node("a", "logic.delay@1", seconds=1), node("b", "logic.delay@1", seconds=1)]
        wires = [wire("a", "exec_out", "b", "exec_in"), wire("b", "exec_out", "a", "exec_in")]
        v = uiview.ui_get(stripped(make_cmd("cyc", nodes, wires)), self.sch)
        self.assertEqual(len(v["nodes"]), 2)

    def test_big_graph_layout_is_fast(self):
        nodes, wires = [node("e", "event.manual@1")], []
        prev = ("e", "exec")
        for i in range(199):
            nid = "n%d" % i
            nodes.append(node(nid, "action.notify@1", title="t%d" % i))
            wires.append(wire(prev[0], prev[1], nid, "exec_in"))
            prev = (nid, "exec_out")
        t0 = time.time()
        v = uiview.ui_get(stripped(make_cmd("big", nodes, wires)), self.sch)
        self.assertLess(time.time() - t0, 3.0)
        self.assertEqual(len(v["nodes"]), 200)
        self.assertEqual(overlaps(v["nodes"]), [])


class CliTests(C.Base):
    def setUp(self):
        super().setUp()
        self.penv = self.env.env_for_subprocess()

    def x(self, *args):
        r = subprocess.run([sys.executable, "-m", "xcmd", "--json", *args], capture_output=True, text=True, env=self.penv,
                           cwd=self.env.root, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def test_ui_list_has_user_commands_examples_and_status(self):
        nodes, wires = C.notify_chain("Привет")
        self.env.write_cmd(make_cmd("Мой тест", nodes, wires, id="my-test"))
        d = self.x("ui-list")
        self.assertEqual([c["id"] for c in d["commands"]], ["my-test"])
        c = d["commands"][0]
        self.assertEqual((c["kind"], c["nodes"], c["errors"], c["enabled"], c["paused"]), ("manual", 2, 0, True, False))
        self.assertEqual(len(d["examples"]), 7)
        self.assertTrue(all(e["example"] and os.path.isfile(e["file"]) for e in d["examples"]))
        self.assertEqual((d["paused_all"], d["mode"]), (False, "local"))

    def test_ui_get_by_name_and_file(self):
        nodes, wires = C.notify_chain("Привет")
        self.env.write_cmd(make_cmd("Мой тест", nodes, wires, id="my-test"))
        by_name = self.x("ui-get", "my-test")
        self.assertEqual(len(by_name["nodes"]), 2)
        by_file = self.x("ui-get", EXAMPLES[0])
        self.assertEqual(by_file["file"], EXAMPLES[0])

    def test_last_run_comes_from_the_run_log(self):
        nodes, wires = C.notify_chain("Привет")
        self.env.write_cmd(make_cmd("Мой тест", nodes, wires, id="my-test"))
        os.makedirs(self.env.state, exist_ok=True)
        with open(os.path.join(self.env.state, "runs.jsonl"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"cmd": "my-test", "status": "ok", "end": 1700000000, "dur": 0.31}) + "\n")
            f.write(json.dumps({"cmd": "my-test", "status": "error", "end": 1700000100, "dur": 0.1, "message": "boom"}) + "\n")
        d = self.x("ui-list")
        self.assertEqual(d["commands"][0]["last_run"]["status"], "error")
        g = self.x("ui-get", "my-test")
        self.assertEqual([r["status"] for r in g["runs"]], ["error", "ok"])

    def test_ui_schema_lists_every_node(self):
        d = self.x("ui-schema")
        ids = {n["id"] for n in d["nodes"]}
        self.assertIn("action.notify", ids)
        self.assertEqual(len(ids), len(S.load_schema().nodes))
        self.assertEqual(d["types"]["text"], "текст")

    def test_english(self):
        d = self.x("ui-get", EXAMPLES[2], "--lang", "en")
        self.assertEqual(d["nodes"][1]["title"], "Notification")


if __name__ == "__main__":
    unittest.main()
