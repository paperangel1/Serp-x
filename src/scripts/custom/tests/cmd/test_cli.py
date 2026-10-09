import asyncio
import json
import os
import subprocess
import sys
import unittest

import common as C
from common import node, wire, make_cmd, notify_chain
from xcmd.daemon import Daemon

BIN = os.path.join(C.REPO, "bin")


def hello(name="Привет"):
    nodes, wires = notify_chain("Привет, мир")
    return make_cmd(name, nodes, wires, id=name.lower())


class CliCase(C.Base):
    def setUp(self):
        super().setUp()
        self.proc_env = self.env.env_for_subprocess()
        self.proc_env["SERPANTINUM_FORK_DIR"] = C.REPO

    def x(self, *args, **kw):
        r = subprocess.run([sys.executable, "-m", "xcmd", *args], capture_output=True, text=True, env=self.proc_env,
                           cwd=self.env.root, timeout=60, **kw)
        return r.returncode, r.stdout, r.stderr

    def j(self, *args):
        rc, out, err = self.x("--json", *args)
        return rc, json.loads(out) if out.strip() else None


class CliTests(CliCase):
    def test_list_empty_and_filled(self):
        rc, out, _ = self.x("list")
        self.assertEqual(rc, 0)
        self.assertIn("Команд пока нет", out)
        self.env.write_cmd(C.approve_all(hello(), __import__("xcmd.schema", fromlist=["x"]).load_schema()))
        rc, out, _ = self.x("list")
        self.assertIn("Привет — без описания  права: notify.show", out)
        rc, data = self.j("list")
        self.assertEqual(data["commands"][0]["name"], "Привет")

    def test_run_ok_dry_run_and_errors(self):
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(hello(), sch))
        rc, out, err = self.x("run", "Привет")
        self.assertEqual(rc, 0)
        self.assertIn("✓ Привет — ok", out)
        self.assertIn("демон не запущен", err)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- Привет, мир"])
        rc, out, _ = self.x("run", "Привет", "--dry-run")
        self.assertIn("репетиция", out)
        self.assertEqual(len(self.env.lines("notify.log")), 1)
        rc, out, err = self.x("run", "нет такой")
        self.assertEqual(rc, 1)
        self.assertIn("не найдена", out)
        rc, out, _ = self.x("run", "Прив", "--steps")             # unique prefix
        self.assertEqual(rc, 0)
        self.assertIn("event.manual@1", out)

    def test_run_denied_until_approved(self):
        self.env.write_cmd(hello())
        rc, out, _ = self.x("run", "Привет")
        self.assertEqual(rc, 1)
        self.assertIn("неподтверждённые права", out)
        self.assertIn("serpantinum-x cmd approve", out)
        rc, out, _ = self.x("approve", "Привет", "--yes")
        self.assertEqual(rc, 0)
        rc, out, _ = self.x("run", "Привет")
        self.assertEqual(rc, 0)

    def test_run_arg_and_yes(self):
        nodes = [node("e", "event.manual@1"), node("s", "action.shell@1", command="echo hi"), node("n", "action.notify@1")]
        wires = [wire("e", "exec", "s", "exec_in"), wire("s", "exec_out", "n", "exec_in"), wire("e", "arg", "n", "title"),
                 wire("s", "stdout", "n", "body")]
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(make_cmd("Shell", nodes, wires), sch))
        rc, out, _ = self.x("run", "Shell", "--arg", "заголовок")
        self.assertEqual(rc, 1)
        self.assertIn("нужно подтверждение", out)
        rc, out, _ = self.x("run", "Shell", "--arg", "заголовок", "--yes")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.env.lines("notify.log"), ["-a Serpantinum -- заголовок hi"])

    def test_validate_by_name_and_by_file_with_fixit(self):
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(hello(), sch))
        rc, out, _ = self.x("validate", "Привет")
        self.assertEqual(rc, 0)
        self.assertIn("Проверка пройдена", out)
        bad = make_cmd("bad", [node("e", "event.manual@1"), node("f", "logic.foreach@1", list=[1]), node("n", "action.notify@1")],
                       [wire("e", "exec", "f", "exec_in"), wire("f", "body", "n", "exec_in"), wire("f", "index", "n", "title")])
        path = os.path.join(self.env.root, "bad.cmd.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(bad, f, ensure_ascii=False)
        rc, out, _ = self.x("validate", path)
        self.assertEqual(rc, 1)
        self.assertIn("Этому входу нужен текст, а подключено число", out)
        self.assertIn("Вставить «Любое → Текст»", out)
        rc, data = self.j("validate", path)
        self.assertFalse(data["ok"])
        self.assertEqual(data["errors"][0]["fix"]["node_type"], "convert.to_text@1")

    def test_log_pause_resume_enable_disable_status(self):
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(hello(), sch))
        self.x("run", "Привет")
        rc, out, _ = self.x("log", "-n", "5")
        self.assertIn("ok", out)
        self.assertIn("Привет", out)
        rc, out, _ = self.x("pause")
        self.assertIn("на паузе", out)
        rc, out, _ = self.x("status")
        self.assertIn("пауза всех: да", out)
        rc, out, _ = self.x("resume")
        self.assertIn("работают", out)
        self.assertIn("выключена", self.x("disable", "Привет")[1])
        self.assertIn("включена", self.x("enable", "Привет")[1])
        rc, out, _ = self.x("pause", "Привет")
        rc, out, _ = self.x("status")
        self.assertIn("на паузе: привет (manual)", out)

    def test_docs_stdout_and_files(self):
        rc, out, _ = self.x("docs")
        self.assertIn("# Справочник узлов «Команд»", out)
        self.assertIn("Выполнить команду оболочки", out)
        rc, out, _ = self.x("docs", "--lang", "en")
        self.assertIn("Commands node reference", out)
        d = os.path.join(self.env.root, "docs")
        rc, out, _ = self.x("docs", "--out", d)
        self.assertIn("index.md", os.listdir(d))

    def test_schema_check_and_doctor(self):
        rc, out, _ = self.x("schema-check")
        self.assertEqual((rc, out.strip()), (0, "Схема в порядке"))
        rc, out, _ = self.x("doctor")
        checks = json.loads(out)["checks"]
        self.assertEqual(checks[0], {"level": "ok", "text": "схема узлов в порядке"})
        self.assertTrue(any("служба serpantinum-cmdd не установлена" in c["text"] for c in checks))

    def test_import_flow(self):
        shell = make_cmd("Чужая", [node("e", "event.manual@1"), node("s", "action.shell@1", command="true")],
                         [wire("e", "exec", "s", "exec_in")], approved_capabilities=["exec.script"], enabled=True)
        pkg = os.path.join(self.env.root, "x.scmd")
        with open(pkg, "w", encoding="utf-8") as f:
            json.dump(shell, f, ensure_ascii=False)
        rc, out, _ = self.x("import", pkg)
        self.assertEqual(rc, 0)
        self.assertIn("выключена, права не подтверждены", out)
        self.assertIn("внимание: узел «Выполнить команду оболочки»", out)
        rc, data = self.j("list")
        c = data["commands"][0]
        self.assertEqual((c["enabled"], c["imported"], c["approved"]), (False, True, False))
        rc, out, _ = self.x("run", "Чужая", "--yes")
        self.assertEqual(rc, 1)                                  # approvals from the file were dropped
        self.assertIn("неподтверждённые права: exec.script", out)
        rc, out, _ = self.x("approve", "Чужая", "--yes")
        self.assertEqual(rc, 0)
        rc, out, _ = self.x("run", "Чужая", "--yes")
        self.assertEqual(rc, 0, out)

    def test_import_rejects_tampered_packages_and_junk(self):
        cmd = hello("Пакет")
        sha = __import__("xcmd.model", fromlist=["x"]).canonical_sha256(cmd)
        pkg = os.path.join(self.env.root, "p.scmd")
        with open(pkg, "w", encoding="utf-8") as f:
            json.dump({"command": cmd, "sha256": sha, "capabilities": ["notify.show"]}, f)
        self.assertEqual(self.x("import", pkg)[0], 0)
        cmd["nodes"][1]["props"]["title"] = "подменено"
        with open(pkg, "w", encoding="utf-8") as f:
            json.dump({"command": cmd, "sha256": sha}, f)
        rc, out, err = self.x("import", pkg)
        self.assertEqual(rc, 1)
        self.assertIn("Контрольная сумма", err)
        junk = os.path.join(self.env.root, "junk.json")
        with open(junk, "w") as f:
            f.write("[1, 2")
        self.assertEqual(self.x("import", junk)[0], 1)

    def test_install_print_apply_and_uninstall_use_only_the_fake_systemctl(self):
        rc, out, _ = self.x("install", "--print")
        self.assertIn("systemctl --user enable --now serpantinum-cmdd.service", out)
        self.assertIn("ExecStart=", out)
        self.assertIn(" cmd daemon", out)
        self.assertEqual(self.env.lines("systemctl.log"), [])
        self.assertFalse(os.path.exists(os.path.join(self.env.units, "serpantinum-cmdd.service")))
        rc, out, _ = self.x("install")
        self.assertEqual(rc, 0, out)
        from xcmd.util import read_text
        unit = read_text(os.path.join(self.env.units, "serpantinum-cmdd.service"))
        self.assertIn("ExecStart=%s cmd daemon" % os.path.join(C.REPO, "bin", "serpantinum-x"), unit)
        self.assertNotIn("@BIN_X@", unit)
        self.assertEqual(self.x("install", "--check")[0], 0)                  # idempotent: nothing to change
        self.assertEqual(self.x("--json", "install", "--check")[0], 0)
        self.assertEqual(self.env.lines("systemctl.log"), ["--user daemon-reload", "--user enable --now serpantinum-cmdd.service"])
        open(os.path.join(self.env.fake, "enabled"), "w").close()
        open(os.path.join(self.env.fake, "active"), "w").close()
        rc, out, _ = self.x("status")
        self.assertIn("Служба: установлена, включена, запущена", out)
        rc, out, _ = self.x("uninstall")
        self.assertFalse(os.path.exists(os.path.join(self.env.units, "serpantinum-cmdd.service")))
        self.assertIn("--user disable --now serpantinum-cmdd.service", self.env.lines("systemctl.log"))

    def test_launchers_and_dispatch(self):
        sch = __import__("xcmd.schema", fromlist=["x"]).load_schema()
        self.env.write_cmd(C.approve_all(hello(), sch))
        e = self.proc_env
        for argv in (["bash", os.path.join(C.CMD_DIR, "x_cmd.sh"), "run", "Привет"],
                     ["bash", os.path.join(BIN, "serpantinum-x"), "run", "Привет"],
                     ["bash", os.path.join(BIN, "serpantinum-x"), "cmd", "run", "Привет"],
                     ["bash", os.path.join(BIN, "serpantinum"), "run", "Привет"]):
            r = subprocess.run(argv, capture_output=True, text=True, env=e, cwd=self.env.root, timeout=60)
            self.assertEqual(r.returncode, 0, (argv, r.stdout, r.stderr))
            self.assertIn("✓ Привет — ok", r.stdout)
        self.assertEqual(len(self.env.lines("notify.log")), 4)
        r = subprocess.run(["bash", os.path.join(BIN, "serpantinum-x"), "doctor"], capture_output=True, text=True, env=e, cwd=self.env.root)
        self.assertIn("Команды: схема узлов в порядке", r.stdout)


class CliDaemonTests(CliCase):
    async def test_cli_talks_to_the_daemon_when_it_runs(self):
        self.runtime()
        d = Daemon(rt=self.rt, socket_path=self.env.sock)
        await d.start()
        self.addAsyncCleanup(d.stop)
        sch = self.rt.sch
        self.add(hello())
        await self.rt.api.call("reload", {})
        rc, out, err = await asyncio.to_thread(self.x, "run", "Привет")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("✓ Привет — ok", out)
        self.assertNotIn("демон не запущен", err)
        rc, out, _ = await asyncio.to_thread(self.x, "status")
        self.assertIn("Демон на сокете: отвечает", out)
        rc, out, _ = await asyncio.to_thread(self.x, "--local", "status")
        self.assertIn("нет (команды выполняются напрямую)", out)


if __name__ == "__main__":
    unittest.main()
