"""Fake serpantinum-cmdd for the ask-dialog UI test: serves the ui.request bridge on a temp unix socket, sends one request of
each kind and records the shell's ui_response answers into <out>. Usage: fake_ui_daemon.py SOCKET OUT (exits when done)."""
import json
import os
import socket
import sys

path, out = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.remove(path)
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(1)
srv.settimeout(40)
conn, _ = srv.accept()
f = conn.makefile("rwb")
seen = []


def send(obj):
    f.write((json.dumps(obj, ensure_ascii=False) + "\n").encode())
    f.flush()


def read_until(pred):
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("daemon: shell closed the connection")
        msg = json.loads(line)
        seen.append(msg)
        if pred(msg):
            return msg


read_until(lambda m: m.get("method") == "subscribe")
answers = []
for i, (kind, payload) in enumerate([
        ("ask", {"mode": "choice", "title": "Что включить?", "options": ["Тихо", "Ярко"], "timeout": 30, "command": "demo"}),
        ("ask", {"mode": "text", "title": "Имя?", "default": "Аня", "timeout": 30}),
        ("ask", {"mode": "number", "title": "Сколько?", "timeout": 30}),
        ("ask", {"mode": "confirm", "title": "Точно?", "timeout": 30}),
        ("ask", {"mode": "choice", "title": "Отмена", "options": ["x"], "timeout": 30}),
        ("confirm", {"node": "Команда оболочки", "text": "command=echo ok"}),
        ("show", {"title": "Итог", "text": "Всё готово\nвторая строка"})]):
    send({"ev": "ui.request", "id": "ui%d" % i, "kind": kind, "payload": payload})
    msg = read_until(lambda m: m.get("method") == "ui_response")
    answers.append(msg["params"])
json.dump(answers, open(out, "w", encoding="utf-8"), ensure_ascii=False)
