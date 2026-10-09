import json
import os
import unittest

import common as C
from xcmd import docs, engine, executors, ptypes as T, schema as S


class SchemaTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_schema_is_consistent(self):
        self.assertEqual(S.schema_check(self.sch, executors.REGISTRY, engine.BUILTIN_HANDLERS), [])

    def test_every_node_has_ru_and_en_name_description_example(self):
        for nd in self.sch.nodes.values():
            for f in ("name", "description", "example"):
                for lang in ("ru", "en"):
                    self.assertTrue(getattr(nd, f).get(lang), "%s.%s.%s" % (nd.id, f, lang))

    def test_starter_nodes_present(self):
        for nid in ("event.manual", "action.notify", "logic.delay", "logic.set_var", "data.get_var", "logic.if",
                    "logic.foreach", "action.clipboard_set", "ui.show_result", "action.shell", "convert.to_text",
                    "convert.to_int", "action.shell.dnd", "action.shell.theme"):
            self.assertIn(nid, self.sch.nodes)

    def test_converters_exist_for_fixits(self):
        self.assertEqual([c.id for c in self.sch.converters()], ["convert.to_int", "convert.to_text"])

    def test_state_changing_nodes_declare_undo_or_reason(self):
        for nd in self.sch.nodes.values():
            if nd.changes_state:
                self.assertTrue(nd.undo or nd.no_undo_reason, nd.id)

    def test_schema_check_catches_problems(self):
        bad = S.Schema()
        bad.add({"id": "x.bad", "version": 1, "category": "action", "flow": "action",
                 "name": {"ru": "Плохой"}, "description": {}, "example": {},
                 "inputs": [{"id": "in", "type": "text"}], "outputs": [], "executor": {"kind": "py", "ref": "nope"},
                 "changes_state": True})
        problems = "\n".join(S.schema_check(bad, executors.REGISTRY, engine.BUILTIN_HANDLERS))
        for needle in ("no name.en", "no description.ru", "no example.en", "capabilities not declared",
                       "py executor nope missing", "without an exec input", "has no undo"):
            self.assertIn(needle, problems)

    def test_duplicate_ids_rejected(self):
        sch = S.Schema()
        d = {"id": "a.b", "version": 1, "category": "action", "flow": "action"}
        sch.add(d)
        with self.assertRaises(S.SchemaError):
            sch.add(d)

    def test_type_string_and_versions(self):
        nd, err = self.sch.get("action.notify@1")
        self.assertIsNotNone(nd)
        self.assertEqual(self.sch.get("action.notify@9")[1], "version")
        self.assertEqual(self.sch.get("nope@1")[1], "unknown")
        self.assertEqual(S.parse_type_string("a.b"), ("a.b", 1))


class TypeTests(unittest.TestCase):
    def test_compat_is_strict(self):
        self.assertTrue(T.compatible("int", "float"))
        self.assertTrue(T.compatible("text", "any"))
        self.assertFalse(T.compatible("float", "int"))
        self.assertFalse(T.compatible("int", "text"))
        self.assertFalse(T.compatible("text", "int"))
        self.assertFalse(T.compatible("exec", "any"))
        self.assertTrue(T.compatible("list<text>", "list<any>"))
        self.assertFalse(T.compatible("list<int>", "list<float>"))

    def test_generic_unification(self):
        b = {}
        self.assertTrue(T.unify("list<T>", "list<text>", b, ("T",)))
        self.assertEqual(T.substitute("T", b), "text")
        self.assertFalse(T.unify("list<T>", "text", {}, ("T",)))

    def test_literals(self):
        self.assertIsNone(T.check_literal("int", 3))
        self.assertIsNotNone(T.check_literal("int", True))
        self.assertIsNotNone(T.check_literal("int", "3"))
        self.assertIsNone(T.check_literal("float", 3))
        self.assertIsNone(T.check_literal("color", "#aabbcc"))
        self.assertIsNotNone(T.check_literal("color", "red"))
        self.assertIsNone(T.check_literal("time", "07:30"))
        self.assertIsNone(T.check_literal("list<text>", ["a", "b"]))
        self.assertIn("элемент 2", T.check_literal("list<text>", ["a", 2]))
        self.assertEqual(T.infer_literal(["a", "b"]), "list<text>")
        self.assertEqual(T.infer_literal([1, 2.5]), "list<float>")
        self.assertIsNone(T.infer_literal(["a", 1]))

    def test_type_names(self):
        self.assertEqual(T.type_name("text"), "текст")
        self.assertEqual(T.type_name("int"), "число")
        self.assertEqual(T.type_name("list<text>"), "список (текст)")
        self.assertEqual(T.type_name("int", "en"), "number")


class DocsTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def test_docs_cover_every_node_and_pin_ru_en(self):
        for lang in ("ru", "en"):
            text = docs.render_all(self.sch, lang)
            for nd in self.sch.nodes.values():
                self.assertIn(nd.label(lang), text)
                self.assertIn("`%s`" % nd.type_string, text)
                for p in nd.inputs + nd.outputs:
                    self.assertIn("`%s`" % p.id, text)

    def test_docs_are_deterministic(self):
        self.assertEqual(docs.render_all(self.sch, "ru"), docs.render_all(S.load_schema(), "ru"))

    def test_golden_node_page(self):
        got = docs.render_node(self.sch.nodes["event.manual"], "ru")
        path = os.path.join(C.HERE, "golden", "doc_event_manual_ru.md")
        if os.environ.get("UPDATE_GOLDEN"):
            open(path, "w", encoding="utf-8").write(got)
        from xcmd.util import read_text
        self.assertEqual(got, read_text(path))

    def test_write_docs_files(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            files = docs.write_docs(self.sch, "ru", d)
            self.assertIn("index.md", files)
            self.assertIn("action.md", files)
            from xcmd.util import read_text
            self.assertIn("Уведомление", read_text(os.path.join(d, "action.md")))

    def test_deferred_nodes_are_marked(self):
        self.assertIn("пока недоступен", docs.render_node(C.schema_with_deferred().nodes["action.test.deferred"], "ru"))


if __name__ == "__main__":
    unittest.main()
