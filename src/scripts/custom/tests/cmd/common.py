"""Shared test fixtures: temp dirs, fake external tools on PATH (notify-send, wl-copy/wl-paste, serpantinum ipc,
systemctl), a fake clock and small builders. Nothing here touches the real desktop, network, systemd or ~/.config."""
import asyncio
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CMD_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "cmd"))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", ".."))
sys.path.insert(0, CMD_DIR)

# schemas built at import time must never read the real ~/.config (function library)
os.environ.setdefault("XCMD_COMMANDS_DIR", os.path.join(tempfile.gettempdir(), "xcmd-test-import-nonexistent"))

from xcmd import build as xbuild, clock as xclock, paths, procs   # noqa: E402

FAKES = {
    "notify-send": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_DIR/notify.log"\n[ -f "$FAKE_DIR/notify.rc" ] && exit "$(cat "$FAKE_DIR/notify.rc")"\nexit 0\n',
    "wl-copy": '#!/bin/sh\nprintf "wl-copy %s\\n" "$*" >> "$FAKE_DIR/clip.log"\n'
               'if [ "$1" = "--clear" ]; then rm -f "$FAKE_DIR/clipboard.txt"; exit 0; fi\ncat > "$FAKE_DIR/clipboard.txt"\n',
    "wl-paste": '#!/bin/sh\n'
                'if [ "$1" = --list-types ]; then [ -f "$FAKE_DIR/types.txt" ] && cat "$FAKE_DIR/types.txt"; exit 0; fi\n'
                'if [ "$1" = --primary ]; then [ -f "$FAKE_DIR/primary.txt" ] || exit 1; cat "$FAKE_DIR/primary.txt"; exit 0; fi\n'
                'if [ "$1" = --no-newline ] && [ "$2" = --type ]; then f="$FAKE_DIR/type_$(echo "$3" | tr / _).txt"; [ -f "$f" ] || exit 1; cat "$f"; exit 0; fi\n'
                '[ -f "$FAKE_DIR/clipboard.txt" ] || exit 1\ncat "$FAKE_DIR/clipboard.txt"\n',
    "serpantinum": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_DIR/ipc.log"\n[ -f "$FAKE_DIR/ipc.fail" ] && exit 1\n'
                   'if [ "$1" = brightness ]; then case "$2" in get) cat "$FAKE_DIR/brightness" 2>/dev/null || echo 50;;'
                   ' set) echo "$3" > "$FAKE_DIR/brightness";; esac; exit 0; fi\n'
                   '[ "$1" = ipc ] && [ "$2" = call ] || exit 2\n'
                   'if [ "$3" = wallpaper ]; then case "$4" in getWallpaperPath) cat "$FAKE_DIR/wallpaper" 2>/dev/null; true;;'
                   ' setWallpaper) echo "$6" > "$FAKE_DIR/wallpaper";; esac; exit 0; fi\n'
                   '[ "$3" = xcmd ] || exit 2\nfn="$4"; val="$5"\n'
                   'case "$fn" in\n get*) f="$FAKE_DIR/ipc_${fn#get}"; if [ -f "$f" ]; then cat "$f"; else echo false; fi;;\n'
                   ' set*) echo "$val" > "$FAKE_DIR/ipc_${fn#set}";;\n *) exit 2;;\nesac\n',
    "wpctl": '#!/bin/sh\nprintf "wpctl %s\\n" "$*" >> "$FAKE_DIR/audio.log"\nc="$1"; shift\n'
             '[ "$1" = -l ] && shift 2\nt="$1"; v="$2"\nk=sink; [ "$t" = @DEFAULT_AUDIO_SOURCE@ ] && k=src\nb="$FAKE_DIR/vol_$k"\n'
             '[ -f "$b.none" ] && { echo "Translate ID error: \'-1\' is not a valid ID" >&2; exit 1; }\n'
             'cur=$(cat "$b.v" 2>/dev/null || echo 0.50)\n'
             'case "$c" in\n get-volume) m=""; [ -f "$b.m" ] && m=" [MUTED]"; echo "Volume: $cur$m";;\n'
             ' set-volume) case "$v" in *%+) d=${v%\\%+}; echo "$cur $d" | awk \'{printf "%.2f\\n", $1+$2/100}\' > "$b.v";;\n'
             '   *%-) d=${v%\\%-}; echo "$cur $d" | awk \'{printf "%.2f\\n", $1-$2/100}\' > "$b.v";;\n'
             '   *%) d=${v%\\%}; echo "$d" | awk \'{printf "%.2f\\n", $1/100}\' > "$b.v";; esac;;\n'
             ' set-mute) case "$v" in 1) touch "$b.m";; 0) rm -f "$b.m";; toggle) if [ -f "$b.m" ]; then rm -f "$b.m"; else touch "$b.m"; fi;; esac;;\n'
             ' *) exit 2;;\nesac\n',
    "pactl": '#!/bin/sh\nprintf "pactl %s\\n" "$*" >> "$FAKE_DIR/audio.log"\n'
             'case "$*" in\n "-f json list sinks") cat "$FAKE_DIR/sinks.json";;\n "get-default-sink") cat "$FAKE_DIR/default_sink";;\n'
             ' "set-default-sink "*) echo "$2" > "$FAKE_DIR/default_sink";;\n *) exit 2;;\nesac\n',
    "playerctl": '#!/bin/sh\nprintf "playerctl %s\\n" "$*" >> "$FAKE_DIR/media.log"\n[ "$1" = -p ] && shift 2\n'
                 '[ -f "$FAKE_DIR/player_state" ] || { echo "No players found" >&2; exit 1; }\n'
                 'case "$1" in\n status) cat "$FAKE_DIR/player_state";;\n play) echo Playing > "$FAKE_DIR/player_state";;\n pause) echo Paused > "$FAKE_DIR/player_state";;\n'
                 ' stop) echo Stopped > "$FAKE_DIR/player_state";;\n play-pause) if [ "$(cat "$FAKE_DIR/player_state")" = Playing ]; then echo Paused; else echo Playing; fi > "$FAKE_DIR/player_state";;\n'
                 ' next|previous) ;;\n metadata) echo "Song";;\n *) exit 2;;\nesac\n',
    "hyprctl": '#!/bin/sh\nprintf "hyprctl %s\\n" "$*" >> "$FAKE_DIR/hypr.log"\n[ -f "$FAKE_DIR/hypr.fail" ] && { echo "error"; exit 1; }\n'
               'case "$1" in\n clients) cat "$FAKE_DIR/clients.json" 2>/dev/null || echo "[]";;\n monitors) cat "$FAKE_DIR/monitors.json" 2>/dev/null || echo "[]";;\n'
               ' activewindow) cat "$FAKE_DIR/activewindow.json" 2>/dev/null || echo "{}";;\n'
               ' dispatch) if [ "$2" = exec ] && [ -f "$FAKE_DIR/spawn.json" ]; then cp "$FAKE_DIR/spawn.json" "$FAKE_DIR/clients.json"; fi; echo ok;;\n *) exit 2;;\nesac\n',
    "magick": '#!/bin/sh\nprintf "magick %s\\n" "$*" >> "$FAKE_DIR/magick.log"\n[ -f "$FAKE_DIR/magick.fail" ] && { echo "convert: boom" >&2; exit 1; }\n'
              'for a; do d="$a"; done\nprintf img > "$d"\n',
    "systemctl": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_DIR/systemctl.log"\ncase "$2" in\n'
                 ' is-enabled) [ -f "$FAKE_DIR/enabled" ] && echo enabled && exit 0; echo disabled; exit 1;;\n'
                 ' is-active) [ -f "$FAKE_DIR/active" ] && echo active && exit 0; echo inactive; exit 3;;\nesac\nexit 0\n',
}


class Env:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="xcmd-test-")
        self.bin = os.path.join(self.root, "bin")
        self.fake = os.path.join(self.root, "fake")
        self.cmds = os.path.join(self.root, "commands")
        self.state = os.path.join(self.root, "state")
        self.sock = os.path.join(self.root, "run", "cmdd.sock")
        self.units = os.path.join(self.root, "units")
        for d in (self.bin, self.fake, self.cmds, self.state, self.units):
            os.makedirs(d)
        for name, body in FAKES.items():
            p = os.path.join(self.bin, name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
        self.vars = {"FAKE_DIR": self.fake, "PATH": self.bin + os.pathsep + os.environ.get("PATH", ""),
                     "XCMD_COMMANDS_DIR": self.cmds, "XCMD_STATE_DIR": self.state, "XCMD_SOCKET": self.sock,
                     "XCMD_UNIT_DIR": self.units, "XCMD_SYSTEMCTL": os.path.join(self.bin, "systemctl"),
                     "XCMD_SERPANTINUM_BIN": os.path.join(self.bin, "serpantinum"), "HOME": self.root,
                     "XDG_RUNTIME_DIR": os.path.join(self.root, "run"), "PYTHONDONTWRITEBYTECODE": "1"}
        self._saved = {k: os.environ.get(k) for k in self.vars}
        os.environ.update(self.vars)

    def restore(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.root, ignore_errors=True)

    def env_for_subprocess(self):
        e = dict(os.environ)
        e.update(self.vars)
        e["PYTHONPATH"] = CMD_DIR
        return e

    def read(self, name):
        p = os.path.join(self.fake, name)
        if not os.path.exists(p):
            return ""
        with open(p, encoding="utf-8") as f:
            return f.read()

    def lines(self, name):
        return [l for l in self.read(name).splitlines() if l]

    def write_fake(self, name, text):
        with open(os.path.join(self.fake, name), "w") as f:
            f.write(text)

    def write_cmd(self, cmd, fname=None):
        path = os.path.join(self.cmds, fname or (cmd["id"] + ".cmd.json"))
        with open(path, "w", encoding="utf-8") as f:
            json.dump(cmd, f, ensure_ascii=False)
        return path


DEFERRED = {"id": "action.test.deferred", "version": 1, "category": "action", "flow": "action", "icon": "bell", "stage": "deferred",
            "name": {"ru": "Пока недоступный", "en": "Not yet"}, "description": {"ru": "т", "en": "t"}, "example": {"ru": "т", "en": "t"},
            "inputs": [{"id": "exec_in", "type": "exec"}, {"id": "on", "type": "bool", "default": True, "label": {"ru": "в", "en": "o"}}],
            "outputs": [{"id": "exec_out", "type": "exec", "label": {"ru": "Готово", "en": "Done"}}],
            "executor": {"kind": "ipc", "target": "xcmd", "fn": "setNothing"}, "undo": {"capture": "getNothing", "restore": "setNothing", "default": "end"},
            "capabilities": [], "timeout_s": 5, "changes_state": True, "side_effects": True}


def schema_with_deferred():
    """The real schema plus a fixture node with stage "deferred" (no real node is deferred any more since stage 9a)."""
    from xcmd import schema as S
    d = tempfile.mkdtemp(prefix="xcmd-test-defer-")
    with open(os.path.join(d, "t.json"), "w", encoding="utf-8") as f:
        json.dump({"nodes": [DEFERRED]}, f)
    return S.load_schema(paths.nodes_dirs() + [d])


PLANNED = {"id": "action.test.planned", "version": 1, "category": "action", "flow": "action", "icon": "shield",
           "name": {"ru": "Задуманный", "en": "Planned"}, "description": {"ru": "т", "en": "t"}, "example": {"ru": "т", "en": "t"},
           "inputs": [{"id": "exec_in", "type": "exec"}, {"id": "enabled", "type": "bool", "label": {"ru": "в", "en": "o"}, "required": True}],
           "outputs": [{"id": "exec_out", "type": "exec", "label": {"ru": "Готово", "en": "Done"}}],
           "capabilities": ["vpn.control"], "timeout_s": 10, "changes_state": True, "side_effects": True}


def schema_with_planned():
    """The real schema plus a fixture planned node (no real node is planned any more since the VPN node became real)."""
    from xcmd import schema as S
    d = tempfile.mkdtemp(prefix="xcmd-test-planned-")
    with open(os.path.join(d, "planned.json"), "w", encoding="utf-8") as f:
        json.dump({"nodes": [PLANNED]}, f)
    return S.load_schema(paths.nodes_dirs() + [d])


def node(nid, typ, **props):
    return {"id": nid, "type": typ, "pos": [0, 0], "props": props}


def wire(a, ap, b, bp):
    return {"from": [a, ap], "to": [b, bp]}


def make_cmd(name, nodes, wires, variables=None, caps="auto", **extra):
    cmd = {"format": 1, "id": extra.pop("id", name.lower().replace(" ", "-")), "name": name, "enabled": True,
           "nodes": nodes, "wires": wires}
    if variables:
        cmd["variables"] = variables
    cmd.update(extra)
    return cmd


def approve_all(cmd, sch):
    from xcmd.model import compute_capabilities
    cmd["approved_capabilities"] = compute_capabilities(cmd, sch)
    return cmd


def notify_chain(*titles):
    """event -> notify(title)… as nodes/wires, for quick graphs."""
    nodes = [node("e", "event.manual@1")]
    wires = []
    prev = ("e", "exec")
    for i, t in enumerate(titles):
        nid = "n%d" % i
        nodes.append(node(nid, "action.notify@1", title=t))
        wires.append(wire(prev[0], prev[1], nid, "exec_in"))
        prev = (nid, "exec_out")
    return nodes, wires


class FakeUi:
    """UI bridge that answers requests with a canned value and records them."""

    def __init__(self, answer=None):
        self.answer, self.requests = answer, []

    async def request(self, kind, payload, timeout=3.0):
        self.requests.append((kind, payload))
        return self.answer


class CbClock(xclock.FakeClock):
    """FakeClock that runs a callback on every sleep (to observe state mid-run)."""

    def __init__(self, cb=None):
        super().__init__()
        self.cb = cb

    async def sleep(self, seconds):
        if self.cb:
            self.cb()
        await super().sleep(seconds)


class Base(unittest.IsolatedAsyncioTestCase):
    use_fake_clock = True

    def setUp(self):
        self.env = Env()
        self.addCleanup(self.env.restore)

    def runtime(self, clock=None, ui=None):
        self.clock = clock or (xclock.FakeClock() if self.use_fake_clock else xclock.RealClock())
        self.rt = xbuild.build(clock=self.clock, ui=ui, proc=procs.ProcessRunner())
        return self.rt

    def add(self, cmd, approve=True):
        if approve:
            approve_all(cmd, self.rt.sch if hasattr(self, "rt") else __import__("xcmd.schema", fromlist=["x"]).load_schema())
        self.env.write_cmd(cmd)
        if hasattr(self, "rt"):
            self.rt.store.load()
        return cmd
