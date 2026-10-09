"""The Xray binary: capability detection (read-only file scan) and config validation (`run -test`).

Safety contract (the user's real VPN may be up, so nothing here may touch the network):
  * capabilities are detected by scanning the binary's bytes, xray is NOT executed for that;
  * the only xray invocation is `xray run -test -c FILE`, and only for a config WITHOUT inbounds
    (guard below raises otherwise), additionally wrapped in an isolated user+net namespace when
    `unshare` can provide one, so even a surprise could not reach the host network.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile

from . import paths

from .xlogshim import log

MARKERS = {
    "tun": b"xray-core/proxy/tun/",
    "hysteria": b"xray-core/proxy/hysteria/",
    "reality": b"xray-core/transport/internet/reality/",
    "xhttp": b"xray-core/transport/internet/splithttp/",
    "shadowsocks": b"xray-core/proxy/shadowsocks/",
    "trojan": b"xray-core/proxy/trojan/",
    "fakedns": b"xray-core/app/dns/fakedns/",
}


def xray_path():
    p = os.environ.get("XVPN_XRAY")
    if p:
        return p
    return shutil.which("xray") or "/usr/bin/xray"


def capabilities(path=None):
    """-> {"path", "exists", "version", "tun", "hysteria", ...}; version from the binary's own banner string."""
    path = path or xray_path()
    out = {"path": path, "exists": os.path.isfile(path), "version": ""}
    for k in MARKERS:
        out[k] = False
    if not out["exists"]:
        return out
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        out["exists"] = False
        return out
    for k, m in MARKERS.items():
        out[k] = m in data
    m = re.search(rb"Xray (\d+\.\d+\.\d+)", data)
    if m:
        out["version"] = m.group(1).decode()
    else:                      # the banner is built at run time: use what the last `-test` printed
        cached = paths.read_json(paths.state_dir() / "core.json", {}) or {}
        try:
            if cached.get("path") == path and cached.get("mtime") == int(os.path.getmtime(path)):
                out["version"] = cached.get("version", "")
        except OSError:
            pass
    return out


def _remember_version(path, text):
    m = re.search(r"Xray (\d+\.\d+\.\d+)", text)
    if not m:
        return
    try:
        paths.write_json(paths.state_dir() / "core.json", {"path": path, "mtime": int(os.path.getmtime(path)), "version": m.group(1)}, 0o600)
    except OSError:
        pass


def _isolated_prefix():
    """['unshare','--user','--net','--map-root-user','--'] when an unprivileged netns works, else []."""
    if os.environ.get("XVPN_NO_UNSHARE") == "1" or not shutil.which("unshare"):
        return []
    try:
        r = subprocess.run(["unshare", "--user", "--net", "--map-root-user", "true"],
                           capture_output=True, timeout=5)
        if r.returncode == 0:
            return ["unshare", "--user", "--net", "--map-root-user", "--"]
    except (OSError, subprocess.SubprocessError):
        pass
    return []


def validate(cfg, runner=subprocess.run, geo_dir=None):
    ok, msg = _validate(cfg, runner=runner, geo_dir=geo_dir)
    (log.info if ok else log.warn)("xray -test", ok=ok, message=None if ok else str(msg)[:300])
    return ok, msg


def _validate(cfg, runner=subprocess.run, geo_dir=None):
    """`xray run -test` on the inbound-less variant. -> (ok, message). Never starts a listener or a device."""
    if cfg.get("inbounds"):
        raise RuntimeError("refusing to run xray -test on a config with inbounds")
    path = xray_path()
    if not os.path.isfile(path) and runner is subprocess.run:
        return False, "xray not found"
    td = tempfile.mkdtemp(prefix="xvpn-test-")
    try:
        os.chmod(td, 0o700)
        f = os.path.join(td, "config.json")
        with open(f, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh)
        os.chmod(f, 0o600)
        env = dict(os.environ)
        if geo_dir:
            env["XRAY_LOCATION_ASSET"] = str(geo_dir)
        cmd = _isolated_prefix() + [path, "run", "-test", "-c", f]
        try:
            r = runner(cmd, capture_output=True, text=True, timeout=25, env=env)
        except (OSError, subprocess.SubprocessError) as e:
            return False, "xray failed to run: " + e.__class__.__name__
        text = ((r.stdout or "") + (r.stderr or "")).strip()
        _remember_version(path, text)
        if r.returncode == 0 and "Configuration OK" in text:
            return True, "ok"
        return False, _sanitize(text)[-400:] or f"exit {r.returncode}"
    finally:
        shutil.rmtree(td, ignore_errors=True)


def _sanitize(text):
    """Error text may echo config fragments: strip anything that looks like a credential."""
    text = re.sub(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "<uuid>", text)
    text = re.sub(r'("(?:password|id|auth|publicKey|shortId)"\s*:\s*)"[^"]*"', r'\1"<hidden>"', text)
    return text


def geo_dir():
    return paths.data_dir() / "geo"


def geo_present():
    d = geo_dir()
    return (d / "geoip.dat").is_file() and (d / "geosite.dat").is_file()
