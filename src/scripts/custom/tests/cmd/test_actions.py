"""Stage 9a: shell / audio / media / window / file action nodes and the selection data nodes.
Every external tool is a fake binary on PATH (tests/cmd/common.py FAKES); nothing touches the real desktop."""
import json
import os
import stat
import unittest

import common as C
from common import node, wire, make_cmd


class ActBase(C.Base):
    async def asyncSetUp(self):
        self.runtime()

    def cmd(self, name, nodes, restore_delay=False):
        """event -> nodes (chained by exec) [-> delay, so an end-of-run rollback is observable]."""
        ns = [node("e", "event.manual@1")] + list(nodes) + ([node("zz", "logic.delay@1", seconds=1)] if restore_delay else [])
        ws, prev = [], "e"
        for n in ns[1:]:
            if n["type"].startswith("data."):
                continue
            ws.append(wire(prev, "exec" if prev == "e" else "exec_out", n["id"], "exec_in"))
            prev = n["id"]
        return make_cmd(name, ns, ws)

    async def go(self, name, nodes, restore_delay=False):
        self.add(self.cmd(name, nodes, restore_delay))
        return await self.rt.engine.run(name)

    def sh(self, name, body):
        p = os.path.join(self.env.bin, name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)

    def last_step(self, res, nid):
        return next(s for s in res["steps"] if s["node"] == nid and not s.get("rollback"))


class ShellTests(ActBase):
    async def test_theme_sets_and_restores(self):
        self.env.write_fake("ipc_Theme", "light:scheme-tonal-spot")
        res = await self.go("th", [node("a", "action.shell.theme@1", mode="dark", scheme="vibrant", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        calls = self.env.lines("ipc.log")
        self.assertIn("ipc call xcmd setTheme dark:scheme-vibrant", calls)
        self.assertEqual(calls[-1], "ipc call xcmd setTheme light:scheme-tonal-spot")

    async def test_theme_toggle_is_passed_on(self):
        res = await self.go("th2", [node("a", "action.shell.theme@1", mode="toggle")])
        self.assertEqual(res["status"], "ok")
        self.assertIn("ipc call xcmd setTheme toggle", self.env.lines("ipc.log"))

    async def test_dnd_goes_through_xcmd(self):
        res = await self.go("dnd", [node("a", "action.shell.dnd@1", enabled=True, restore="off")])
        self.assertEqual(res["status"], "ok")
        self.assertEqual(self.env.read("ipc_Dnd").strip(), "true")

    async def test_wallpaper_file_and_restore(self):
        pic = os.path.join(self.env.root, "a.jpg")
        open(pic, "w").close()
        old = os.path.join(self.env.root, "old.png")
        open(old, "w").close()
        self.env.write_fake("wallpaper", old + "\n")
        res = await self.go("wp", [node("a", "action.shell.wallpaper@1", path=pic, restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        calls = self.env.lines("ipc.log")
        self.assertIn("ipc call wallpaper setWallpaper all %s fade" % pic, calls)
        self.assertEqual(self.env.read("wallpaper").strip(), old)             # restored

    async def test_wallpaper_random_from_folder_and_errors(self):
        d = os.path.join(self.env.root, "wps")
        os.makedirs(d)
        for n in ("x.png", "y.jpg", "notes.txt"):
            open(os.path.join(d, n), "w").close()
        res = await self.go("wp2", [node("a", "action.shell.wallpaper@1", path=d)])
        self.assertEqual(res["status"], "ok")
        self.assertIn(self.env.read("wallpaper").strip(), (os.path.join(d, "x.png"), os.path.join(d, "y.jpg")))
        res = await self.go("wp3", [node("a", "action.shell.wallpaper@1", path=os.path.join(d, "none.png"))])
        self.assertEqual(res["status"], "err")
        self.assertIn("не найден", res["message"])

    async def test_night_filter_on_off_and_restore(self):
        self.env.write_fake("ipc_NightFilter", "off:50")
        res = await self.go("nf", [node("a", "action.shell.night_filter@1", enabled=True, temperature=4000, restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        calls = self.env.lines("ipc.log")
        self.assertIn("ipc call xcmd setNightFilter on:4000", calls)
        self.assertEqual(calls[-1], "ipc call xcmd setNightFilter off:50")
        res = await self.go("nf2", [node("a", "action.shell.night_filter@1", enabled=True, temperature=500)])
        self.assertIn("от 1000 до 10000", res["message"])

    async def test_brightness_set_delta_clamp_restore(self):
        self.env.write_fake("brightness", "70\n")
        res = await self.go("br", [node("a", "action.shell.brightness@1", percent=30, restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.env.read("brightness").strip(), "70")
        res = await self.go("br2", [node("a", "action.shell.brightness@1", mode="delta", delta=-100)])
        self.assertEqual(self.env.read("brightness").strip(), "1")            # never fully dark
        self.assertEqual(self.last_step(res, "a")["out"]["result"], 1)


class AudioTests(ActBase):
    def vol(self, kind="sink"):
        return self.env.read("vol_%s.v" % kind).strip()

    async def test_volume_set_change_mute_and_restore(self):
        self.env.write_fake("vol_sink.v", "0.55\n")
        res = await self.go("v", [node("a", "action.audio.set_volume@1", volume=20, restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.vol(), "0.55")
        self.assertIn("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 20%", self.env.lines("audio.log"))
        res = await self.go("v2", [node("a", "action.audio.set_volume@1", mode="change", delta=-10)])
        self.assertEqual(self.vol(), "0.45")
        res = await self.go("v3", [node("a", "action.audio.set_volume@1", mode="toggle_mute")])
        self.assertTrue(self.last_step(res, "a")["out"]["muted"])
        self.assertTrue(os.path.exists(os.path.join(self.env.fake, "vol_sink.m")))

    async def test_volume_without_audio_gives_a_russian_error(self):
        self.env.write_fake("vol_sink.none", "1")
        res = await self.go("v4", [node("a", "action.audio.set_volume@1", volume=20)])
        self.assertEqual(res["status"], "err")
        self.assertIn("Выход звука не найден", res["message"])

    async def test_set_output_matches_description_and_restores(self):
        self.env.write_fake("sinks.json", json.dumps([{"name": "alsa_output.pci.hdmi", "description": "HDMI Audio"},
                                                    {"name": "bluez_output.AA", "description": "WH-1000XM4 Headphones"}]))
        self.env.write_fake("default_sink", "alsa_output.pci.hdmi\n")
        res = await self.go("o", [node("a", "action.audio.set_output@1", device="headphones", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertIn("pactl set-default-sink bluez_output.AA", self.env.lines("audio.log"))
        self.assertEqual(self.env.read("default_sink").strip(), "alsa_output.pci.hdmi")
        res = await self.go("o2", [node("a", "action.audio.set_output@1", device="колонки")])
        self.assertEqual(res["status"], "err")
        self.assertIn("HDMI Audio", res["message"])

    async def test_mic_mute_unmute_toggle_restore(self):
        res = await self.go("m", [node("a", "action.audio.mic_mute@1", muted=True, restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertFalse(os.path.exists(os.path.join(self.env.fake, "vol_src.m")))       # restored to unmuted
        self.assertIn("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 1", self.env.lines("audio.log"))
        res = await self.go("m2", [node("a", "action.audio.mic_mute@1", mode="toggle", muted=False)])
        self.assertTrue(self.last_step(res, "a")["out"]["is_muted"])
        self.env.write_fake("vol_src.none", "1")
        res = await self.go("m3", [node("a", "action.audio.mic_mute@1", muted=True)])
        self.assertIn("Микрофон не найден", res["message"])


class MediaTests(ActBase):
    async def test_pause_returns_state_and_restores_playing(self):
        self.env.write_fake("player_state", "Playing\n")
        res = await self.go("p", [node("a", "action.media.control@1", command="pause", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.last_step(res, "a")["out"]["state"], "paused")
        self.assertEqual(self.env.read("player_state").strip(), "Playing")

    async def test_no_player_is_not_an_error(self):
        res = await self.go("p2", [node("a", "action.media.control@1", command="play")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.last_step(res, "a")["out"]["state"], "none")

    async def test_named_player_and_toggle(self):
        self.env.write_fake("player_state", "Paused\n")
        await self.go("p3", [node("a", "action.media.control@1", command="toggle", player="spotify")])
        self.assertIn("playerctl -p spotify play-pause", self.env.lines("media.log"))
        self.assertEqual(self.env.read("player_state").strip(), "Playing")


CLIENTS = [{"address": "0xa1", "mapped": True, "hidden": False, "class": "firefox", "floating": False, "workspace": {"id": 1}},
           {"address": "0xa2", "mapped": True, "hidden": False, "class": "Code", "floating": True, "workspace": {"id": 2}},
           {"address": "0xa3", "mapped": True, "hidden": False, "class": "kitty", "floating": False, "workspace": {"id": 2}}]
MONITORS = [{"name": "DP-1", "focused": True, "activeWorkspace": {"id": 1}}, {"name": "HDMI-A-1", "focused": False, "activeWorkspace": {"id": 5}}]


class WindowTests(ActBase):
    def dispatches(self):
        return [l[len("hyprctl dispatch "):] for l in self.env.lines("hypr.log") if l.startswith("hyprctl dispatch ")]

    async def test_open_app_by_command_with_workspace_rule(self):
        self.sh("fakeapp", "exit 0\n")
        res = await self.go("w", [node("a", "action.window.open_app@1", app="fakeapp --flag", workspace=3)])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.dispatches(), ["exec [workspace 3 silent] fakeapp --flag"])

    async def test_open_app_by_desktop_entry(self):
        d = os.path.join(self.env.root, "share", "applications")
        os.makedirs(d)
        with open(os.path.join(d, "org.fake.App.desktop"), "w") as f:
            f.write("[Desktop Entry]\nName=Fake\nExec=fake-bin --new %U\nType=Application\n")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.env.root, "share")
        self.addCleanup(os.environ.pop, "XDG_DATA_HOME", None)
        res = await self.go("w2", [node("a", "action.window.open_app@1", app="org.fake.App", workspace=2)])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.dispatches(), ["exec [workspace 2 silent] fake-bin --new"])

    async def test_missing_app_has_a_russian_error_and_no_dispatch(self):
        res = await self.go("w3", [node("a", "action.window.open_app@1", app="no-such-app-xyz")])
        self.assertEqual(res["status"], "err")
        self.assertIn("Приложение «no-such-app-xyz» не найдено", res["message"])
        self.assertEqual(self.dispatches(), [])

    async def test_wait_for_window(self):
        self.sh("fakeapp", "exit 0\n")
        self.env.write_fake("clients.json", "[]")
        self.env.write_fake("spawn.json", json.dumps(CLIENTS[:1]))
        res = await self.go("w4", [node("a", "action.window.open_app@1", app="fakeapp", wait=5)])
        self.assertEqual(self.last_step(res, "a")["out"]["address"], "0xa1")
        self.env.write_fake("clients.json", "[]")
        os.remove(os.path.join(self.env.fake, "spawn.json"))
        res = await self.go("w5", [node("a", "action.window.open_app@1", app="fakeapp", wait=1)])
        self.assertEqual(res["status"], "err")
        self.assertIn("не появилось", res["message"])

    async def test_arrange_by_monitor_moves_matching_windows_and_undoes(self):
        self.env.write_fake("clients.json", json.dumps(CLIENTS))
        self.env.write_fake("monitors.json", json.dumps(MONITORS))
        res = await self.go("ar", [node("a", "action.window.arrange@1", layout="by_monitor", monitor="HDMI-A-1", apps="firefox, code", restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        d = self.dispatches()
        self.assertEqual(d[:2], ["movetoworkspacesilent 5,address:0xa1", "movetoworkspacesilent 5,address:0xa2"])
        self.assertEqual(d[2:], ["movetoworkspacesilent 1,address:0xa1", "movetoworkspacesilent 2,address:0xa2"])   # rollback

    async def test_arrange_unknown_monitor_and_workspaces_layout(self):
        self.env.write_fake("clients.json", json.dumps(CLIENTS))
        self.env.write_fake("monitors.json", json.dumps(MONITORS))
        res = await self.go("ar2", [node("a", "action.window.arrange@1", layout="by_monitor", monitor="eDP-9")])
        self.assertIn("Подключены: DP-1, HDMI-A-1", res["message"])
        res = await self.go("ar3", [node("a", "action.window.arrange@1", layout="workspaces", apps="kitty:7, firefox:4")])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(sorted(self.dispatches()), ["movetoworkspacesilent 4,address:0xa1", "movetoworkspacesilent 7,address:0xa3"])
        res = await self.go("ar4", [node("a", "action.window.arrange@1", layout="workspaces", apps="kitty")])
        self.assertIn("приложение:номер", res["message"])

    async def test_arrange_tile_sets_tiled_and_splits(self):
        self.env.write_fake("clients.json", json.dumps(CLIENTS[:2]))
        self.env.write_fake("monitors.json", json.dumps(MONITORS))
        res = await self.go("ar5", [node("a", "action.window.arrange@1", layout="tile", workspace=3)])
        self.assertEqual(res["status"], "ok", res)
        d = self.dispatches()
        self.assertIn("settiled address:0xa2", d)
        self.assertIn("movewindow l", d)
        self.assertIn("movewindow r", d)

    async def test_hyprland_down_gives_a_clear_error(self):
        self.env.write_fake("hypr.fail", "1")
        res = await self.go("ar6", [node("a", "action.window.arrange@1", layout="stack")])
        self.assertEqual(res["status"], "err")
        self.assertIn("Hyprland не отвечает", res["message"])


class FileTests(ActBase):
    def f(self, *parts):
        return os.path.join(self.env.root, *parts)

    def rd(self, p):
        with open(p) as fh:
            return fh.read()

    def mk(self, rel, text="x"):
        p = self.f(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)
        return p

    async def test_move_creates_folder_renames_on_clash_and_undoes(self):
        src = self.mk("dl/a.txt", "new")
        self.mk("dst/a.txt", "old")
        res = await self.go("fm", [node("a", "action.file.move@1", path=src, folder=self.f("dst"), restore="end")], True)
        self.assertEqual((res["status"], res["undone"]), ("ok", 1), res)
        self.assertEqual(self.rd(self.f("dst", "a.txt")), "old")              # never overwritten
        self.assertFalse(os.path.exists(self.f("dst", "a (1).txt")))               # ... and undone (moved back)
        self.assertEqual(self.rd(src), "new")

    async def test_move_result_and_new_folder(self):
        src = self.mk("dl/b.txt")
        res = await self.go("fm2", [node("a", "action.file.move@1", path=src, folder=self.f("fresh", "sub"))])
        self.assertEqual(self.last_step(res, "a")["out"]["new_path"], self.f("fresh", "sub", "b.txt"))
        self.assertFalse(os.path.exists(src))

    async def test_copy_skip_fail_policies(self):
        src = self.mk("dl/c.txt")
        self.mk("dst/c.txt")
        await self.go("fm3", [node("a", "action.file.move@1", path=src, folder=self.f("dst"), mode="copy")])
        self.assertTrue(os.path.exists(src) and os.path.exists(self.f("dst", "c (1).txt")))
        res = await self.go("fm4", [node("a", "action.file.move@1", path=src, folder=self.f("dst"), on_exists="skip")])
        self.assertEqual(res["status"], "ok")
        res = await self.go("fm5", [node("a", "action.file.move@1", path=src, folder=self.f("dst"), on_exists="fail")])
        self.assertIn("уже есть", res["message"])

    async def test_outside_home_is_refused_without_the_approved_right(self):
        outside = os.path.join(os.path.realpath("/tmp"), "xcmd-outside-%d" % os.getpid())
        os.makedirs(outside)
        self.addCleanup(__import__("shutil").rmtree, outside, True)
        src = self.mk("dl/d.txt")
        res = await self.go("fm6", [node("a", "action.file.move@1", path=src, folder=outside)])
        self.assertEqual(res["status"], "err")
        self.assertIn("вне домашней папки", res["message"])
        self.assertTrue(os.path.exists(src))
        # opting in adds the file.write.any right to the command; once approved it works
        cmd = self.cmd("fm7", [node("a", "action.file.move@1", path=src, folder=outside, allow_outside_home=True)])
        from xcmd.model import compute_capabilities
        self.assertIn("file.write.any", compute_capabilities(cmd, self.rt.sch))
        self.add(cmd)
        res = await self.rt.engine.run("fm7")
        self.assertEqual(res["status"], "ok", res)
        self.assertTrue(os.path.exists(os.path.join(outside, "d.txt")))
        # opted in but the right was not approved -> refused
        cmd = self.cmd("fm8", [node("a", "action.file.move@1", path=os.path.join(outside, "d.txt"), folder=self.f("back"), allow_outside_home=True)])
        cmd["approved_capabilities"] = ["file.write"]
        self.env.write_cmd(cmd)
        self.rt.store.load()
        res = await self.rt.engine.run("fm8")
        self.assertEqual(res["status"], "denied")

    async def test_missing_file(self):
        res = await self.go("fm9", [node("a", "action.file.move@1", path=self.f("nope.txt"), folder=self.f("x"))])
        self.assertIn("Файл не найден", res["message"])

    async def test_convert_image_args_outputs_and_no_overwrite(self):
        src = self.mk("pics/p.PNG")
        self.mk("pics/p.webp")
        res = await self.go("ci", [node("a", "action.file.convert_image@1", path=src, format="webp", max_width=800, quality=70)])
        self.assertEqual(res["status"], "ok", res)
        self.assertEqual(self.last_step(res, "a")["out"]["new_path"], self.f("pics", "p (1).webp"))
        line = self.env.lines("magick.log")[0]
        self.assertIn("-resize 800x> -quality 70", line)
        self.assertTrue(os.path.exists(self.f("pics", "p (1).webp")))
        self.assertTrue(os.path.exists(src))

    async def test_convert_image_list_folder_and_errors(self):
        a, b = self.mk("pics/a.jpg"), self.mk("pics/b.jpg")
        res = await self.go("ci2", [node("a", "action.file.convert_image@1", paths=[a, b], format="png", folder=self.f("out"))])
        self.assertEqual(res["status"], "ok", res)
        self.assertTrue(os.path.exists(self.f("out", "a.png")) and os.path.exists(self.f("out", "b.png")))
        self.assertIn(self.f("out", "b.png"), self.last_step(res, "a")["out"]["new_paths"])
        txt = self.mk("pics/t.txt")
        res = await self.go("ci3", [node("a", "action.file.convert_image@1", paths=[txt, a])])
        self.assertEqual(res["status"], "err")
        self.assertIn("t.txt: это не картинка", res["message"])
        self.env.write_fake("magick.fail", "1")
        res = await self.go("ci4", [node("a", "action.file.convert_image@1", path=a)])
        self.assertIn("ImageMagick вернул код 1", res["message"])
        res = await self.go("ci5", [node("a", "action.file.convert_image@1")])
        self.assertIn("Не указано", res["message"])


class DataTests(ActBase):
    def data_cmd(self, name, dnode, pin, extra=None):
        nodes = [node("e", "event.manual@1"), dnode, node("n", "action.notify@1")]
        ws = [wire("e", "exec", "n", "exec_in"), wire("d", pin, "n", "title")] + (extra or [])
        if pin == "count":                                   # number -> text for the notification title
            nodes.append(node("c", "convert.to_text@1"))
            ws = [wire("e", "exec", "n", "exec_in"), wire("d", pin, "c", "value"), wire("c", "text", "n", "title")]
        return make_cmd(name, nodes, ws)

    async def run_data(self, name, dnode, pin, extra=None, args=None):
        self.add(self.data_cmd(name, dnode, pin, extra))
        return await self.rt.engine.run(name, args=args)

    async def test_selected_text_primary_then_clipboard(self):
        self.env.write_fake("primary.txt", "из выделения")
        self.env.write_fake("clipboard.txt", "из буфера")
        res = await self.run_data("st", node("d", "data.selected_text@1"), "text")
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("из выделения", self.env.read("notify.log"))
        os.remove(os.path.join(self.env.fake, "primary.txt"))
        await self.run_data("st2", node("d", "data.selected_text@1"), "source")
        self.assertIn("clipboard", self.env.read("notify.log"))

    async def test_selected_text_nothing_selected(self):
        res = await self.run_data("st3", node("d", "data.selected_text@1"), "source")
        self.assertEqual(res["status"], "ok", res)
        self.assertIn("none", self.env.read("notify.log"))

    async def test_selected_files_from_clipboard_and_argument(self):
        a = os.path.join(self.env.root, "one file.png")
        open(a, "w").close()
        from urllib.parse import quote
        self.env.write_fake("types.txt", "text/plain\nx-special/gnome-copied-files\n")
        self.env.write_fake("type_x-special_gnome-copied-files.txt", "copy\nfile://%s\nfile:///missing/x.png" % quote(a))
        res = await self.run_data("sf", node("d", "data.selected_files@1"), "count", )
        self.assertEqual(res["status"], "ok", res)
        step = next(s for s in res["steps"] if s["node"] == "d")
        self.assertIn(a, step["out"]["files"])
        self.assertNotIn("missing", step["out"]["files"])
        self.env.write_fake("types.txt", "")
        res = await self.run_data("sf2", node("d", "data.selected_files@1"), "count", args=a + "\n/missing")
        self.assertEqual(next(s for s in res["steps"] if s["node"] == "d")["out"]["count"], 1)

    async def test_file_kind(self):
        cases = {"/x/a.PNG": "image", "/x/r.pdf": "document", "/x/b.tar.gz": "archive", "/x/v.mkv": "video",
                 "/x/m.flac": "audio", "/x/noext": "other", "/x/.bashrc": "other", "/x/a.zip": "archive"}
        for path, kind in cases.items():
            res = await self.run_data("fk", node("d", "data.file_kind@1", path=path), "kind")
            self.assertEqual(next(s for s in res["steps"] if s["node"] == "d")["out"]["kind"], kind, path)


class CapabilityTests(unittest.TestCase):
    def test_prompt_texts_exist_in_both_languages(self):
        from xcmd import uiview, schema, executors
        sch = schema.load_schema()
        caps = set()
        for nd in sch.nodes.values():
            caps.update(nd.capabilities)
            for extra in nd.capabilities_if.values():
                caps.update(extra)
        for c in ("shell.dnd", "shell.theme", "shell.wallpaper", "screen.control", "audio.volume", "audio.output", "audio.mic",
                  "media.control", "window.manage", "file.write", "file.write.any", "image.convert", "read.selection"):
            self.assertIn(c, caps, c)
            self.assertTrue(uiview.CAP_RU.get(c) and uiview.CAP_EN.get(c), c)

    def test_nodes_declare_the_expected_rights(self):
        from xcmd import schema
        sch = schema.load_schema()
        want = {"action.shell.dnd": "shell.dnd", "action.shell.theme": "shell.theme", "action.shell.wallpaper": "shell.wallpaper",
                "action.audio.set_volume": "audio.volume", "action.audio.mic_mute": "audio.mic", "action.media.control": "media.control",
                "action.window.open_app": "window.manage", "action.window.arrange": "window.manage", "action.file.move": "file.write",
                "action.file.convert_image": "image.convert", "data.selected_text": "read.selection", "data.selected_files": "read.selection"}
        for nid, cap in want.items():
            self.assertIn(cap, sch.nodes[nid].capabilities, nid)
        self.assertEqual(sch.nodes["action.file.move"].capabilities_if, {"allow_outside_home": ["file.write.any"]})
        self.assertEqual(schema.schema_check(sch, __import__("xcmd.executors", fromlist=["x"]).REGISTRY, None), [])


class GalleryReadyTests(unittest.TestCase):
    def test_gallery_commands_with_all_nodes_are_ready_the_rest_name_exact_gaps(self):
        from xcmd import gallery, schema
        sch = schema.load_schema()
        got = {}
        for f in gallery.files():
            e = gallery.entry_for(f, sch)
            got[e["id"]] = (e["ready"], e["missing"], e["errors"])
        self.assertEqual(len(got), 13)
        for gid, res in got.items():                         # stage 9b: nothing is pending any more
            self.assertEqual(res, (True, [], []), gid)


if __name__ == "__main__":
    unittest.main()
