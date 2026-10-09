import copy
import json
import os
import unittest

import common as C
from common import node, wire, make_cmd
from xcmd import schema as S
from xcmd.validate import validate


def codes(rep, level="errors"):
    return [i["code"] for i in rep[level]]


def issue(rep, code):
    return next(i for i in rep["errors"] + rep["warnings"] if i["code"] == code)


class ValidateTests(unittest.TestCase):
    def setUp(self):
        self.sch = S.load_schema()

    def v(self, nodes, wires, **kw):
        return validate(make_cmd("t", nodes, wires, **kw), self.sch)

    def hello(self):
        return [node("e", "event.manual@1"), node("n", "action.notify@1", title="x")], [wire("e", "exec", "n", "exec_in")]

    def test_minimal_command_is_valid(self):
        rep = self.v(*self.hello())
        self.assertTrue(rep["ok"], rep)
        self.assertEqual(rep["capabilities"], ["notify.show"])
        self.assertEqual(rep["warnings"], [])

    def test_unknown_node_and_version(self):
        nodes, wires = self.hello()
        nodes.append(node("x", "action.nope@1"))
        nodes.append(node("y", "action.notify@7", title="t"))
        rep = self.v(nodes, wires)
        self.assertIn("unknown_node", codes(rep))
        self.assertIn("node_version", codes(rep))
        self.assertIn("потерян", issue(rep, "unknown_node")["message"])

    def test_duplicate_ids(self):
        nodes, wires = self.hello()
        nodes.append(node("n", "action.notify@1", title="y"))
        self.assertIn("duplicate_node", codes(self.v(nodes, wires)))

    def test_missing_required_input(self):
        nodes = [node("e", "event.manual@1"), node("n", "action.notify@1")]
        rep = self.v(nodes, [wire("e", "exec", "n", "exec_in")])
        i = issue(rep, "missing_input")
        self.assertEqual((i["node"], i["pin"]), ("n", "title"))

    def test_type_mismatch_number_into_text_has_converter_fix(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=[1, 2]),
                 node("n", "action.notify@1")]
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "index", "n", "title")]
        rep = self.v(nodes, wires)
        i = issue(rep, "type_mismatch")
        self.assertIn("Этому входу нужен текст, а подключено число", i["message"])
        self.assertIn("needs text, but number is connected", i["message_en"])
        self.assertEqual(i["fix"]["kind"], "insert_converter")
        self.assertEqual(i["fix"]["node_type"], "convert.to_text@1")
        self.assertIn("Вставить", i["fix"]["label"])
        self.assertEqual((i["node"], i["pin"]), ("n", "title"))

    def test_text_into_number_suggests_text_to_number(self):
        nodes = [node("e", "event.manual@1"), node("n", "logic.delay@1")]
        wires = [wire("e", "exec", "n", "exec_in"), wire("e", "arg", "n", "seconds")]
        rep = self.v(nodes, wires)
        self.assertEqual(issue(rep, "type_mismatch")["fix"]["node_type"], "convert.to_int@1")

    def test_int_flows_into_float(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=[1, 2]), node("d", "logic.delay@1")]
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "d", "exec_in"), wire("f", "index", "d", "seconds")]
        self.assertTrue(self.v(nodes, wires)["ok"])

    def test_generics_follow_the_connected_list(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=["a", "b"]), node("n", "action.notify@1")]
        wires = [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "item", "n", "title")]
        self.assertTrue(self.v(nodes, wires)["ok"])
        nodes[1]["props"]["list"] = [1, 2]
        self.assertIn("type_mismatch", codes(self.v(nodes, wires)))

    def test_foreach_needs_a_list(self):
        nodes = [node("e", "event.manual@1"), node("f", "logic.foreach@1", list="text")]
        rep = self.v(nodes, [wire("e", "exec", "f", "exec_in")])
        self.assertIn("bad_literal", codes(rep))

    def test_literal_only_pin_rejects_wires(self):
        nodes = [node("e", "event.manual@1"), node("s", "logic.set_var@1", value="x")]
        wires = [wire("e", "exec", "s", "exec_in"), wire("e", "arg", "s", "name")]
        rep = self.v(nodes, wires, variables=[{"name": "a", "type": "text"}])
        self.assertIn("literal_only", codes(rep))

    def test_exec_fanout_and_multi_input(self):
        nodes, wires = self.hello()
        nodes.append(node("m", "action.notify@1", title="y"))
        wires.append(wire("e", "exec", "m", "exec_in"))
        self.assertIn("exec_fanout", codes(self.v(nodes, wires)))
        nodes = [node("e", "event.manual@1"), node("n", "action.notify@1"), node("a", "convert.to_text@1", value=1),
                 node("b", "convert.to_text@1", value=2)]
        wires = [wire("e", "exec", "n", "exec_in"), wire("a", "text", "n", "title"), wire("b", "text", "n", "title")]
        self.assertIn("multi_input", codes(self.v(nodes, wires)))

    def test_exec_and_data_cycles(self):
        nodes = [node("e", "event.manual@1"), node("a", "action.notify@1", title="a"), node("b", "action.notify@1", title="b")]
        wires = [wire("e", "exec", "a", "exec_in"), wire("a", "exec_out", "b", "exec_in"), wire("b", "exec_out", "a", "exec_in")]
        self.assertIn("exec_cycle", codes(self.v(nodes, wires)))
        nodes = [node("e", "event.manual@1"), node("a", "convert.to_text@1"), node("b", "convert.to_text@1")]
        wires = [wire("a", "text", "b", "value"), wire("b", "text", "a", "value")]
        self.assertIn("data_cycle", codes(self.v(nodes, wires)))

    def test_exec_data_mismatch_and_bad_wires(self):
        nodes, wires = self.hello()
        rep = self.v(nodes, wires + [wire("e", "exec", "n", "title")])
        self.assertIn("exec_data_mismatch", codes(rep))
        rep = self.v(nodes, wires + [wire("e", "nope", "n", "title"), wire("zz", "exec", "n", "title")])
        self.assertEqual(codes(rep).count("bad_wire"), 2)
        rep = validate({"name": "t", "nodes": nodes, "wires": [{"bogus": 1}]}, self.sch)
        self.assertIn("bad_wire", codes(rep))

    def test_no_event_and_unreachable(self):
        rep = self.v([node("n", "action.notify@1", title="x")], [])
        self.assertIn("no_event", codes(rep))
        self.assertIn("unreachable", codes(rep, "warnings"))

    def test_variables(self):
        nodes = [node("e", "event.manual@1"), node("s", "logic.set_var@1", name="nope", value="x")]
        rep = self.v(nodes, [wire("e", "exec", "s", "exec_in")], variables=[{"name": "a", "type": "text"}])
        self.assertIn("unknown_variable", codes(rep))
        rep = self.v(nodes, [], variables=[{"name": "a", "type": "bogus"}, {"name": "a", "type": "text"}])
        self.assertEqual(codes(rep).count("bad_variable"), 2)

    def test_set_var_value_must_match_variable_type(self):
        nodes = [node("e", "event.manual@1"), node("s", "logic.set_var@1", name="n", value="text")]
        rep = self.v(nodes, [wire("e", "exec", "s", "exec_in")], variables=[{"name": "n", "type": "int"}])
        self.assertIn("bad_literal", codes(rep))

    def test_get_var_output_type_follows_variable(self):
        nodes = [node("e", "event.manual@1"), node("g", "data.get_var@1", name="n"), node("m", "action.notify@1")]
        wires = [wire("e", "exec", "m", "exec_in"), wire("g", "value", "m", "title")]
        rep = self.v(nodes, wires, variables=[{"name": "n", "type": "int"}])
        self.assertEqual(issue(rep, "type_mismatch")["fix"]["node_type"], "convert.to_text@1")
        rep = self.v(nodes, wires, variables=[{"name": "n", "type": "text"}])
        self.assertTrue(rep["ok"], rep)

    def test_restore_modes(self):
        base = [node("e", "event.manual@1")]
        w = [wire("e", "exec", "c", "exec_in")]
        rep = self.v(base + [node("c", "action.clipboard_set@1", text="a", restore="off_event")], w)
        self.assertIn("restore_mode_unavailable", codes(rep))
        rep = self.v(base + [node("c", "action.clipboard_set@1", text="a", restore="sometimes")], w)
        self.assertIn("bad_restore", codes(rep))
        rep = self.v(base + [node("c", "action.notify@1", title="a", restore="end")], [wire("e", "exec", "c", "exec_in")])
        self.assertIn("no_undo_support", codes(rep))
        rep = self.v(base + [node("c", "action.clipboard_set@1", text="a", restore="end")], w)
        self.assertTrue(rep["ok"], rep)

    def test_literal_range_choice_and_on_error(self):
        base = [node("e", "event.manual@1")]
        rep = self.v(base + [node("d", "logic.delay@1", seconds=99999)], [wire("e", "exec", "d", "exec_in")])
        self.assertIn("out_of_range", codes(rep))
        rep = self.v(base + [node("t", "action.shell.theme@1", mode="blue")], [wire("e", "exec", "t", "exec_in")])
        self.assertIn("bad_choice", codes(rep))
        nodes, wires = self.hello()
        nodes[1]["props"]["on_error"] = "explode"
        self.assertIn("bad_on_error", codes(self.v(nodes, wires)))

    def test_warnings_state_change_deferred_danger(self):
        base = [node("e", "event.manual@1"), node("s", "action.shell@1", command="true")]
        rep = self.v(base, [wire("e", "exec", "s", "exec_in")])
        w = codes(rep, "warnings")
        self.assertIn("no_undo", w)
        self.assertIn("danger_confirm", w)
        self.sch = C.schema_with_deferred()
        rep = self.v([node("e", "event.manual@1"), node("d", "action.test.deferred@1", on=True)],
                     [wire("e", "exec", "d", "exec_in")])
        self.assertIn("deferred_node", codes(rep, "warnings"))

    def test_policy_checks(self):
        nodes, wires = self.hello()
        rep = self.v(nodes, wires, policy={"reentrancy": "maybe", "max_runs_per_min": 0})
        self.assertEqual(codes(rep).count("bad_policy"), 2)

    def test_capabilities_are_the_union(self):
        nodes = [node("e", "event.manual@1"), node("n", "action.notify@1", title="a"), node("c", "action.clipboard_set@1", text="b"),
                 node("s", "action.shell@1", command="true")]
        wires = [wire("e", "exec", "n", "exec_in"), wire("n", "exec_out", "c", "exec_in"), wire("c", "exec_out", "s", "exec_in")]
        self.assertEqual(self.v(nodes, wires)["capabilities"], ["clipboard.write", "exec.script", "notify.show"])

    def test_every_issue_has_ru_and_en_messages(self):
        nodes = [node("n", "action.nope@1"), node("n", "action.notify@1")]
        rep = validate({"name": "t", "nodes": nodes, "wires": [{"from": ["n", "x"], "to": ["q", "y"]}]}, self.sch)
        for i in rep["errors"]:
            self.assertTrue(i["message"] and i["message_en"], i)

    def test_broken_files(self):
        self.assertFalse(validate("not an object", self.sch)["ok"])
        self.assertFalse(validate({"name": "t", "nodes": "x"}, self.sch)["ok"])

    def test_golden_report(self):
        cmd = make_cmd("golden", [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=[1, 2]),
                                  node("n", "action.notify@1"), node("z", "action.nope@1")],
                       [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "index", "n", "title")])
        got = json.dumps(validate(cmd, self.sch), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        path = os.path.join(C.HERE, "golden", "validate_type_mismatch.json")
        if os.environ.get("UPDATE_GOLDEN"):
            with open(path, "w", encoding="utf-8") as f:
                f.write(got)
        from xcmd.util import read_text
        self.assertEqual(got, read_text(path))


if __name__ == "__main__":
    unittest.main()
