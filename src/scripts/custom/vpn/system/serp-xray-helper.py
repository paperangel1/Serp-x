#!/usr/bin/python3
"""serp-xray-helper: the ONLY root-side code of the Serpantinum VPN. Installed by `x_vpn.sh install` as a
root-owned copy (the allowlist below is inlined at install time); never run from the user's checkout.

Commands (called by serp-xray.service / serp-xray-unblock.service):
  guard       refuse to start while Happ's tunnel/service is active (never both at once)
  prepare     validate the user-written config against an allowlist and stage it under /run/serp-xray
  post-start  wait for the TUN device, assign addresses, install policy routing (activation is the LAST step)
  post-stop   remove everything again (or, with kill-switch on and an unclean stop, leave a blackhole)
  unblock     remove everything including a kill-switch blackhole

Routing model (WireGuard-quick style, no loops): xray's own sockets carry fwmark MARK and use the main
table; LAN stays direct (suppress_prefixlength 0); all other traffic uses TABLE whose default route is the
tunnel (or a blackhole for IPv6 when blocking is on).
"""
import ipaddress
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import time

MARK = 9011
TABLE = 22333
TUN = "serp-xray"
ADDR4 = "172.30.255.1/30"
ADDR6 = "fd00:5e72:7878::1/126"
RUN = "/run/serp-xray"
KS_MARK = "/run/serp-xray-killswitch"
PREF_NODE, PREF_MARK, PREF_SUPP, PREF_TUN = 9000, 9100, 9150, 9200
MAX_CONFIG = 1_000_000

# @@ALLOWLIST@@


def run(cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip()[:200]}")
    return r.returncode


def _user_file(path, uid, max_size=None):
    max_size = max_size or MAX_CONFIG
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != uid or st.st_size > max_size:
        raise RuntimeError(f"unsafe file: {path}")
    return path


HAPP_CORE = "/opt/happ/bin/core/xray"


def guard():
    # happd.service runs permanently (it only controls the app's processes), so the daemon alone is NOT a
    # conflict. Happ's VPN is on only while its core xray runs, or its tunnel holds the default route.
    if subprocess.run(["pgrep", "-f", HAPP_CORE], capture_output=True).returncode == 0:
        raise RuntimeError("Happ VPN is active (its xray core is running)")
    if os.path.exists("/sys/class/net/happ-xray"):
        r = subprocess.run(["ip", "-o", "route", "show", "default", "dev", "happ-xray"],
                           capture_output=True, text=True)
        if r.stdout.strip():
            raise RuntimeError("Happ tunnel holds the default route")


def prepare():
    user = os.environ["XVPN_USER"]
    uid = pwd.getpwnam(user).pw_uid
    state = os.environ["XVPN_USER_STATE"]
    data = os.environ.get("XVPN_USER_DATA", "")
    cfg_path = _user_file(os.path.join(state, "config.json"), uid)
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    check_root_safe(cfg)
    os.makedirs(RUN, mode=0o700, exist_ok=True)
    _write(os.path.join(RUN, "config.json"), json.dumps(cfg), 0o600)
    rt = {"killSwitch": False, "blockIPv6": True, "bypassIps": []}
    try:
        with open(_user_file(os.path.join(state, "runtime.json"), uid), "r", encoding="utf-8") as rf:
            raw = json.load(rf)
        rt["killSwitch"] = bool(raw.get("killSwitch"))
        rt["blockIPv6"] = bool(raw.get("blockIPv6", True))
        for ip in (raw.get("bypassIps") or [])[:256]:
            try:
                rt["bypassIps"].append(str(ipaddress.ip_address(str(ip))))
            except ValueError:
                continue
    except (OSError, ValueError, RuntimeError, TypeError):
        pass
    _write(os.path.join(RUN, "runtime.json"), json.dumps(rt), 0o600)
    geo = os.path.join(RUN, "geo")
    os.makedirs(geo, mode=0o755, exist_ok=True)
    for name in ("geoip.dat", "geosite.dat"):
        dst = os.path.join(geo, name)
        for src in (os.path.join(data, "geo", name), "/usr/share/v2ray/" + name, "/usr/share/xray/" + name):
            try:
                if src.startswith(data) and data:
                    _user_file(src, uid, 200_000_000)
                shutil.copyfile(src, dst)
                os.chmod(dst, 0o644)
                break
            except (OSError, RuntimeError):
                continue


def _write(path, text, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def _rt():
    try:
        with open(os.path.join(RUN, "runtime.json"), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"killSwitch": False, "blockIPv6": True, "bypassIps": []}


def _ip(fam, *args, check=True):
    return run(["ip", fam, *args], check=check)


def cleanup():
    """Remove every rule/route we may have added. Idempotent, never raises."""
    for fam in ("-4", "-6"):
        for pref in (PREF_TUN, PREF_SUPP, PREF_MARK):
            for _ in range(4):
                if _ip(fam, "rule", "del", "pref", str(pref), check=False) != 0:
                    break
        for _ in range(300):                       # node bypass rules
            if _ip(fam, "rule", "del", "pref", str(PREF_NODE), check=False) != 0:
                break
        _ip(fam, "route", "flush", "table", str(TABLE), check=False)
    try:
        os.unlink(KS_MARK)
    except OSError:
        pass


def post_start():
    rt = _rt()
    for _ in range(100):                           # up to 10 s for the TUN device
        if os.path.exists(f"/sys/class/net/{TUN}"):
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("tun device did not appear")
    cleanup()
    try:
        run(["ip", "link", "set", TUN, "up", "mtu", "1500"])
        run(["ip", "addr", "replace", ADDR4, "dev", TUN])
        run(["ip", "-6", "addr", "replace", ADDR6, "dev", TUN], check=False)
        for ip in rt.get("bypassIps", []):
            fam = "-6" if ":" in ip else "-4"
            mask = "128" if fam == "-6" else "32"
            _ip(fam, "rule", "add", "pref", str(PREF_NODE), "to", f"{ip}/{mask}", "lookup", "main")
        for fam in ("-4", "-6"):
            _ip(fam, "rule", "add", "pref", str(PREF_MARK), "fwmark", hex(MARK), "lookup", "main", check=(fam == "-4"))
            _ip(fam, "rule", "add", "pref", str(PREF_SUPP), "lookup", "main", "suppress_prefixlength", "0", check=(fam == "-4"))
        run(["ip", "-4", "route", "replace", "default", "dev", TUN, "table", str(TABLE)])
        if rt.get("blockIPv6", True):
            _ip("-6", "route", "replace", "blackhole", "default", "table", str(TABLE), check=False)
        else:
            _ip("-6", "route", "replace", "default", "dev", TUN, "table", str(TABLE), check=False)
        for fam in ("-4", "-6"):                    # activation: the very last step
            _ip(fam, "rule", "add", "pref", str(PREF_TUN), "lookup", str(TABLE), check=(fam == "-4"))
    except Exception:
        cleanup()
        raise


def post_stop():
    rt = _rt()
    unclean = os.environ.get("SERVICE_RESULT", "success") != "success"
    if rt.get("killSwitch") and unclean:
        for fam in ("-4", "-6"):
            _ip(fam, "route", "replace", "blackhole", "default", "table", str(TABLE), check=False)
            _ip(fam, "rule", "add", "pref", str(PREF_TUN), "lookup", str(TABLE), check=False)
            _ip(fam, "rule", "add", "pref", str(PREF_SUPP), "lookup", "main", "suppress_prefixlength", "0", check=False)
            _ip(fam, "rule", "add", "pref", str(PREF_MARK), "fwmark", hex(MARK), "lookup", "main", check=False)
        _write(KS_MARK, "1", 0o644)
        return
    cleanup()


def unblock():
    cleanup()


COMMANDS = {"guard": guard, "prepare": prepare, "post-start": post_start, "post-stop": post_stop, "unblock": unblock}


def main(argv):
    if len(argv) != 2 or argv[1] not in COMMANDS:
        print("usage: serp-xray-helper {" + "|".join(COMMANDS) + "}", file=sys.stderr)
        return 2
    try:
        COMMANDS[argv[1]]()
    except Exception as e:  # noqa: BLE001 - systemd shows this line
        print("serp-xray-helper:", argv[1], "failed:", e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
