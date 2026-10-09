#!/usr/bin/env python3
"""Fake `xray` for the ping tests. `run -test` -> OK. `run -c cfg` -> a SOCKS5 (user/password) server per socks inbound
that relays to FAKE_XRAY_TARGET (host:port) according to FAKE_XRAY_BEHAVIOR {outbound address: spec}:
ok | delay:<sec> | hang | close. FAKE_XRAY_MODE=exit makes it die at once. Records pid / config / child pid in FAKE_XRAY_DIR."""
import json
import os
import socket
import subprocess
import sys
import threading
import time

a = sys.argv[1:]
if a[:2] == ["run", "-test"]:
    print("Xray 26.3.27 (stub)\nConfiguration OK.")
    sys.exit(0)
rec = os.environ["FAKE_XRAY_DIR"]
cfgfile = a[a.index("-c") + 1]
cfg = json.load(open(cfgfile))
open(os.path.join(rec, "pid"), "w").write(str(os.getpid()))
open(os.path.join(rec, "cfgdir"), "w").write(os.path.dirname(cfgfile))
open(os.path.join(rec, "config.json"), "w").write(json.dumps(cfg))
open(os.path.join(rec, "child.pid"), "w").write(str(subprocess.Popen(["sleep", "300"]).pid))
if os.environ.get("FAKE_XRAY_MODE") == "exit":
    sys.exit(3)
beh = json.loads(os.environ.get("FAKE_XRAY_BEHAVIOR", "{}"))
tgt = os.environ["FAKE_XRAY_TARGET"].split(":")
addr_of = {}
for ob in cfg["outbounds"]:
    st = ob.get("settings", {})
    addr_of[ob["tag"]] = (st.get("vnext") or st.get("servers") or [{}])[0].get("address") or st.get("address")
out_of = {r["inboundTag"][0]: r["outboundTag"] for r in cfg["routing"]["rules"]}


def rn(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise OSError
        b += d
    return b


def pipe(x, y):
    try:
        while True:
            d = x.recv(4096)
            if not d:
                break
            y.sendall(d)
    except OSError:
        pass
    finally:
        for s in (x, y):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(c, ib):
    spec = beh.get(addr_of.get(out_of.get(ib["tag"])), "ok")
    try:
        c.settimeout(10)
        hd = rn(c, 2)
        rn(c, hd[1])
        c.sendall(b"\x05\x02")
        v = rn(c, 2)
        user = rn(c, v[1]); pl = rn(c, 1); pw = rn(c, pl[0])
        acc = ib["settings"]["accounts"][0]
        if (user.decode(), pw.decode()) != (acc["user"], acc["pass"]):
            open(os.path.join(rec, "badauth"), "a").write("x")
            c.sendall(b"\x01\x01")
            return
        c.sendall(b"\x01\x00")
        h = rn(c, 4)
        n = rn(c, 1)[0] if h[3] == 3 else {1: 4, 4: 16}[h[3]]
        rn(c, n + 2)
        c.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        if spec == "close":
            return
        if spec == "hang":
            time.sleep(60)
            return
        if spec.startswith("delay:"):
            time.sleep(float(spec[6:]))
        u = socket.create_connection((tgt[0], int(tgt[1])), timeout=5)
        threading.Thread(target=pipe, args=(c, u), daemon=True).start()
        pipe(u, c)
    except OSError:
        pass
    finally:
        c.close()


def listen(ib):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ib["listen"], ib["port"]))
    s.listen(16)
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, ib), daemon=True).start()


for ib in cfg["inbounds"]:
    threading.Thread(target=listen, args=(ib,), daemon=True).start()
while True:
    time.sleep(1)
