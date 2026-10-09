"""First-launch tutorial: the steps are data (assets/custom-commands/tutorial.json), the progress is a small state file.
The editor reports what the user did (command created, node added, wire added, rehearsal run, saved); a step advances when
the event matches its `advance` rule. The overlay and the pure transition logic live in QML (EditorLogic.js)."""
import json
import os
import re

from . import paths
from .util import read_json
from .xlogshim import log as xlog

TARGETS = ("new_button", "canvas", "debug_button", "save_button", "window")
ADVANCE = re.compile(r"^(next|command_created|saved|rehearsed|node_added:[A-Za-z0-9_.]+\*?|wire_added:(exec|data))$")


def load_steps():
    return read_json(paths.tutorial_file()).get("steps", [])


def check(sch=None, steps=None):
    problems = []
    try:
        steps = load_steps() if steps is None else steps
    except (OSError, ValueError) as e:
        return ["tutorial.json: %s" % e]
    if not 5 <= len(steps) <= 10:
        problems.append("tutorial.json: expected 5-10 steps, got %d" % len(steps))
    seen = set()
    for i, s in enumerate(steps):
        w = "step %d" % (i + 1)
        if not s.get("id") or s["id"] in seen:
            problems.append("%s: missing or duplicate id" % w)
        seen.add(s.get("id"))
        for f in ("title", "text"):
            for lang in ("ru", "en"):
                if not (s.get(f) or {}).get(lang):
                    problems.append("%s: no %s.%s" % (w, f, lang))
        if s.get("target") not in TARGETS:
            problems.append("%s: unknown target %r" % (w, s.get("target")))
        adv = s.get("advance", "")
        if not ADVANCE.match(adv):
            problems.append("%s: bad advance rule %r" % (w, adv))
        elif sch is not None and adv.startswith("node_added:") and not adv.endswith("*"):
            if adv.split(":", 1)[1] not in sch.nodes:
                problems.append("%s: node %s is not in the schema" % (w, adv.split(":", 1)[1]))
    return problems


def _state_path():
    return os.path.join(paths.state_dir(), "tutorial.json")


def get_state():
    try:
        d = read_json(_state_path())
    except (OSError, ValueError):
        d = {}
    return {"done": bool(d.get("done")), "skipped": bool(d.get("skipped")), "step": max(0, int(d.get("step", 0) or 0))}


def set_state(done=None, skipped=None, step=None):
    st = get_state()
    if done is not None:
        st["done"] = bool(done)
    if skipped is not None:
        st["skipped"] = bool(skipped)
    if step is not None:
        st["step"] = max(0, int(step))
    os.makedirs(os.path.dirname(_state_path()), exist_ok=True)
    tmp = _state_path() + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, _state_path())
    xlog.info("tutorial progress", step=st["step"], done=st["done"], skipped=st["skipped"])
    return st


def reset():
    return set_state(done=False, skipped=False, step=0)


def ui_data(lang):
    try:
        steps = load_steps()
    except (OSError, ValueError):
        steps = []
    pick = lambda d: (d.get(lang) or d.get("ru") or "") if isinstance(d, dict) else d
    return {"steps": [{"id": s["id"], "target": s["target"], "title": pick(s["title"]), "text": pick(s["text"]), "advance": s["advance"]}
                      for s in steps], "state": get_state()}
