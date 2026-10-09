#!/usr/bin/env python3
"""Writes fake data for the offscreen Commands UI test: test-only node types (XCMD_EXTRA_NODES), demo commands
(XCMD_COMMANDS_DIR) and optionally a generated big graph. Usage: make_fixtures.py <out-dir> [--big N]"""
import json
import os
import sys

out = sys.argv[1]
big = int(sys.argv[sys.argv.index("--big") + 1]) if "--big" in sys.argv else 0
os.makedirs(os.path.join(out, "nodes"), exist_ok=True)
os.makedirs(os.path.join(out, "commands"), exist_ok=True)


def nd(id_, cat, icon, ru, desc, ins, outs, caps=(), undo=False, ex=""):
    d = {"id": id_, "version": 1, "category": cat, "flow": "event" if cat == "event" else "action", "icon": icon,
         "name": {"ru": ru, "en": ru}, "description": {"ru": desc, "en": desc}, "example": {"ru": ex, "en": ex},
         "inputs": ins, "outputs": outs, "executor": {"kind": "py", "ref": "notify"}, "capabilities": list(caps),
         "timeout_s": 5, "changes_state": undo, "side_effects": cat != "event"}
    if undo:
        d["undo"] = {"capture": "getX", "restore": "setX", "default": "end"}
    return d


def pin(i, t, ru="", **kw):
    p = {"id": i, "type": t}
    if ru:
        p["label"] = {"ru": ru, "en": ru}
    p.update(kw)
    return p


EX = pin("exec_in", "exec")
DONE = pin("exec_out", "exec", "Готово")
nodes = [
    nd("event.bt_headphones", "event", "headphones", "Наушники подключены", "Срабатывает, когда подключаются Bluetooth-наушники.", [],
       [pin("exec", "exec", "Выполнить"), pin("device", "text", "Имя устройства"), pin("bluetooth", "bool", "Bluetooth")]),
    nd("event.bt_headphones_off", "event", "unplug", "Когда наушники отключат", "Срабатывает при отключении наушников.", [], [pin("exec", "exec", "Выполнить")]),
    nd("event.sunset", "event", "sunset", "Закат", "Срабатывает на закате.", [], [pin("exec", "exec", "Выполнить"), pin("time", "time", "Время")]),
    nd("event.monitor", "event", "window", "Монитор подключён", "Срабатывает при подключении второго монитора.", [], [pin("exec", "exec", "Выполнить")]),
    nd("event.clipboard_link", "event", "clipboard", "Скопирована ссылка", "Срабатывает, когда в буфер скопирована ссылка.", [],
       [pin("exec", "exec", "Выполнить"), pin("url", "url", "Ссылка")]),
    nd("action.audio_output", "action", "volume", "Переключить вывод звука", "Меняет устройство вывода звука.", [EX, pin("device", "text", "Устройство", required=True)],
       [DONE, pin("ok", "bool", "Успешно")], ("audio.control",), True, "Вывод звука: Наушники."),
    nd("action.volume_set", "action", "volume", "Установить громкость", "Меняет громкость. Если включён откат, при завершении команды вернёт прежнее значение.",
       [EX, pin("percent", "int", "Громкость, %", default=50, min=0, max=100)], [DONE], ("audio.control",), True, "Громкость: 40%."),
    nd("action.media_resume", "action", "play", "Медиа: продолжить", "Продолжает воспроизведение.", [EX], [DONE], ("media.control",), False),
    nd("action.night_filter", "action", "filter", "Ночной фильтр", "Включает тёплый ночной фильтр экрана.", [EX, pin("on", "bool", "Включить", default=True)], [DONE], ("screen.control",), True),
    nd("action.dark_theme", "action", "moon", "Тёмная тема", "Переключает тёмную тему оболочки.", [EX], [DONE], ("shell.control",), True),
    nd("action.brightness", "action", "brightness", "Установить яркость", "Меняет яркость основного монитора.",
       [EX, pin("percent", "int", "Яркость, %", default=30, min=0, max=100)], [DONE], ("screen.control",), True, "Яркость: 30%."),
    nd("undo.revert", "undo", "revert", "Вернуть изменения", "Возвращает всё, что команда изменила.", [EX], [], (), False),
]
json.dump({"nodes": nodes}, open(os.path.join(out, "nodes", "extra.json"), "w"), ensure_ascii=False, indent=1)


def n(i, t, x, y, **props):
    return {"id": i, "type": t, "pos": [x, y], "props": props}


def w(a, ap, b, bp):
    return {"from": [a, ap], "to": [b, bp]}


def cmd(cid, name, desc, nds, wires, comments=None, enabled=True, caps=None, approved=None):
    c = {"format": 1, "id": cid, "name": name, "description": desc, "enabled": enabled, "nodes": nds, "wires": wires,
         "capabilities": caps or [], "approved_capabilities": caps or [] if approved is None else approved}
    if comments:
        c["comments"] = comments
    json.dump(c, open(os.path.join(out, "commands", cid + ".cmd.json"), "w"), ensure_ascii=False, indent=1)


cmd("headphones", "Наушники", "Переключить звук, 40% громкости, продолжить музыку",
    [n("n1", "event.bt_headphones@1", 50, 60), n("n2", "action.audio_output@1", 400, 52), n("n3", "action.volume_set@1", 770, 52, percent=40),
     n("n4", "action.media_resume@1", 1120, 52), n("n5", "event.bt_headphones_off@1", 400, 330), n("n6", "undo.revert@1", 770, 330)],
    [w("n1", "exec", "n2", "exec_in"), w("n1", "device", "n2", "device"), w("n2", "exec_out", "n3", "exec_in"),
     w("n3", "exec_out", "n4", "exec_in"), w("n5", "exec", "n6", "exec_in")],
    [{"x": 40, "y": 240, "w": 300, "h": 112, "color": "#f9e2af", "title": "Как это работает",
      "text": "Подключили наушники → переключаем звук, ставим 40% и продолжаем музыку. Когда отключат — всё вернётся."}],
    caps=["audio.control", "media.control"])
cmd("evening", "Вечер", "Ночной фильтр, тёмная тема, меньше яркости",
    [n("n1", "event.sunset@1", 50, 60), n("n2", "action.night_filter@1", 400, 60), n("n3", "action.dark_theme@1", 760, 60), n("n4", "action.brightness@1", 1060, 60, percent=30)],
    [w("n1", "exec", "n2", "exec_in"), w("n2", "exec_out", "n3", "exec_in"), w("n3", "exec_out", "n4", "exec_in")], caps=["screen.control", "shell.control"])
cmd("second-monitor", "Второй монитор", "Расставить окна и сменить обои",
    [n("n1", "event.monitor@1", 50, 60), n("n2", "action.notify@1", 400, 60, title="Монитор подключён")], [w("n1", "exec", "n2", "exec_in")], caps=["notify.show"])
cmd("downloads", "Сортировка загрузок", "Раскладывает новые файлы по папкам",
    [n("n1", "event.monitor@1", 50, 60), n("n2", "action.notify@1", 400, 60, title="Файл отсортирован")], [w("n1", "exec", "n2", "exec_in")], caps=["notify.show"])
cmd("video-link", "Видео по ссылке", "Предлагает скачать видео через yt-dlp",
    [n("n1", "event.clipboard_link@1", 50, 60), n("n2", "action.notify@1", 400, 60, title="Скачать видео?")],
    [w("n1", "exec", "n2", "exec_in"), w("n1", "url", "n2", "body")], caps=["notify.show"])
cmd("work", "Работа", "Открыть приложения по рабочим столам, не беспокоить, музыка",
    [n("n1", "event.manual@1", 50, 60), n("n2", "action.notify@1", 360, 60, title="Работа")], [w("n1", "exec", "n2", "exec_in")], caps=["notify.show"])
cmd("focus", "Фокус 25 минут", "Таймер, «не беспокоить» и уведомление о перерыве",
    [n("n1", "event.manual@1", 50, 60), n("n2", "logic.delay@1", 360, 60, seconds=1500), n("n3", "action.notify@1", 650, 60, title="Перерыв")],
    [w("n1", "exec", "n2", "exec_in"), w("n2", "exec_out", "n3", "exec_in")], caps=["notify.show"])
cmd("explain", "Объяснить", "Выделенный текст → Gemini объясняет во всплывающем окне",
    [n("n1", "event.manual@1", 50, 60), n("n2", "action.shell@1", 360, 60, command="echo")], [w("n1", "exec", "n2", "exec_in")], caps=["exec.script"])

# editor test fixtures: a type mismatch with a converter fix-it (text -> int) and a not yet approved automation
cmd("mismatch", "Яркость вечером", "Ошибка типа: текст подключён к числу",
    [n("m1", "event.manual@1", 50, 60), n("m2", "action.shell@1", 360, 60, command="echo 30"), n("m3", "action.brightness@1", 760, 60)],
    [w("m1", "exec", "m2", "exec_in"), w("m2", "exec_out", "m3", "exec_in"), w("m2", "stdout", "m3", "percent")], caps=["exec.script", "screen.control"])
cmd("unapproved", "Ночной режим", "Автоматизация, права ещё не подтверждены",
    [n("u1", "event.sunset@1", 50, 60), n("u2", "action.night_filter@1", 400, 60)], [w("u1", "exec", "u2", "exec_in")],
    enabled=False, caps=["screen.control"], approved=[])

# functions (stage 6): a library function and a command that calls it (the collapsed «Вечер»)
os.makedirs(os.path.join(out, "commands", "functions"), exist_ok=True)
fn = {"format": 1, "kind": "function", "id": "quiet-evening", "name": "Тихий вечер", "description": "Ночной фильтр, тёмная тема и яркость.",
      "icon": "function", "exec": True, "inputs": [{"id": "percent", "type": "int", "label": "Яркость, %", "default": 30}], "outputs": [],
      "nodes": [n("fn_in", "function.input@1", 40, 60), n("a", "action.night_filter@1", 340, 60), n("b", "action.dark_theme@1", 700, 60),
                n("c", "action.brightness@1", 1000, 60), n("fn_out", "function.output@1", 1340, 60)],
      "wires": [w("fn_in", "exec", "a", "exec_in"), w("a", "exec_out", "b", "exec_in"), w("b", "exec_out", "c", "exec_in"),
                w("fn_in", "percent", "c", "percent"), w("c", "exec_out", "fn_out", "exec_in")], "variables": [], "comments": []}
json.dump(fn, open(os.path.join(out, "commands", "functions", "quiet-evening.fn.json"), "w"), ensure_ascii=False, indent=1)
cmd("evening-fn", "Вечер (функция)", "Закат → «Тихий вечер»",
    [n("n1", "event.sunset@1", 50, 60), n("n2", "fn.quiet-evening@1", 400, 60, percent=25)],
    [w("n1", "exec", "n2", "exec_in")], caps=["screen.control", "shell.control"])

if big:
    nds, wires, cols = [], [], 20
    rows = max(1, big // cols)
    for r in range(rows):
        for c in range(cols):
            i = "n%d_%d" % (r, c)
            t = "event.manual@1" if c == 0 else ("action.notify@1" if c % 3 else "logic.delay@1")
            nds.append(n(i, t, 50 + c * 330, 50 + r * 190, **({"title": "Шаг %d" % c} if t.startswith("action") else ({"seconds": 1} if t.startswith("logic") else {}))))
            if c > 0:
                prev = "n%d_%d" % (r, c - 1)
                wires.append(w(prev, "exec" if c == 1 else "exec_out", i, "exec_in"))
    cmd("big", "Большой граф", "Сгенерированный граф для проверки производительности", nds, wires, caps=["notify.show"])
print("fixtures in", out)
