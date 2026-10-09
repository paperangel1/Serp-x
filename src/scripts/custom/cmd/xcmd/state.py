"""Persistent engine state (state.json) and the undo stacks of running commands (undo/<run>.json)."""
import json
import os

from .model import atomic_write
from .util import read_json


class State:
    def __init__(self, directory):
        self.path = os.path.join(directory, "state.json")
        self.data = {"vars": {}, "paused_all": False, "paused": {}}
        if os.path.exists(self.path):
            try:
                self.data.update(read_json(self.path))
            except (OSError, ValueError):
                pass

    def save(self):
        atomic_write(self.path, json.dumps(self.data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    @property
    def paused_all(self):
        return bool(self.data.get("paused_all"))

    def set_paused_all(self, value):
        self.data["paused_all"] = bool(value)
        self.save()

    def paused_cmds(self):
        return dict(self.data.get("paused", {}))

    def is_paused(self, cmd_id):
        return cmd_id in self.data.get("paused", {})

    def pause_cmd(self, cmd_id, reason, ts):
        self.data.setdefault("paused", {})[cmd_id] = {"reason": reason, "ts": ts}
        self.save()

    def resume_cmd(self, cmd_id):
        self.data.get("paused", {}).pop(cmd_id, None)
        self.save()

    def get_var(self, cmd_id, name, default=None):
        return self.data.get("vars", {}).get(cmd_id, {}).get(name, default)

    def set_var(self, cmd_id, name, value):
        self.data.setdefault("vars", {}).setdefault(cmd_id, {})[name] = value
        self.save()


class UndoStore:
    """Undo stacks live on disk while a run is active so a crash cannot silently lose them (and cannot be
    replayed blindly later: stale stacks are discarded on start, see discard_stale)."""

    def __init__(self, directory):
        self.dir = os.path.join(directory, "undo")

    def _path(self, run_id):
        return os.path.join(self.dir, "%s.json" % run_id)

    def save(self, run_id, cmd_id, entries):
        atomic_write(self._path(run_id), json.dumps({"run": run_id, "cmd": cmd_id, "entries": entries}, ensure_ascii=False))

    def clear(self, run_id):
        try:
            os.remove(self._path(run_id))
        except FileNotFoundError:
            pass

    def discard_stale(self):
        """Remove stacks of runs that no longer exist; returns [(run, cmd, n_entries)] for the log."""
        out = []
        if not os.path.isdir(self.dir):
            return out
        for f in sorted(os.listdir(self.dir)):
            p = os.path.join(self.dir, f)
            try:
                d = read_json(p)
                out.append((d.get("run"), d.get("cmd"), len(d.get("entries", []))))
            except (OSError, ValueError):
                out.append((f, None, 0))
            os.remove(p)
        return out
