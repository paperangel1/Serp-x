"""Example gallery (design §10): ready-made commands in assets/custom-commands/gallery/*.cmd.json, every step annotated with
comment nodes (ru + en). A gallery command may use nodes that do not exist yet (nodes/planned.json): it is then «pending»
(«ждёт узлов»), still opens in the editor, and becomes ready by itself when stage 9 implements those nodes."""
import copy
import glob
import os
import shutil

from . import paths
from .model import compute_capabilities
from .schema import parse_type_string
from .util import read_json
from .validate import validate
from .xlogshim import log as xlog

MANIFEST = "gallery.json"
PENDING_CODES = {"planned_node"}                       # the only errors a pending command may have
TOLERATED_WARNINGS = {"planned_node", "deferred_node", "danger_confirm", "no_undo", "loop_no_delay"}     # inherent to the example, not mistakes


def _pick(v, lang):
    return (v.get(lang) or v.get("ru") or "") if isinstance(v, dict) else (v or "")


def localize(cmd, lang):
    """A copy for the editor / the user's list: comments become plain strings in `lang`, the gallery block is dropped."""
    out = copy.deepcopy(cmd)
    meta = out.pop("gallery", None) or {}
    for c in out.get("comments") or []:
        for k in ("title", "text"):
            if k in c:
                c[k] = _pick(c[k], lang)
    if lang != "ru":
        out["name"] = _pick(meta.get("name"), lang) or out.get("name", "")
        out["description"] = _pick(meta.get("description"), lang) or out.get("description", "")
    return out


def analyse(cmd, sch):
    """What the gallery card needs: missing nodes (planned / deferred), capabilities incl. planned ones, validation codes."""
    missing, caps, events = [], set(), []
    for n in cmd.get("nodes", []):
        nd, _ = sch.get(n.get("type", ""))
        base, _v = parse_type_string(n.get("type", ""))
        if nd is None:
            missing.append(base)                        # unknown node: counted as missing, validation reports it separately
            continue
        caps.update(nd.capabilities)
        if nd.planned or nd.stage == "deferred":
            missing.append(nd.id)
        if nd.category == "event" and nd.id != "event.manual":
            events.append(nd.id)
    rep = validate(cmd, sch)
    return {"missing": sorted(set(missing)), "capabilities": sorted(caps), "events": events,
            "errors": sorted({i["code"] for i in rep["errors"]}), "warnings": sorted({i["code"] for i in rep["warnings"]}),
            "real_capabilities": compute_capabilities(cmd, sch)}


def files(gdir=None):
    return sorted(glob.glob(os.path.join(gdir or paths.gallery_dir(), "*.cmd.json")))


def entry_for(path, sch):
    cmd = read_json(path)
    meta = cmd.get("gallery") or {}
    a = analyse(cmd, sch)
    missing = a["missing"]
    return {"id": os.path.basename(path)[:-len(".cmd.json")], "file": os.path.basename(path), "command_id": cmd.get("id", ""),
            "name": meta.get("name") or {"ru": cmd.get("name", ""), "en": cmd.get("name", "")},
            "description": meta.get("description") or {"ru": cmd.get("description", ""), "en": cmd.get("description", "")},
            "category": meta.get("category", "other"), "tags": meta.get("tags") or {"ru": [], "en": []},
            "packages": list(meta.get("packages") or []), "capabilities": a["capabilities"], "events": a["events"],
            "nodes": len([n for n in cmd.get("nodes", [])]), "comments": len(cmd.get("comments") or []),
            "ready": not missing and not a["errors"], "missing": missing, "errors": a["errors"], "warnings": a["warnings"]}


def manifest(sch, gdir=None):
    """The committed gallery.json: derived from the files (a test fails when it is stale)."""
    items = []
    for f in files(gdir):
        e = entry_for(f, sch)
        items.append({k: e[k] for k in ("id", "file", "category", "ready", "missing", "packages", "capabilities", "events", "nodes")})
    return {"format": 1, "gallery": items}


def check(sch, gdir=None):
    """Problems of the gallery itself: ready ones must validate cleanly, pending ones may fail only because of missing nodes."""
    problems = []
    for f in files(gdir):
        e = entry_for(f, sch)
        w = e["file"]
        for lang in ("ru", "en"):
            if not e["name"].get(lang) or not e["description"].get(lang):
                problems.append("%s: no name/description in %s" % (w, lang))
        cmd = read_json(f)
        if not (cmd.get("comments") or []):
            problems.append("%s: no comment nodes" % w)
        for c in cmd.get("comments") or []:
            for k in ("title", "text"):
                v = c.get(k)
                if not (isinstance(v, dict) and v.get("ru") and v.get("en")):
                    problems.append("%s: comment %s.%s is not ru+en" % (w, c.get("id"), k))
        if cmd.get("enabled", False):
            problems.append("%s: a gallery command must be disabled" % w)
        extra_err = [c for c in e["errors"] if c not in PENDING_CODES]
        if extra_err:
            problems.append("%s: errors %s" % (w, ", ".join(extra_err)))
        if e["ready"] and {"planned_node", "deferred_node"} & set(e["warnings"]):
            problems.append("%s: ready but reports planned/deferred nodes" % w)
        if not e["ready"] and not e["missing"]:
            problems.append("%s: not ready but nothing is missing" % w)
        if e["missing"] and "planned_node" not in e["errors"] and all(m in sch.planned for m in e["missing"]):
            problems.append("%s: planned nodes missing but the validator did not report them" % w)
        bad_w = [c for c in e["warnings"] if c not in TOLERATED_WARNINGS]
        if bad_w:
            problems.append("%s: warnings %s" % (w, ", ".join(bad_w)))
    return problems


def find(ref, gdir=None):
    ref = (ref or "").strip().lower()
    for f in files(gdir):
        cmd = read_json(f)
        names = [os.path.basename(f)[:-len(".cmd.json")], cmd.get("id", "")]
        meta = (cmd.get("gallery") or {}).get("name") or {}
        names += [cmd.get("name", "")] + list(meta.values())
        if ref in [n.lower() for n in names if n]:
            return f
    return None


def installed(pkg):
    return shutil.which(pkg) is not None


def ui_data(sch, lang, gdir=None):
    """For the window: cards in `lang` plus the real state of required packages."""
    out = []
    for f in files(gdir):
        e = entry_for(f, sch)
        out.append({"id": e["id"], "file": f, "name": _pick(e["name"], lang), "description": _pick(e["description"], lang),
                    "category": e["category"], "tags": e["tags"].get(lang) or [], "ready": e["ready"], "missing": e["missing"],
                    "packages": [{"name": p, "installed": installed(p)} for p in e["packages"]],
                    "capabilities": e["capabilities"], "events": e["events"], "nodes": e["nodes"]})
    return out


def add(be, ref, lang="ru", gdir=None):
    """Copy a gallery command into the user's commands (disabled, rights not approved). Returns {id, name, ready, missing}."""
    f = find(ref, gdir)
    if f is None:
        raise KeyError(ref)
    cmd = localize(read_json(f), lang)
    base = cmd["name"]
    existing = {c["name"].strip().lower() for c in be.call("list").get("commands", [])}
    name, n = base, 2
    while name.strip().lower() in existing:
        name = "%s %d" % (base, n)
        n += 1
    import tempfile
    import json
    cmd["name"] = name
    cmd.pop("id", None)
    cmd["enabled"] = False
    fd, tmp = tempfile.mkstemp(prefix="xcmd-gallery-", suffix=".cmd.json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(cmd, fh, ensure_ascii=False)
        res = be.call("new", {"name": name, "from": tmp})
    finally:
        os.unlink(tmp)
    from .schema import load_schema
    e = entry_for(f, load_schema())
    xlog.info("gallery add", gallery=e["id"], ready=e["ready"], missing=len(e["missing"]))
    return {"id": res["id"], "name": res["name"], "ready": e["ready"], "missing": e["missing"]}
