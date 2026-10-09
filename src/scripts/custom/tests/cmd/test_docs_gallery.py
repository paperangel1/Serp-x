"""Stage 8: node help coverage, generated documentation, example gallery (incl. planned nodes), tutorial data."""
import json
import os
import shutil
import tempfile
import unittest

import common as C
from test_cli import CliCase
from xcmd import docs, gallery, tutorial, uiview
from xcmd import schema as S
from xcmd.util import read_json, read_text
from xcmd.validate import validate

def put(path, text, mode="w"):
    with open(path, mode, encoding="utf-8") as f:
        f.write(text)


def put_json(path, doc):
    put(path, json.dumps(doc, ensure_ascii=False))


ELEVEN = {"work", "headphones", "second-monitor", "sort-downloads", "video-link", "evening", "away", "explain", "converter",
          "focus-25", "node-down"}
GALLERY = ELEVEN | {"wifi-vpn", "color-clipboard"}                  # stage 9c added two more annotated examples


class HelpCoverage(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_every_node_documented_in_both_languages(self):
        for nd in list(self.sch.nodes.values()) + list(self.sch.planned.values()):
            for f in ("name", "description", "example"):
                for lang in ("ru", "en"):
                    self.assertTrue(getattr(nd, f).get(lang), "%s.%s.%s" % (nd.id, f, lang))
            for lang in ("ru", "en"):
                self.assertTrue(nd.keywords.get(lang), "%s: keywords.%s" % (nd.id, lang))
            for p in nd.inputs + nd.outputs:
                if p.type != "exec":
                    for lang in ("ru", "en"):
                        self.assertTrue(p.label.get(lang), "%s.%s label.%s" % (nd.id, p.id, lang))

    def test_coverage_check_fails_for_an_undocumented_node(self):
        bad = S.Schema()
        bad.add({"id": "x.bad", "version": 1, "category": "action", "flow": "action", "name": {"ru": "Х"}, "description": {},
                 "example": {}, "inputs": [{"id": "exec_in", "type": "exec"}], "outputs": [], "capabilities": [],
                 "executor": {"kind": "builtin", "ref": "x"}})
        text = "\n".join(S.schema_check(bad))
        self.assertIn("x.bad: no description.en", text)
        self.assertIn("x.bad: no example.ru", text)
        self.assertIn("x.bad: no keywords.en", text)

    def test_help_carries_description_pins_rights_and_example(self):
        for nd in self.sch.nodes.values():
            h = uiview.node_help(nd, "en")
            self.assertTrue(h["description"] and h["example"], nd.id)
            self.assertEqual(len(h["inputs"]), len(nd.inputs))
            self.assertEqual(len(h["outputs"]), len(nd.outputs))
            self.assertEqual(len(h["capabilities"]), len(nd.capabilities))
            for p in h["inputs"] + h["outputs"]:
                self.assertTrue(p["type_name"])

    def test_search_words_include_keywords_in_both_languages(self):
        e = {c["id"]: c for c in uiview.ui_schema(self.sch, "ru")["catalog"]}
        self.assertIn("всплывашка", e["action.notify"]["search"])
        self.assertIn("toast", e["action.notify"]["search"])
        self.assertIn("закат", e["event.sun"]["search"])

    def test_planned_nodes_are_hidden_from_palette_and_grant_nothing(self):
        self.sch = C.schema_with_planned()
        cat = {c["id"] for c in uiview.ui_schema(self.sch, "ru")["catalog"]}
        self.assertFalse(cat & set(self.sch.planned))
        self.assertFalse(set(self.sch.nodes) & set(self.sch.planned))
        for nd in self.sch.planned.values():
            self.assertTrue(nd.planned)
        from xcmd.model import compute_capabilities
        cmd = C.make_cmd("P", [C.node("e", "event.manual@1"), C.node("a", "action.test.planned@1", enabled=True)],
                         [C.wire("e", "exec", "a", "exec_in")])
        self.assertEqual(compute_capabilities(cmd, self.sch), [])
        rep = validate(cmd, self.sch)
        self.assertEqual([i["code"] for i in rep["errors"]], ["planned_node"])
        self.assertIn("появится позже", rep["errors"][0]["message"])

    def test_planned_event_does_not_register_as_trigger(self):
        self.assertEqual(list(self.sch.planned), [])                              # stage 9c: no placeholder is left, the VPN node is real
        self.assertEqual(len(self.sch.event_nodes("vpn.changed")), 1)
        self.assertEqual(len(self.sch.event_nodes("clipboard.link")), 1)
        planned_event = dict(C.PLANNED, id="event.test.planned", category="event", flow="event", inputs=[],
                             outputs=[{"id": "exec", "type": "exec"}], source={"emits": "test.planned", "src": "x"})
        sch = S.load_schema(S.paths.nodes_dirs())
        sch.add_planned(planned_event, "t")
        self.assertEqual(sch.event_nodes("test.planned"), [])


class DocsTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_all_concepts_and_reference_and_recipes_present(self):
        for lang in ("ru", "en"):
            files = docs.build_all(self.sch, lang)
            for cid in docs.CONCEPTS:
                self.assertGreater(len(files[cid + ".md"]), 200, (lang, cid))
            for cat in self.sch.by_category():
                self.assertIn("reference/%s.md" % cat, files)
            self.assertIn("recipes.md", files)
            ref = "\n".join(v for k, v in files.items() if k.startswith("reference/"))
            for nd in self.sch.nodes.values():
                self.assertIn("`%s@%d`" % (nd.id, nd.version), ref)
            for planned in self.sch.planned:
                self.assertNotIn("`%s@" % planned, ref)

    def test_golden_index_en(self):
        got = docs.build_all(self.sch, "en")["index.md"]
        path = os.path.join(C.HERE, "golden", "docs_index_en.md")
        if os.environ.get("UPDATE_GOLDEN"):
            put(path, got)
        self.assertEqual(got, read_text(path))

    def test_recipes_list_every_gallery_command(self):
        text = docs.recipes_text("ru", self.sch)
        for f in gallery.files():
            e = gallery.entry_for(f, self.sch)
            self.assertIn("## " + e["name"]["ru"], text)

    def test_committed_reference_is_up_to_date(self):
        self.assertEqual(docs.check(self.sch), [])

    def test_stale_reference_is_detected(self):
        with tempfile.TemporaryDirectory() as d:
            shutil.copytree(os.path.join(os.environ.get("XCMD_ASSETS_DIR") or C.paths.assets_dir()), d, dirs_exist_ok=True)
            old = os.environ.get("XCMD_ASSETS_DIR")
            os.environ["XCMD_ASSETS_DIR"] = d
            try:
                p = os.path.join(d, "docs", "en", "reference", "action.md")
                put(p, "\nstale\n", "a")
                os.remove(os.path.join(d, "docs", "ru", "events.md"))
                probs = "\n".join(docs.check(self.sch))
                self.assertIn("reference/action.md: out of date", probs)
                self.assertIn("ru/events.md: missing", probs)
                docs.write_reference(self.sch)
                self.assertNotIn("out of date", "\n".join(docs.check(self.sch)))
            finally:
                if old is None:
                    os.environ.pop("XCMD_ASSETS_DIR")
                else:
                    os.environ["XCMD_ASSETS_DIR"] = old

    def test_viewer_pages(self):
        pages = docs.pages(self.sch, "ru")
        ids = [p["id"] for p in pages]
        self.assertEqual(ids[0], "index")
        for p in pages:
            self.assertTrue(docs.page(self.sch, "ru", p["id"]), p["id"])
        self.assertIn("reference/event", ids)
        self.assertIsNone(docs.page(self.sch, "ru", "nope"))


class GalleryTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_eleven_commands_and_a_fresh_manifest(self):
        self.assertEqual({gallery.entry_for(f, self.sch)["id"] for f in gallery.files()}, GALLERY)
        man = read_json(os.path.join(C.paths.gallery_dir(), "gallery.json"))
        self.assertEqual(man, gallery.manifest(self.sch))
        for it in man["gallery"]:
            self.assertEqual(it["ready"], not it["missing"])

    def test_gallery_files_validate(self):
        self.assertEqual(gallery.check(self.sch), [])
        for f in gallery.files():
            e = gallery.entry_for(f, self.sch)
            if e["ready"]:
                self.assertEqual(e["errors"], [], e["id"])
            else:
                self.assertTrue(set(e["errors"]) <= {"planned_node"}, (e["id"], e["errors"]))
                self.assertTrue(e["missing"])

    def test_missing_nodes_are_planned_or_deferred(self):
        for f in gallery.files():
            for m in gallery.entry_for(f, self.sch)["missing"]:
                nd, _ = self.sch.get(m + "@1")
                self.assertTrue(nd is not None and (nd.planned or nd.stage == "deferred"), m)

    def test_every_step_is_annotated_in_both_languages(self):
        for f in gallery.files():
            cmd = read_json(f)
            self.assertGreaterEqual(len(cmd["comments"]), 3, f)
            for c in cmd["comments"]:
                for k in ("title", "text"):
                    self.assertTrue(c[k]["ru"] and c[k]["en"], (f, c["id"], k))
            self.assertIsInstance(gallery.localize(cmd, "en")["comments"][0]["title"], str)

    def test_ready_fixture_is_ready_and_pending_one_is_not(self):
        with tempfile.TemporaryDirectory() as d:
            doc = {"format": 1, "id": "gallery-ok", "name": "Ok", "description": "d", "enabled": False,
                   "nodes": [C.node("e", "event.manual@1"), C.node("a", "action.notify@1", title="x")],
                   "wires": [C.wire("e", "exec", "a", "exec_in")],
                   "comments": [{"id": "c1", "x": 0, "y": 0, "w": 100, "h": 50, "title": {"ru": "а", "en": "a"}, "text": {"ru": "б", "en": "b"}}],
                   "gallery": {"name": {"ru": "Ок", "en": "Ok"}, "description": {"ru": "д", "en": "d"}, "category": "x"}}
            put_json(os.path.join(d, "ok.cmd.json"), doc)
            e = gallery.entry_for(os.path.join(d, "ok.cmd.json"), self.sch)
            self.assertTrue(e["ready"])
            self.assertEqual(gallery.check(self.sch, d), [])
            doc["nodes"][1]["type"] = "action.test.planned@1"
            doc["nodes"][1]["props"] = {"enabled": True}
            put_json(os.path.join(d, "ok.cmd.json"), doc)
            e = gallery.entry_for(os.path.join(d, "ok.cmd.json"), C.schema_with_planned())
            self.assertFalse(e["ready"])
            self.assertEqual(e["missing"], ["action.test.planned"])

    def test_video_link_needs_ytdlp_and_passes_the_link_as_argument(self):
        cmd = read_json(os.path.join(C.paths.gallery_dir(), "video-link.cmd.json"))
        self.assertEqual(cmd["gallery"]["packages"], ["yt-dlp"])
        shells = [n for n in cmd["nodes"] if n["type"] == "action.shell@1"]
        self.assertEqual(len(shells), 2)
        for n in shells:
            self.assertIn('"$1"', n["props"]["command"])
            self.assertNotIn("{", n["props"]["command"])


class GalleryCli(CliCase):
    def test_list_show_and_add(self):
        rc, items = self.j("gallery", "list")
        self.assertEqual({i["id"] for i in items}, GALLERY)
        rc, out, _ = self.x("gallery", "show", "headphones")
        self.assertEqual(rc, 0)
        self.assertIn("готова", out)
        self.assertNotIn("ждёт узлов", out)
        rc, res = self.j("gallery", "add", "headphones", "--lang", "en")
        self.assertEqual(rc, 0, res)
        self.assertEqual(res["name"], "Headphones")
        self.assertTrue(res["ready"])
        rc, res2 = self.j("gallery", "add", "headphones", "--lang", "en")
        self.assertEqual(res2["name"], "Headphones 2")
        files = [f for f in os.listdir(self.env.cmds) if f.endswith(".cmd.json")]
        self.assertEqual(len(files), 2)
        doc = read_json(os.path.join(self.env.cmds, sorted(files)[0]))
        self.assertFalse(doc["enabled"])
        self.assertNotIn("gallery", doc)
        self.assertFalse(doc.get("approved_capabilities"))
        self.assertIsInstance(doc["comments"][0]["text"], str)
        rc, _, err = self.x("gallery", "add", "nope")
        self.assertEqual(rc, 1)

    def test_ui_list_carries_gallery_tutorial_docs(self):
        rc, out, _ = self.x("ui-list", "--lang", "en")
        d = json.loads(out)
        self.assertEqual(len(d["gallery"]), 13)
        self.assertTrue(d["tutorial"]["steps"])
        self.assertTrue(d["docs"])
        g = {x["id"]: x for x in d["gallery"]}
        self.assertEqual(g["video-link"]["name"], "Video by link")
        self.assertEqual(g["video-link"]["packages"][0]["name"], "yt-dlp")

    def test_docs_all_cli(self):
        out = os.path.join(self.env.root, "docs")
        rc, o, _ = self.x("docs", "--all", "--lang", "ru", "--out", out)
        self.assertEqual(rc, 0, o)
        self.assertTrue(os.path.isfile(os.path.join(out, "reference", "event.md")))
        self.assertTrue(os.path.isfile(os.path.join(out, "recipes.md")))
        rc, o, _ = self.x("docs", "--check")
        self.assertEqual(rc, 0, o)
        rc, o, _ = self.x("docs", "--page", "security", "--lang", "en")
        self.assertIn("Security", o)

    def test_doctor_reports_docs_gallery_tutorial(self):
        rc, out, _ = self.x("doctor")
        text = " ".join(c["text"] for c in json.loads(out)["checks"])
        self.assertIn("документация в порядке", text)
        self.assertIn("галерея примеров в порядке", text)
        self.assertIn("обучение в порядке", text)


class TutorialTests(CliCase):
    def test_steps_file_is_valid(self):
        self.assertEqual(tutorial.check(S.load_schema()), [])
        steps = tutorial.load_steps()
        self.assertTrue(6 <= len(steps) <= 8)
        self.assertEqual(steps[0]["advance"], "command_created")
        self.assertEqual(steps[-1]["advance"], "saved")

    def test_validation_catches_bad_steps(self):
        bad = [{"id": "a", "target": "nowhere", "advance": "fly", "title": {"ru": "x"}, "text": {}}] * 5
        text = "\n".join(tutorial.check(S.load_schema(), bad))
        self.assertIn("unknown target", text)
        self.assertIn("bad advance rule", text)
        self.assertIn("duplicate id", text)
        self.assertIn("no title.en", text)
        self.assertIn("is not in the schema", "\n".join(tutorial.check(S.load_schema(), [
            dict(s, advance="node_added:action.nope") for s in tutorial.load_steps()[:5]])))

    def test_state_is_persisted_and_resettable(self):
        rc, st = self.j("tutorial", "get")
        self.assertEqual(st["state"], {"done": False, "skipped": False, "step": 0})
        self.x("tutorial", "set", "--step", "3")
        rc, st = self.j("tutorial", "get", "--lang", "en")
        self.assertEqual(st["state"]["step"], 3)
        self.assertEqual(st["steps"][0]["title"], "Create a command")
        self.x("tutorial", "set", "--done", "1")
        self.assertTrue(self.j("tutorial", "get")[1]["state"]["done"])
        self.x("tutorial", "reset")
        self.assertEqual(self.j("tutorial", "get")[1]["state"], {"done": False, "skipped": False, "step": 0})


if __name__ == "__main__":
    unittest.main()
