"""Pinned commands: an ordered list of command ids in <commands dir>/.pinned.json (atomic write).

Pins are a UI/launcher preference, not part of a command, so they live next to the commands but never inside a
*.cmd.json (export/import and the history do not carry them). A broken or missing file reads as «nothing pinned»."""
import json
import os

from . import paths
from .model import atomic_write


def path():
    return os.path.join(paths.commands_dir(), ".pinned.json")


def load():
    try:
        with open(path(), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    items = data.get("pinned") if isinstance(data, dict) else data
    out = []
    for x in items if isinstance(items, list) else []:
        if isinstance(x, str) and x and x not in out:
            out.append(x)
    return out


def save(ids):
    atomic_write(path(), json.dumps({"pinned": list(ids)}, ensure_ascii=False, indent=2) + "\n")


def set_pinned(cid, on):
    """Returns True when the file changed."""
    ids = load()
    if on and cid not in ids:
        save(ids + [cid])
        return True
    if not on and cid in ids:
        save([i for i in ids if i != cid])
        return True
    return False


def mark(commands):
    """Add `pinned` (bool) to every command summary dict, in place; returns the same list."""
    ids = set(load())
    for c in commands:
        c["pinned"] = c.get("id", "") in ids
    return commands
