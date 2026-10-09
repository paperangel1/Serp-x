"""Fake serpantinum-cmdd for the debug-overlay UI test: accepts one shell connection on a temp unix socket, waits for
`subscribe` and then `run`, answers `run` after PUSHING a recorded trace (schema v1, see xcmd/debug.py) and records every
request into <out>. Usage: fake_trace_daemon.py SOCKET OUT [--burst N] (exits when the run was answered)."""
import json
import os
import socket
import sys
import time

path, out = sys.argv[1], sys.argv[2]
burst = int(sys.argv[sys.argv.index("--burst") + 1]) if "--burst" in sys.argv else 0
if os.path.exists(path):
    os.remove(path)
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(1)
srv.settimeout(40)
conn, _ = srv.accept()
f = conn.makefile("rwb")
seen = []
seq = [0]


def send(obj):
    f.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
    f.flush()


def ev(kind, **kw):
    seq[0] += 1
    send(dict({"v": 1, "seq": seq[0], "ev": kind, "run": "1000-1", "t": round(seq[0] * 0.01, 3)}, **kw))


while True:
    line = f.readline()
    if not line:
        break
    msg = json.loads(line)
    seen.append(msg)
    if msg.get("method") == "subscribe":
        send({"id": msg["id"], "ok": True, "result": {"topics": msg["params"]["topics"]}})
    elif msg.get("method") == "run":
        send({"ev": "run.start", "run": "1000-1", "cmd": msg["params"]["ref"], "name": "Наушники", "trigger": "manual",
              "rehearse": bool(msg["params"].get("rehearse")), "debug": True})
        ev("enter", node="n1", type="event.bt_headphones@1")
        ev("exit", node="n1", pins={"device": "Sony WH-1000XM5", "bluetooth": True}, dur=0.0, out_pin="exec")
        ev("wire", exec=True, **{"from": ["n1", "exec"], "to": ["n2", "exec_in"]})
        ev("wire", value="Sony WH-1000XM5", **{"from": ["n1", "device"], "to": ["n2", "device"]})
        ev("enter", node="n2", type="action.audio_output@1")
        ev("exit", node="n2", pins={"device": "Sony WH-1000XM5", "ok": True}, dur=0.04, out_pin="exec_out",
           plan="вызвал бы xcmd.setAudio(Sony WH-1000XM5)", would_undo="вернул бы прежнее значение, когда запуск закончится")
        ev("var", name="last", value="Sony")
        ev("wire", exec=True, **{"from": ["n2", "exec_out"], "to": ["n3", "exec_in"]})
        ev("enter", node="n3", type="action.volume_set@1")
        for i in range(burst):          # a flood of events must be coalesced by the shell (>= 30 ms batches)
            ev("var", name="v%d" % (i % 20), value=str(i))
        ev("error", node="n3", error="Цель «xcmd» оболочки не отвечает", pins={"percent": 40}, dur=0.1)
        send({"ev": "run.end", "run": "1000-1", "cmd": msg["params"]["ref"], "name": "Наушники", "status": "err", "reason": "node_error",
              "message": "Цель «xcmd» оболочки не отвечает", "failed_node": "n3", "dur": 0.3})
        time.sleep(0.2)
        send({"id": msg["id"], "ok": True, "result": {"run": "1000-1", "status": "err", "reason": "node_error",
                                                       "message": "Цель «xcmd» оболочки не отвечает", "steps": []}})
        break
json.dump(seen, open(out, "w", encoding="utf-8"), ensure_ascii=False)
