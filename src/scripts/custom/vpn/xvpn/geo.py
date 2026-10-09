"""Russian routing lists (geoip.dat / geosite.dat) from a GitHub release, sha256-verified.

Default source: runetfreedom/russia-v2ray-rules-dat (geoip:ru, geosite:category-ru, ru-available-only-inside).
A file is replaced only after its digest matches the one published next to it in the release.
"""
import hashlib
import os
import re
import time
import urllib.error
import urllib.request

from . import core, paths
from .xlogshim import log

FILES = ("geoip.dat", "geosite.dat")
MAX_BYTES = 120_000_000
MIN_BYTES = 1000


class GeoError(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


def _get(url, timeout=60, opener=None, limit=MAX_BYTES):
    req = urllib.request.Request(url, headers={"User-Agent": "serpantinum-x/1"})
    op = opener or urllib.request.urlopen
    try:
        with op(req, timeout=timeout) as r:
            data = r.read(limit + 1)
    except urllib.error.HTTPError as e:
        e.close()
        raise GeoError("http_error", str(e.code)) from None
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise GeoError("network", e.__class__.__name__) from None
    if len(data) > limit:
        raise GeoError("too_large")
    return data


def _digest(text):
    m = re.search(r"\b([0-9a-fA-F]{64})\b", text)
    return m.group(1).lower() if m else ""


def update(base_url=None, opener=None, now=None):
    """Download both lists; -> meta dict. Raises GeoError (existing files stay untouched)."""
    log.info("geo lists update started")
    try:
        meta = _update(base_url, opener, now)
    except GeoError as e:
        log.error("geo lists update failed (old files kept)", code=str(e)[:80])
        raise
    log.info("geo lists updated", source=meta.get("source"), files=len(meta.get("sha256", {})))
    return meta


def _update(base_url=None, opener=None, now=None):
    base = (base_url or paths.load_settings()["geoUrl"]).rstrip("/")
    if base.startswith("http://") and os.environ.get("XVPN_ALLOW_HTTP") != "1" and "127.0.0.1" not in base and "localhost" not in base:
        raise GeoError("http_not_allowed")
    staged = {}
    sums = {}
    for name in FILES:
        data = _get(f"{base}/{name}", opener=opener)
        want = _digest(_get(f"{base}/{name}.sha256sum", opener=opener, limit=4096).decode("utf-8", "replace"))
        if not want:
            raise GeoError("no_digest", name)
        got = hashlib.sha256(data).hexdigest()
        if got != want or len(data) < MIN_BYTES:
            raise GeoError("digest_mismatch", name)
        staged[name] = data
        sums[name] = got
    d = core.geo_dir()
    paths.ensure_dir(d, 0o755)
    for name, data in staged.items():
        paths.atomic_write(d / name, data, 0o644)
    meta = {"updated": int(now or time.time()), "sha256": sums, "source": base.split("/releases")[0].rsplit("/", 1)[-1]}
    paths.write_json(paths.state_dir() / "geo.json", meta, 0o600)
    return meta


def info():
    meta = paths.read_json(paths.state_dir() / "geo.json", {}) or {}
    return {"present": core.geo_present(), "updated": meta.get("updated", 0)}


def due(settings=None, now=None, days=3):
    i = info()
    return (not i["present"]) or ((now or time.time()) - i["updated"] > days * 86400)
