import json
import os
import unittest

import common as C
from test_cli import CliCase, hello


class PinTests(CliCase):
    def setUp(self):
        super().setUp()
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(hello("Привет"), sch))
        self.env.write_cmd(C.approve_all(hello('Кавычки "и" пробелы'), sch))

    def pin_file(self):
        return os.path.join(self.env.cmds, ".pinned.json")

    def test_pin_unpin_pinned_roundtrip(self):
        rc, out, _ = self.x("pin", "Привет")
        self.assertEqual(rc, 0)
        self.assertIn("Закреплена", out)
        rc, out, _ = self.x("pin", "Привет")
        self.assertIn("уже так было", out)
        rc, _o, _e = self.x("pin", 'Кавычки "и" пробелы')
        self.assertEqual(rc, 0)
        rc, data = self.j("pinned")
        self.assertEqual([c["name"] for c in data["pinned"]], ["Привет", 'Кавычки "и" пробелы'])
        rc, data = self.j("list")
        self.assertTrue(all(c["pinned"] for c in data["commands"]))
        rc, data = self.j("ui-list")
        self.assertEqual(len(data["pinned"]), 2)
        self.assertTrue(all(c["pinned"] for c in data["commands"]))
        rc, out, _ = self.x("unpin", "Привет")
        self.assertIn("Откреплена", out)
        rc, data = self.j("pinned")
        self.assertEqual([c["name"] for c in data["pinned"]], ['Кавычки "и" пробелы'])
        with open(self.pin_file(), encoding="utf-8") as f:
            self.assertEqual(len(json.load(f)["pinned"]), 1)

    def test_ui_launch_and_pulse(self):
        self.x("pin", "Привет")
        rc, data = self.j("ui-launch")
        self.assertEqual(rc, 0)
        self.assertEqual([c["name"] for c in data["commands"] if c["pinned"]], ["Привет"])
        self.assertEqual(data["pinned"], ["привет"])
        self.assertNotIn("examples", data)
        c = [c for c in data["commands"] if c["name"] == "Привет"][0]
        self.assertTrue(c["approved"])
        self.assertIn("kind", c)
        self.assertTrue(any("ведомл" in k for k in c["keywords"]), c["keywords"])
        rc, p = self.j("pulse")
        self.assertEqual(rc, 0)
        self.assertEqual((p["paused_all"], p["failed_recent"], p["pinned"], p["last"]), (False, 0, 1, None))
        self.x("run", "Привет")
        rc, p = self.j("pulse")
        self.assertEqual(p["last"]["status"], "ok")
        self.assertEqual(p["failed_recent"], 0)
        self.x("pause")
        rc, p = self.j("pulse")
        self.assertTrue(p["paused_all"])

    def test_doctor_row(self):
        rc, data = self.j("doctor")
        rows = [c["text"] for c in data["checks"] if "палитра" in c["text"]]
        self.assertEqual(len(rows), 1, rows)
        self.assertIn("файлы на месте", rows[0])
        with open(self.pin_file(), "w") as f:
            f.write("not json")
        rc, data = self.j("doctor")
        self.assertTrue([c for c in data["checks"] if "повреждён" in c["text"]])

    def test_unknown_name_and_broken_file(self):
        rc, _o, err = self.x("pin", "нет такой")
        self.assertEqual(rc, 1)
        with open(self.pin_file(), "w") as f:
            f.write("{not json")
        rc, data = self.j("pinned")
        self.assertEqual(data["pinned"], [])
        rc, _o, _e = self.x("pin", "Привет")
        self.assertEqual(rc, 0)
        self.assertFalse([n for n in os.listdir(os.path.dirname(self.pin_file())) if ".tmp." in n])

    def test_stale_pin_is_ignored(self):
        self.x("pin", "Привет")
        with open(self.pin_file(), "w") as f:
            json.dump({"pinned": ["gone", "привет"]}, f)
        rc, data = self.j("pinned")
        self.assertEqual([c["id"] for c in data["pinned"]], ["привет"])


if __name__ == "__main__":
    unittest.main()
