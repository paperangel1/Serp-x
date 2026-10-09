"""Node schema: the single source of truth (design §3). Editor nodes, validation, execution dispatch and the
reference docs are all derived from the JSON files in nodes/."""
import glob
import json
import os

from . import paths, ptypes as T
from .util import read_json

FLOWS = ("event", "action", "pure", "latent")
CATEGORIES = ("event", "action", "logic", "data", "ui", "function")
LANGS = ("ru", "en")
PLANNED_FILE = "planned.json"
KEYWORDS_FILE = "keywords.json"


class SchemaError(Exception):
    pass


class Pin:
    __slots__ = ("id", "type", "label", "default", "has_default", "required", "min", "max", "choices", "literal",
                 "log", "secret", "var_typed", "d")

    def __init__(self, d, generics=()):
        self.d = d
        self.id = d["id"]
        self.type = d["type"]
        self.label = d.get("label", {})
        self.has_default = "default" in d
        self.default = d.get("default")
        self.required = bool(d.get("required", False))
        self.min = d.get("min")
        self.max = d.get("max")
        self.choices = d.get("choices")
        self.literal = bool(d.get("literal", False))      # only a literal in props, never a wire
        self.log = d.get("log", "full")                    # full | length | mask
        self.secret = bool(d.get("secret", False))
        self.var_typed = d.get("type_from_var")            # pin type follows the variable named by this literal pin


class NodeDef:
    def __init__(self, d):
        self.d = d
        self.id = d["id"]
        self.version = int(d["version"])
        self.category = d["category"]
        self.flow = d["flow"]
        self.icon = d.get("icon", "")
        self.name = d.get("name", {})
        self.description = d.get("description", {})
        self.example = d.get("example", {})
        self.generics = tuple(d.get("generics", {}).keys())
        self.inputs = [Pin(p, self.generics) for p in d.get("inputs", [])]
        self.outputs = [Pin(p, self.generics) for p in d.get("outputs", [])]
        self.executor = d.get("executor", {})
        self.undo = d.get("undo")
        self.capabilities = list(d.get("capabilities", []))
        self.capabilities_if = d.get("capabilities_if") or {}  # {literal pin id: [extra rights]} when that literal is truthy in props
        self.timeout_s = float(d.get("timeout_s", 30))
        self.danger = d.get("danger", "none")
        self.changes_state = bool(d.get("changes_state", False))
        self.no_undo_reason = d.get("no_undo_reason")
        self.converter = d.get("converter")
        self.stage = d.get("stage")                         # "deferred": schema entry exists, executor not available yet
        self.keywords = d.get("keywords") or {}             # {ru: [...], en: [...]}: extra words for the node search (nodes/keywords.json)
        self.planned = bool(d.get("planned", False))        # nodes/planned.json: pins are fixed, the node is not executable yet
        self.source = d.get("source")
        self.side_effects = bool(d.get("side_effects", self.flow == "action"))

    @property
    def type_string(self):
        return "%s@%d" % (self.id, self.version)

    def pin(self, pid, direction):
        for p in (self.inputs if direction == "in" else self.outputs):
            if p.id == pid:
                return p
        return None

    def label(self, lang="ru"):
        return self.name.get(lang) or self.name.get("ru") or self.id


def parse_type_string(s):
    """'action.notify@1' -> ('action.notify', 1); a missing version means 1."""
    if not isinstance(s, str) or not s:
        return None, None
    if "@" in s:
        base, _, ver = s.rpartition("@")
        try:
            return base, int(ver)
        except ValueError:
            return None, None
    return s, 1


FN_PREFIX = "fn."
FN_INPUT, FN_OUTPUT = "function.input", "function.output"      # interface nodes inside a function graph
FN_IN_ID, FN_OUT_ID = "fn_in", "fn_out"                        # their (fixed) node ids
MAX_FN_DEPTH = 8                                               # nested calls (A -> B -> C ...): validation and engine


def fn_type(fid):
    return "%s%s@1" % (FN_PREFIX, fid)


def fn_id_of(type_string):
    """'fn.abc@1' -> 'abc'; None for an ordinary node type."""
    base, _ = parse_type_string(type_string)
    return base[len(FN_PREFIX):] if base and base.startswith(FN_PREFIX) else None


class Schema:
    def __init__(self):
        self.nodes = {}
        self.unknown_keywords = []
        self.planned = {}           # planned nodes (nodes/planned.json): known to the validator, hidden from palette / docs / engine
        self.functions = {}         # fid -> function dict (library, or embedded copies in an overlay)
        self.fn_nodes = {}          # "fn.<fid>" -> NodeDef generated from the function (a call node)
        self._iface = {}
        self._cp = {}
        self._rep = {}
        self._base = self

    # ---- functions (custom nodes): call nodes are generated, never written by hand
    def set_functions(self, fns):
        """Replace the function set; every function becomes a call node in the palette / validation / docs."""
        self.functions = {f["id"]: f for f in fns if isinstance(f, dict) and f.get("id")}
        self._iface, self._cp, self._rep = {}, {}, {}
        self.fn_nodes = {}
        for fid, fn in self.functions.items():
            self.fn_nodes[FN_PREFIX + fid] = NodeDef(self._call_def(fn))

    def with_functions(self, extra):
        """Overlay with embedded copies of functions; a function of the library is never replaced by an embedded one."""
        extra = [f for f in (extra or []) if isinstance(f, dict) and f.get("id") and f["id"] not in self.functions]
        if not extra:
            return self
        sch = Schema()
        sch.nodes = self.nodes
        sch.planned = self.planned
        sch.set_functions(list(self.functions.values()) + extra)
        return sch

    def _caps_of(self, fn, seen):
        caps = set()
        for n in fn.get("nodes") or []:
            base, _ = parse_type_string(n.get("type", "")) if isinstance(n, dict) else (None, None)
            if base in self.nodes:
                caps.update(self.nodes[base].capabilities)
            elif base and base.startswith(FN_PREFIX):
                fid = base[len(FN_PREFIX):]
                if fid in self.functions and fid not in seen:
                    caps |= self._caps_of(self.functions[fid], seen | {fid})
        return caps

    def _reverts(self, fn, seen):
        for n in fn.get("nodes") or []:
            base, _ = parse_type_string(n.get("type", "")) if isinstance(n, dict) else (None, None)
            if base in self.nodes and self.nodes[base].undo:
                return True
            fid = base[len(FN_PREFIX):] if base and base.startswith(FN_PREFIX) else None
            if fid in self.functions and fid not in seen and self._reverts(self.functions[fid], seen | {fid}):
                return True
        return False

    def _call_def(self, fn):
        lab = lambda s: {"ru": s, "en": s}
        has_exec = bool(fn.get("exec"))

        def pin(p, direction):
            d = {"id": p["id"], "type": p["type"], "label": p.get("label") if isinstance(p.get("label"), dict) else lab(p.get("label") or p["id"])}
            if direction == "in":
                if "default" in p:
                    d["default"] = p["default"]
                elif p["type"] != "exec":
                    d["required"] = bool(p.get("required", True))
            if p.get("description"):
                d["description"] = lab(p["description"]) if isinstance(p["description"], str) else p["description"]
            return d
        ins = [pin(p, "in") for p in fn.get("inputs") or []]
        outs = [pin(p, "out") for p in fn.get("outputs") or []]
        if has_exec:
            ins.insert(0, {"id": "exec_in", "type": "exec"})
            outs.insert(0, {"id": "exec_out", "type": "exec", "label": {"ru": "Готово", "en": "Done"}})
        name = fn.get("name") or fn["id"]
        desc = fn.get("description") or ""
        n_inner = len([n for n in fn.get("nodes") or [] if isinstance(n, dict) and n.get("type") not in (FN_INPUT + "@1", FN_OUTPUT + "@1")])
        ex = {"ru": "Функция «%s»: %d узл. внутри" % (name, n_inner), "en": "Function «%s»: %d nodes inside" % (name, n_inner)}
        return {"id": FN_PREFIX + fn["id"], "version": 1, "category": "function", "flow": "action" if has_exec else "pure",
                "icon": fn.get("icon") or "function", "name": lab(name), "description": lab(desc or name), "example": ex,
                "inputs": ins, "outputs": outs, "executor": {"kind": "function", "ref": fn["id"]},
                "capabilities": sorted(self._caps_of(fn, {fn["id"]})), "timeout_s": 3600, "danger": "none",
                "side_effects": has_exec, "function": {"id": fn["id"], "nodes": n_inner, "reverts": self._reverts(fn, {fn["id"]})}}

    def for_function(self, fn):
        """Schema used inside one function graph: this one plus the two interface nodes built from its declaration."""
        key = (fn.get("id"), id(fn))
        sch = self._iface.get(key)
        if sch is None:
            sch = Schema()
            sch._base = self._base
            sch.nodes = dict(self.nodes)
            sch.planned = self.planned
            sch.functions, sch.fn_nodes = self.functions, self.fn_nodes
            has_exec = bool(fn.get("exec"))
            lab = lambda s: {"ru": s, "en": s}

            def pins(lst, is_in):
                out = []
                for p in lst:
                    d = {"id": p["id"], "type": p["type"], "label": p.get("label") if isinstance(p.get("label"), dict) else lab(p.get("label") or p["id"])}
                    out.append(d)
                return out
            i_outs = pins(fn.get("inputs") or [], False)
            o_ins = pins(fn.get("outputs") or [], True)
            for d in o_ins:
                d["required"] = False
            if has_exec:
                i_outs.insert(0, {"id": "exec", "type": "exec"})
                o_ins.insert(0, {"id": "exec_in", "type": "exec"})
            base = {"version": 1, "category": "function", "icon": "function", "capabilities": [], "side_effects": False,
                    "executor": {"kind": "builtin", "ref": "fn_input"}}
            sch.nodes[FN_INPUT] = NodeDef(dict(base, id=FN_INPUT, flow="event" if has_exec else "pure", name=lab("Вход функции"),
                                               description=lab("Входы функции"), example=lab(""), outputs=i_outs, inputs=[]))
            sch.nodes[FN_OUTPUT] = NodeDef(dict(base, id=FN_OUTPUT, flow="action" if has_exec else "pure", name=lab("Выход функции"),
                                                description=lab("Выходы функции"), example=lab(""), inputs=o_ins, outputs=[],
                                                executor={"kind": "builtin", "ref": "fn_output"}))
            self._iface[key] = sch
        return sch

    def call_problem(self, fid):
        """None | ('cycle', [names]) | ('depth', n): what is wrong with the calls made from this function."""
        if fid in self._cp:
            return self._cp[fid]
        res, depth = None, {}

        def visit(f, path):
            nonlocal res
            fn = self.functions.get(f)
            if fn is None or res is not None:
                return 0
            best = 0
            for n in fn.get("nodes") or []:
                g = fn_id_of(n.get("type", "")) if isinstance(n, dict) else None
                if g is None or g not in self.functions:
                    continue
                if g in path:
                    cyc = path[path.index(g):] + [g]
                    res = ("cycle", [self.functions[x].get("name", x) for x in cyc])
                    return 0
                best = max(best, 1 + visit(g, path + [g]))
            return best
        d = visit(fid, [fid])
        if res is None and d + 1 > MAX_FN_DEPTH:
            res = ("depth", d + 1)
        self._cp[fid] = res
        return res

    def add(self, d, source="?"):
        for key in ("id", "version", "category", "flow"):
            if key not in d:
                raise SchemaError("%s: node without «%s»" % (source, key))
        if d["id"] in self.nodes:
            raise SchemaError("%s: duplicate node id %s" % (source, d["id"]))
        if d["flow"] not in FLOWS:
            raise SchemaError("%s: %s has unknown flow %s" % (source, d["id"], d["flow"]))
        self.nodes[d["id"]] = NodeDef(d)

    def add_planned(self, d, source="?"):
        d = dict(d, planned=True)
        for key in ("id", "version", "category", "flow"):
            if key not in d:
                raise SchemaError("%s: planned node without «%s»" % (source, key))
        if d["id"] in self.nodes or d["id"] in self.planned:
            raise SchemaError("%s: duplicate node id %s" % (source, d["id"]))
        self.planned[d["id"]] = NodeDef(d)

    def get(self, type_string):
        """(NodeDef, None) | (None, 'unknown'|'version'); planned nodes are returned too (check `.planned`)"""
        base, ver = parse_type_string(type_string)
        nd = (self.nodes.get(base) or self.fn_nodes.get(base) or self.planned.get(base)) if base else None
        if nd is None:
            return None, "unknown"
        if ver != nd.version:
            return None, "version"
        return nd, None

    def converters(self):
        return sorted((n for n in self.nodes.values() if n.converter), key=lambda n: n.id)

    def all_nodes(self):
        return list(self.nodes.values()) + list(self.fn_nodes.values())

    def by_category(self):
        out = {}
        for nd in sorted(self.all_nodes(), key=lambda n: n.id):
            out.setdefault(nd.category, []).append(nd)
        return out

    def event_nodes(self, emits):
        return [n for n in self.nodes.values() if n.flow == "event" and (n.source or {}).get("emits") == emits]


def load_schema(dirs=None):
    sch = Schema()
    kw = {}
    for d in (dirs if dirs is not None else paths.nodes_dirs()):
        for f in sorted(glob.glob(os.path.join(d, "*.json"))):
            try:
                data = read_json(f)
            except (OSError, ValueError) as e:
                raise SchemaError("%s: %s" % (f, e))
            if os.path.basename(f) == KEYWORDS_FILE:
                kw.update(data.get("keywords", {}))
                continue
            planned = os.path.basename(f) == PLANNED_FILE
            for nd in data.get("nodes", []):
                (sch.add_planned if planned else sch.add)(nd, os.path.basename(f))
    for nd in list(sch.nodes.values()) + list(sch.planned.values()):
        nd.keywords = kw.get(nd.id, {})
    sch.unknown_keywords = sorted(set(kw) - set(sch.nodes) - set(sch.planned))
    if dirs is None:                                    # the default schema also carries the function library (call nodes)
        from .fnstore import FnStore
        sch.set_functions(FnStore().load().all())
    return sch


def planned_check(sch):
    """The planned nodes must be as well documented as real ones (ru+en name/description/example, pin labels, valid types)."""
    problems = []
    for nd in sorted(sch.planned.values(), key=lambda n: n.id):
        w = nd.id
        if nd.category not in CATEGORIES:
            problems.append("%s: unknown category %s" % (w, nd.category))
        if w in sch.nodes:
            problems.append("%s: planned and real at once" % w)
        for lang in LANGS:
            for field in ("name", "description", "example"):
                if not getattr(nd, field).get(lang):
                    problems.append("%s: no %s.%s" % (w, field, lang))
        if "capabilities" not in nd.d:
            problems.append("%s: capabilities not declared" % w)
        for pin in nd.inputs + nd.outputs:
            if not T.valid_type(pin.type, nd.generics):
                problems.append("%s.%s: invalid type %s" % (w, pin.id, pin.type))
            for lang in LANGS:
                if pin.type != "exec" and not pin.label.get(lang):
                    problems.append("%s.%s: no label.%s" % (w, pin.id, lang))
    return problems


def keywords_check(sch):
    problems = ["keywords.json: unknown node %s" % k for k in getattr(sch, "unknown_keywords", [])]
    for nd in sorted(list(sch.nodes.values()) + list(sch.planned.values()), key=lambda n: n.id):
        for lang in LANGS:
            if not nd.keywords.get(lang):
                problems.append("%s: no keywords.%s (node search)" % (nd.id, lang))
    return problems


def schema_check(sch, registry=None, builtins=None):
    """Problems found in the schema itself (CI / doctor). `registry` = py executor names, `builtins` = engine handlers."""
    problems = planned_check(sch) + keywords_check(sch)
    for nd in sorted(sch.nodes.values(), key=lambda n: n.id):
        w = nd.id
        if nd.category not in CATEGORIES:
            problems.append("%s: unknown category %s" % (w, nd.category))
        for lang in LANGS:
            for field in ("name", "description", "example"):
                if not getattr(nd, field).get(lang):
                    problems.append("%s: no %s.%s" % (w, field, lang))
        if "capabilities" not in nd.d:
            problems.append("%s: capabilities not declared" % w)
        seen = set()
        for pin in nd.inputs + nd.outputs:
            if pin.id in seen:
                problems.append("%s: duplicate pin %s" % (w, pin.id))
            seen.add(pin.id)
            if not T.valid_type(pin.type, nd.generics):
                problems.append("%s.%s: invalid type %s" % (w, pin.id, pin.type))
            for lang in LANGS:
                if pin.type != "exec" and not pin.label.get(lang):
                    problems.append("%s.%s: no label.%s" % (w, pin.id, lang))
            if pin.has_default and pin.type != "exec":
                err = T.check_literal(pin.type, pin.default)
                if err:
                    problems.append("%s.%s: bad default (%s)" % (w, pin.id, err))
        ex = nd.executor
        kind = ex.get("kind")
        if kind not in ("builtin", "py", "ipc"):
            problems.append("%s: executor kind %s" % (w, kind))
        elif kind == "builtin" and builtins is not None and ex.get("ref") not in builtins:
            problems.append("%s: builtin handler %s missing" % (w, ex.get("ref")))
        elif kind == "py" and registry is not None and ex.get("ref") not in registry:
            problems.append("%s: py executor %s missing" % (w, ex.get("ref")))
        elif kind == "ipc" and not (ex.get("target") and ex.get("fn")):
            problems.append("%s: ipc executor needs target and fn" % w)
        if nd.flow in ("action", "latent") and not any(p.type == "exec" for p in nd.inputs):
            problems.append("%s: %s node without an exec input" % (w, nd.flow))
        if nd.flow == "pure" and any(p.type == "exec" for p in nd.inputs + nd.outputs):
            problems.append("%s: pure node must not have exec pins" % w)
        if nd.flow == "event" and not any(p.type == "exec" for p in nd.outputs):
            problems.append("%s: event node without an exec output" % w)
        if nd.changes_state and not nd.undo and not nd.no_undo_reason:
            problems.append("%s: changes state, has no undo and no no_undo_reason" % w)
        if nd.undo:
            for key in ("capture", "restore"):
                ref = nd.undo.get(key)
                if not ref:
                    problems.append("%s: undo.%s missing" % (w, key))
                elif nd.executor.get("kind") == "py" and registry is not None and ref not in registry:
                    problems.append("%s: undo.%s executor %s missing" % (w, key, ref))
            if not nd.changes_state:
                problems.append("%s: undo declared but changes_state is false" % w)
        if nd.danger not in ("none", "confirm"):
            problems.append("%s: danger %s" % (w, nd.danger))
        if nd.converter and not (nd.converter.get("from") and nd.converter.get("to")):
            problems.append("%s: converter needs from/to" % w)
    return problems
