"""Graph validation (design §4): one implementation, used by the CLI, the daemon, the engine before a run and,
later, by the editor over the socket. Returns structured issues with ru/en messages and optional fix-its."""
import re

from . import ptypes as T
from .model import policy_of, compute_capabilities
from .schema import FN_INPUT, FN_OUTPUT, MAX_FN_DEPTH, fn_id_of

# code -> (level, ru template, en template)
MSG = {
    "bad_command": ("error", "Файл команды повреждён: {why}.", "The command file is broken: {why}."),
    "duplicate_node": ("error", "Идентификатор узла «{node}» встречается дважды.", "Node id «{node}» is used twice."),
    "unknown_node": ("error", "Узел «{node}» имеет неизвестный тип «{type}»: он потерян, команда не запустится.",
                     "Node «{node}» has unknown type «{type}»: it is lost, the command will not run."),
    "node_version": ("error", "Узел «{node}»: версия типа «{type}» не поддерживается.", "Node «{node}»: unsupported version of «{type}»."),
    "bad_wire": ("error", "Провод {wire} ведёт в несуществующий узел или вывод: {why}.", "Wire {wire} is broken: {why}."),
    "exec_data_mismatch": ("error", "Нельзя соединить порядок выполнения с данными: {wire}.", "Execution and data pins cannot be connected: {wire}."),
    "multi_input": ("error", "В узел «{node}» на вход «{pin}» приходит больше одного провода.", "Input «{pin}» of node «{node}» has more than one wire."),
    "exec_fanout": ("error", "Из выхода «{pin}» узла «{node}» выходит больше одного провода порядка выполнения.",
                    "Execution output «{pin}» of node «{node}» has more than one wire."),
    "literal_only": ("error", "Вход «{pin}» узла «{node}» принимает только значение, а не провод.", "Input «{pin}» of node «{node}» takes a literal, not a wire."),
    "type_mismatch": ("error", "Этому входу нужен {need}, а подключено {got}. Вход «{pin}» узла «{node}», источник — «{src}».",
                      "This input needs {need_en}, but {got_en} is connected. Input «{pin}» of node «{node}», source «{src}»."),
    "missing_input": ("error", "У узла «{node}» не заполнен обязательный вход «{pin}».", "Node «{node}» has the required input «{pin}» empty."),
    "bad_literal": ("error", "У узла «{node}» вход «{pin}»: {why}.", "Node «{node}», input «{pin}»: {why}."),
    "out_of_range": ("error", "У узла «{node}» вход «{pin}»: значение вне допустимых границ ({lo}…{hi}).",
                     "Node «{node}», input «{pin}»: value out of range ({lo}…{hi})."),
    "bad_choice": ("error", "У узла «{node}» вход «{pin}»: допустимо только {choices}.", "Node «{node}», input «{pin}»: allowed values are {choices}."),
    "unknown_variable": ("error", "Узел «{node}»: переменная «{var}» не объявлена в команде.", "Node «{node}»: variable «{var}» is not declared."),
    "bad_variable": ("error", "Переменная «{var}»: {why}.", "Variable «{var}»: {why}."),
    "no_event": ("error", "В команде нет события: добавьте узел «Вручную» или другое событие.", "The command has no event node."),
    "exec_cycle": ("error", "Порядок выполнения замкнут в цикл через узел «{node}». Для повторов есть узел «Для каждого».",
                   "Execution order loops back through node «{node}». Use «For each» for repetition."),
    "data_cycle": ("error", "Данные ходят по кругу через узел «{node}».", "Data flows in a circle through node «{node}»."),
    "bad_restore": ("error", "У узла «{node}» неизвестный режим отката «{mode}».", "Node «{node}» has an unknown restore mode «{mode}»."),
    "restore_mode_unavailable": ("error", "У узла «{node}» откат по обратному событию («{mode}») пока недоступен: он появится вместе с триггерами.",
                                 "Node «{node}»: restore on the opposite event («{mode}») is not available yet."),
    "no_undo_support": ("error", "Узел «{node}» не умеет откатываться, а в свойствах указан откат «{mode}».", "Node «{node}» cannot be rolled back but restore «{mode}» is set."),
    "bad_on_error": ("error", "У узла «{node}» неизвестная реакция на ошибку «{mode}» (stop или continue).", "Node «{node}»: unknown on_error «{mode}» (stop or continue)."),
    "bad_policy": ("error", "Политика команды: {why}.", "Command policy: {why}."),
    "unreachable": ("warning", "Узел «{node}» недостижим: до него не доходит ни одно событие.", "Node «{node}» is unreachable."),
    "unused": ("warning", "Выход узла «{node}» нигде не используется.", "The output of node «{node}» is not used."),
    "no_undo": ("warning", "Узел «{node}» меняет состояние, но не откатывается при завершении.", "Node «{node}» changes state but is not rolled back."),
    "deferred_node": ("warning", "Узел «{node}» пока недоступен: его исполнитель появится на одном из следующих этапов.",
                      "Node «{node}» is not available yet."),
    "planned_node": ("error", "Узел «{node}» появится позже: его исполнитель ещё не написан, команда пока не запустится.",
                     "Node «{node}» will appear later: its executor is not written yet, so the command cannot run."),
    "break_outside_loop": ("error", "Узел «{node}» стоит вне цикла: «Прервать цикл» работает только внутри тела «Для каждого».",
                           "Node «{node}» is outside a loop: «Break loop» only works inside a «For each» body."),
    "var_not_number": ("error", "Узел «{node}»: переменная «{var}» не числовая, увеличивать можно только число.",
                       "Node «{node}»: variable «{var}» is not numeric; only numbers can be incremented."),
    "choice_no_options": ("error", "Узел «{node}»: для вопроса с выбором задайте варианты (список пуст).",
                          "Node «{node}»: a choice question needs options (the list is empty)."),
    "loop_no_delay": ("warning", "Цикл «{node}» повторяет действия {count} без паузы: добавьте «Задержку» или «Спросить меня» в тело, либо ограничьте список.",
                      "Loop «{node}» repeats actions {count} without a pause: add a «Delay» or «Ask me» to the body or limit the list."),
    "wait_too_long": ("warning", "Узел «{node}» ждёт {wait} с, а вся команда ограничена {limit} с: запуск оборвётся раньше. Увеличьте policy.timeout_s.",
                      "Node «{node}» waits {wait} s but the whole command is limited to {limit} s: the run would be cut off. Raise policy.timeout_s."),
    "fn_cycle": ("error", "Узел «{node}» вызывает функцию по кругу: {path}. Функция не может вызывать саму себя, даже через другие.",
                 "Node «{node}» calls functions in a circle: {path}. A function cannot call itself, even through others."),
    "fn_depth": ("error", "Узел «{node}»: функции вложены слишком глубоко ({depth} уровней, не больше %d)." % MAX_FN_DEPTH,
                 "Node «{node}»: functions are nested too deeply ({depth} levels, at most %d)." % MAX_FN_DEPTH),
    "fn_invalid": ("error", "Функция «{fn}» в узле «{node}» содержит ошибку: {why}", "Function «{fn}» in node «{node}» has an error: {why}"),
    "fn_interface": ("error", "Функция: {why}.", "Function: {why}."),
    "fn_event_node": ("error", "В функции нельзя использовать событие «{node}»: функцию запускает вызывающая команда.",
                      "An event node «{node}» cannot be used inside a function."),
    "fn_impure": ("error", "Функция без порядка выполнения не может содержать «{node}»: он что-то делает. Добавьте функции вход и выход порядка выполнения.",
                  "A function without execution pins cannot contain «{node}», which acts: give the function execution pins."),
    "danger_confirm": ("warning", "Узел «{node}» опасный: при каждом запуске потребуется подтверждение.", "Node «{node}» is dangerous: every run needs confirmation."),
}
RESTORE_MODES = ("off", "end", "off_event")


class Graph:
    """Normalised view of a command; tolerant of broken wires (they are reported by validate, skipped here)."""

    def __init__(self, cmd, sch):
        self.cmd = cmd
        self.sch = sch
        self.nodes, self.defs = {}, {}
        for n in cmd.get("nodes") or []:
            nid = n.get("id") if isinstance(n, dict) else None
            if nid is None or nid in self.nodes:
                continue
            self.nodes[nid] = n
            nd, _ = sch.get(n.get("type", ""))
            if nd:
                self.defs[nid] = nd
        self.vars = {v.get("name"): v for v in cmd.get("variables") or [] if isinstance(v, dict)}
        self.wires = []                # (src, sp, dst, dp) with both ends resolved
        self.in_wire, self.exec_out = {}, {}
        for w in cmd.get("wires") or []:
            ends = _ends(w)
            if not ends:
                continue
            sn, sp, dn, dp = ends
            if sn in self.defs and dn in self.defs and self.defs[sn].pin(sp, "out") and self.defs[dn].pin(dp, "in"):
                self.wires.append(ends)
                if self.defs[sn].pin(sp, "out").type == "exec":
                    self.exec_out.setdefault((sn, sp), (dn, dp))
                else:
                    self.in_wire.setdefault((dn, dp), (sn, sp))
        self.bind = {nid: {} for nid in self.defs}
        self._resolve_generics()

    def prop(self, nid, key):
        return (self.nodes[nid].get("props") or {}).get(key)

    def var_type(self, nid, pin):
        """Type of a variable-typed pin (set/get variable) or None when it is not variable-typed."""
        nd = self.defs[nid]
        for p in nd.inputs + nd.outputs:
            if p.id == pin and p.var_typed:
                v = self.vars.get(self.prop(nid, p.var_typed))
                return v.get("type") if v else "any"
        return None

    def pin_type(self, nid, pin, direction):
        nd = self.defs[nid]
        p = nd.pin(pin, direction)
        vt = self.var_type(nid, pin)
        if vt is not None:
            return vt
        t = T.substitute(p.type, self.bind[nid])
        for g in nd.generics:
            t = t.replace(g, "any")
        return t

    def _resolve_generics(self):
        for nid, nd in self.defs.items():           # literals bind generics too: a list of texts makes T = text
            props = self.nodes[nid].get("props") or {}
            for pin in nd.inputs:
                if nd.generics and pin.id in props and (nid, pin.id) not in self.in_wire and pin.type != "exec":
                    lit = T.infer_literal(props[pin.id])
                    if lit:
                        T.unify(pin.type, lit, self.bind[nid], nd.generics)
        for _ in range(len(self.defs) + 2):
            changed = False
            for sn, sp, dn, dp in self.wires:
                nd = self.defs[dn]
                pin = nd.pin(dp, "in")
                if nd.generics and any(g in pin.type for g in nd.generics) and pin.type != "exec":
                    before = dict(self.bind[dn])
                    T.unify(pin.type, self.pin_type(sn, sp, "out"), self.bind[dn], nd.generics)
                    changed = changed or before != self.bind[dn]
            if not changed:
                break


def _ends(w):
    try:
        (sn, sp), (dn, dp) = w["from"], w["to"]
        return sn, sp, dn, dp
    except (KeyError, TypeError, ValueError):
        return None


def _wire_name(w):
    e = _ends(w)
    return "%s.%s → %s.%s" % e if e else str(w)


def _label(g, nid):
    nd = g.defs.get(nid)
    return nd.label("ru") if nd else str(nid)


class Report:
    def __init__(self):
        self.errors, self.warnings, self.capabilities = [], [], []

    def add(self, code, node=None, pin=None, fix=None, nid=None, **kw):
        """`node` is the label shown in messages, `nid` the node id the editor uses to find the node."""
        level, ru, en = MSG[code]
        kw["node"] = node
        kw.setdefault("pin", pin)
        issue = {"code": code, "level": level, "node": nid if nid is not None else node, "pin": pin,
                 "message": ru.format(**kw), "message_en": en.format(**({k: "" for k in _fields(en)} | kw))}
        if fix:
            issue["fix"] = fix
        (self.errors if level == "error" else self.warnings).append(issue)

    def result(self):
        return {"ok": not self.errors, "errors": self.errors, "warnings": self.warnings, "capabilities": self.capabilities}


def _fields(tpl):
    import string
    return {f[1] for f in string.Formatter().parse(tpl) if f[1]}


def _find_fix(g, src_t, dst_t, wire):
    cands = sorted(g.sch.converters(), key=lambda c: (c.converter["from"] != src_t, c.id))
    for c in cands:
        if T.compatible(src_t, c.converter["from"]) and T.compatible(c.converter["to"], dst_t):
            return {"kind": "insert_converter", "node_type": c.type_string, "wire": list(wire),
                    "label": "Вставить «%s»" % c.label("ru"), "label_en": "Insert «%s»" % c.label("en")}
    return None


def _fn_report(sch, fid):
    """Memoised validation of a library function (nested calls are checked through their call sites)."""
    base = sch._base
    if fid not in base._rep:
        base._rep[fid] = {"ok": True, "errors": []}          # guards against recursion; cycles are reported separately
        base._rep[fid] = validate_function(base.functions[fid], base)
    return base._rep[fid]


PIN_ID = re.compile(r"^[a-z][a-z0-9_]{0,31}$")


def _fn_interface(rep, fn):
    if not isinstance(fn.get("nodes"), list) or not isinstance(fn.get("wires", []), list):
        rep.add("fn_interface", why="нужны списки nodes и wires")
    if not str(fn.get("name", "")).strip():
        rep.add("fn_interface", why="у функции нет названия")
    for key, ru in (("inputs", "вход"), ("outputs", "выход")):
        seen = set()
        for p in fn.get(key) or []:
            pid = p.get("id") if isinstance(p, dict) else None
            if not isinstance(pid, str) or not PIN_ID.match(pid) or pid in ("exec", "exec_in", "exec_out"):
                rep.add("fn_interface", why="%s «%s»: недопустимый идентификатор" % (ru, pid))
                continue
            if pid in seen:
                rep.add("fn_interface", why="%s «%s» объявлен дважды" % (ru, pid))
            seen.add(pid)
            if not T.valid_type(p.get("type", ""), ()) or p.get("type") == "exec":
                rep.add("fn_interface", why="%s «%s»: неизвестный тип «%s»" % (ru, pid, p.get("type")))
            elif "default" in p and T.check_literal(p["type"], p["default"]):
                rep.add("fn_interface", why="%s «%s»: значение по умолчанию — %s" % (ru, pid, T.check_literal(p["type"], p["default"])))


def validate_function(fn, sch):
    """Validate a function graph: the same checks as for a command plus the interface rules."""
    if not isinstance(fn, dict):
        rep = Report()
        rep.add("fn_interface", why="это не объект")
        return rep.result()
    inner = {"nodes": fn.get("nodes"), "wires": fn.get("wires", []), "variables": fn.get("variables", []), "policy": {}}
    return validate(inner, sch, fn=fn)


def validate(cmd, sch, fn=None):
    rep = Report()
    sch = sch.for_function(fn) if fn is not None else sch.with_functions(cmd.get("functions") if isinstance(cmd, dict) else None)
    if fn is not None:
        _fn_interface(rep, fn)
    if not isinstance(cmd, dict):
        rep.add("bad_command", why="это не объект")
        return rep.result()
    if not isinstance(cmd.get("nodes"), list) or not isinstance(cmd.get("wires", []), list):
        rep.add("bad_command", why="нужны списки nodes и wires")
        return rep.result()

    # ---- policy and variables
    pol = policy_of(cmd)
    if pol["reentrancy"] not in ("skip", "queue", "restart", "parallel"):
        rep.add("bad_policy", why="reentrancy: skip, queue, restart или parallel")
    for key in ("max_runs_per_min", "timeout_s"):
        if not isinstance(pol[key], (int, float)) or isinstance(pol[key], bool) or pol[key] <= 0:
            rep.add("bad_policy", why="%s должно быть положительным числом" % key)
    seen_vars = set()
    for v in cmd.get("variables") or []:
        name = v.get("name") if isinstance(v, dict) else None
        if not name or name in seen_vars:
            rep.add("bad_variable", var=name, why="пустое или повторяющееся имя")
            continue
        seen_vars.add(name)
        if not T.valid_type(v.get("type", ""), ()) or v.get("type") == "exec":
            rep.add("bad_variable", var=name, why="неизвестный тип «%s»" % v.get("type"))
        elif v.get("scope", "run") not in ("run", "persist"):
            rep.add("bad_variable", var=name, why="область видимости: run или persist")
        elif fn is not None and v.get("scope", "run") != "run":
            rep.add("bad_variable", var=name, why="в функции переменные только на время вызова (run)")
        elif "initial" in v and T.check_literal(v["type"], v["initial"]):
            rep.add("bad_variable", var=name, why="начальное значение: " + T.check_literal(v["type"], v["initial"]))

    # ---- nodes
    ids = set()
    for n in cmd["nodes"]:
        nid = n.get("id") if isinstance(n, dict) else None
        if nid is None:
            rep.add("bad_command", why="узел без id")
        elif nid in ids:
            rep.add("duplicate_node", node=nid)
        ids.add(nid)
    g = Graph(cmd, sch)
    for nid, n in g.nodes.items():
        if nid not in g.defs:
            _, why = sch.get(n.get("type", ""))
            rep.add("node_version" if why == "version" else "unknown_node", node=nid, type=n.get("type"))

    # ---- wires
    for w in cmd.get("wires") or []:
        e = _ends(w)
        if not e:
            rep.add("bad_wire", wire=_wire_name(w), why="нужны поля from и to вида [узел, вывод]")
            continue
        sn, sp, dn, dp = e
        bad = None
        for nid in (sn, dn):
            if nid not in g.nodes:
                bad = "узла «%s» нет" % nid
        if bad is None and sn in g.defs and not g.defs[sn].pin(sp, "out"):
            bad = "у узла «%s» нет выхода «%s»" % (_label(g, sn), sp)
        if bad is None and dn in g.defs and not g.defs[dn].pin(dp, "in"):
            bad = "у узла «%s» нет входа «%s»" % (_label(g, dn), dp)
        if bad:
            if sn in g.defs or dn in g.defs or sn not in g.nodes or dn not in g.nodes:
                rep.add("bad_wire", wire=_wire_name(w), why=bad)
            continue
        if sn not in g.defs or dn not in g.defs:
            continue
        st, dt = g.defs[sn].pin(sp, "out").type, g.defs[dn].pin(dp, "in").type
        if (st == "exec") != (dt == "exec"):
            rep.add("exec_data_mismatch", node=dn, pin=dp, wire=_wire_name(w))

    counts_in, counts_exec = {}, {}
    for w in cmd.get("wires") or []:
        e = _ends(w)
        if not e or e[0] not in g.defs or e[2] not in g.defs:
            continue
        sn, sp, dn, dp = e
        sd, dd = g.defs[sn].pin(sp, "out"), g.defs[dn].pin(dp, "in")
        if not sd or not dd:
            continue
        if sd.type == "exec" and dd.type == "exec":
            counts_exec[(sn, sp)] = counts_exec.get((sn, sp), 0) + 1
        elif sd.type != "exec" and dd.type != "exec":
            counts_in[(dn, dp)] = counts_in.get((dn, dp), 0) + 1
            if dd.literal:
                rep.add("literal_only", node=_label(g, dn), nid=dn, pin=dp)
    for (dn, dp), c in counts_in.items():
        if c > 1:
            rep.add("multi_input", node=_label(g, dn), nid=dn, pin=dp)
    for (sn, sp), c in counts_exec.items():
        if c > 1:
            rep.add("exec_fanout", node=_label(g, sn), nid=sn, pin=sp)

    # ---- per node: variables, literals, required inputs, restore/on_error
    for nid, nd in g.defs.items():
        node = g.nodes[nid]
        props = node.get("props") or {}
        lbl = nd.label("ru")
        for pin in nd.inputs + nd.outputs:
            if pin.var_typed:
                vname = props.get(pin.var_typed)
                if vname is not None and vname not in g.vars:
                    rep.add("unknown_variable", node=lbl, nid=nid, var=vname)
        for pin in nd.inputs:
            if pin.type == "exec":
                continue
            has_wire = (nid, pin.id) in g.in_wire
            if pin.id in props:
                ptype = g.pin_type(nid, pin.id, "in")
                err = T.check_literal(ptype, props[pin.id])
                if err:
                    rep.add("bad_literal", node=lbl, nid=nid, pin=pin.id, why=err)
                elif pin.choices is not None and props[pin.id] not in pin.choices:
                    rep.add("bad_choice", node=lbl, nid=nid, pin=pin.id, choices=", ".join(map(str, pin.choices)))
                elif isinstance(props[pin.id], (int, float)) and not isinstance(props[pin.id], bool) and (
                        (pin.min is not None and props[pin.id] < pin.min) or (pin.max is not None and props[pin.id] > pin.max)):
                    rep.add("out_of_range", node=lbl, nid=nid, pin=pin.id, lo=pin.min, hi=pin.max)
            elif not has_wire and not pin.has_default and pin.required:
                rep.add("missing_input", node=lbl, nid=nid, pin=pin.id)
        mode = props.get("restore")
        if mode is not None or nd.undo:
            mode = mode if mode is not None else (nd.undo or {}).get("default", "off")
            if mode not in RESTORE_MODES:
                rep.add("bad_restore", node=lbl, nid=nid, mode=mode)
            elif mode == "off_event":
                rep.add("restore_mode_unavailable", node=lbl, nid=nid, mode=mode)
            elif mode != "off" and not nd.undo:
                rep.add("no_undo_support", node=lbl, nid=nid, mode=mode)
        if props.get("on_error", "stop") not in ("stop", "continue"):
            rep.add("bad_on_error", node=lbl, nid=nid, mode=props.get("on_error"))
        if nd.changes_state and not nd.undo:
            rep.add("no_undo", node=lbl, nid=nid)
        if nd.planned:
            rep.add("planned_node", node=lbl, nid=nid)
        elif nd.stage == "deferred":
            rep.add("deferred_node", node=lbl, nid=nid)
        if nd.danger == "confirm":
            rep.add("danger_confirm", node=lbl, nid=nid)

    # ---- functions: call sites (cycles, depth, a broken function) and the rules inside a function graph
    for nid, nd in g.defs.items():
        if nd.executor.get("kind") != "function":
            continue
        fid = nd.executor["ref"]
        prob = sch.call_problem(fid)
        if prob and prob[0] == "cycle":
            rep.add("fn_cycle", node=_label(g, nid), nid=nid, path=" → ".join("«%s»" % x for x in prob[1]))
        elif prob:
            rep.add("fn_depth", node=_label(g, nid), nid=nid, depth=prob[1])
        else:
            sub = _fn_report(sch, fid)
            if not sub["ok"]:
                rep.add("fn_invalid", node=_label(g, nid), nid=nid, fn=_label(g, nid), why=sub["errors"][0]["message"])
    if fn is not None:
        for kind, ru in ((FN_INPUT, "Вход функции"), (FN_OUTPUT, "Выход функции")):
            n = [nid for nid, nd in g.defs.items() if nd.id == kind]
            if len(n) != 1:
                rep.add("fn_interface", why="должен быть ровно один узел «%s» (сейчас %d)" % (ru, len(n)))
        for nid, nd in g.defs.items():
            if nd.flow == "event" and nd.id != FN_INPUT:
                rep.add("fn_event_node", node=_label(g, nid), nid=nid)
            elif not fn.get("exec") and nd.flow in ("action", "latent"):
                rep.add("fn_impure", node=_label(g, nid), nid=nid)

    # ---- types on data wires
    for sn, sp, dn, dp in g.wires:
        if "exec" in (g.defs[sn].pin(sp, "out").type, g.defs[dn].pin(dp, "in").type):
            continue
        st, dt = g.pin_type(sn, sp, "out"), g.pin_type(dn, dp, "in")
        if not T.compatible(st, dt):
            fix = _find_fix(g, st, dt, (sn, sp, dn, dp))
            rep.add("type_mismatch", node=_label(g, dn), nid=dn, pin=dp, src=_label(g, sn), need=T.type_name(dt),
                    got=T.type_name(st), need_en=T.type_name(dt, "en"), got_en=T.type_name(st, "en"), fix=fix)

    # ---- exec graph: event present, cycles, reachability
    events = [nid for nid, nd in g.defs.items() if nd.flow == "event"]
    if not events and fn is None:
        rep.add("no_event")
    adj = {}
    for (sn, _sp), (dn, _dp) in g.exec_out.items():
        adj.setdefault(sn, set()).add(dn)
    _cycle(rep, g, adj, "exec_cycle")
    dadj = {}
    for sn, _sp, dn, _dp in g.wires:
        if g.defs[sn].pin(_sp, "out").type != "exec":
            dadj.setdefault(sn, set()).add(dn)
    _cycle(rep, g, dadj, "data_cycle")
    reach, stack = set(), list(events)
    while stack:
        cur = stack.pop()
        if cur in reach:
            continue
        reach.add(cur)
        stack.extend(adj.get(cur, ()))
    for nid, nd in g.defs.items():
        if nd.flow in ("action", "latent") and nid not in reach:
            rep.add("unreachable", node=_label(g, nid), nid=nid)
        elif nd.flow == "pure" and not dadj.get(nid) and nd.id not in (FN_INPUT, FN_OUTPUT):
            rep.add("unused", node=_label(g, nid), nid=nid)

    _logic_checks(rep, g, adj, pol)
    rep.capabilities = compute_capabilities(cmd, sch)
    return rep.result()


WAITING = ("logic.delay", "logic.ask", "logic.wait_event")


def _reach(adj, start):
    seen, stack = set(), list(start)
    while stack:
        cur = stack.pop()
        if cur not in seen:
            seen.add(cur)
            stack.extend(adj.get(cur, ()))
    return seen


def _loop_size(g, fid):
    """How many iterations a for-each will make, or None when that is unknown until it runs."""
    props = g.nodes[fid].get("props") or {}
    w = g.in_wire.get((fid, "list"))
    if w is None:
        lst = props.get("list")
        return len(lst) if isinstance(lst, list) else 0
    sn = w[0]
    if g.defs[sn].id == "data.range":
        if (sn, "count") in g.in_wire:
            return None
        c = g.prop(sn, "count")
        return c if isinstance(c, int) and not isinstance(c, bool) else 3
    return None


def _logic_checks(rep, g, adj, pol):
    """Loops, breaks, increments, ask options and waits that outlive the run timeout."""
    in_body = set()
    for nid, nd in g.defs.items():
        if nd.id != "logic.foreach":
            continue
        tgt = g.exec_out.get((nid, "body"))
        body = _reach(adj, [tgt[0]]) if tgt else set()
        in_body |= body
        size = _loop_size(g, nid)
        if body and (size is None or size > 50) and not any(g.defs[b].id in WAITING for b in body) and any(
                g.defs[b].side_effects and g.defs[b].category not in ("logic",) for b in body):
            rep.add("loop_no_delay", node=_label(g, nid), nid=nid, count="много раз" if size is None else "%d раз" % size)
    for nid, nd in g.defs.items():
        props = g.nodes[nid].get("props") or {}
        lbl = nd.label("ru")
        if nd.id == "logic.break" and nid not in in_body:
            rep.add("break_outside_loop", node=lbl, nid=nid)
        elif nd.id == "logic.increment":
            v = g.vars.get(props.get("name"))
            if v is not None and v.get("type") not in ("int", "float"):
                rep.add("var_not_number", node=lbl, nid=nid, var=props.get("name"))
        elif nd.id == "logic.ask":
            if props.get("mode", "choice") == "choice" and (nid, "options") not in g.in_wire and not props.get("options"):
                rep.add("choice_no_options", node=lbl, nid=nid)
        if nd.id == "action.timer" and (nid, "seconds") not in g.in_wire:
            wait = props.get("seconds", 60)
            if isinstance(wait, (int, float)) and wait > pol["timeout_s"]:
                rep.add("wait_too_long", node=lbl, nid=nid, wait=wait, limit=pol["timeout_s"])
        if nd.id in ("logic.ask", "logic.wait_event") and (nid, "timeout") not in g.in_wire:
            wait = props.get("timeout", 120 if nd.id == "logic.ask" else 60)
            if isinstance(wait, (int, float)) and wait > pol["timeout_s"]:
                rep.add("wait_too_long", node=lbl, nid=nid, wait=wait, limit=pol["timeout_s"])


def _cycle(rep, g, adj, code):
    color = {}

    def visit(n):
        color[n] = 1
        for m in sorted(adj.get(n, ())):
            if color.get(m) == 1:
                rep.add(code, node=_label(g, m), nid=m)
                return True
            if color.get(m) is None and visit(m):
                return True
        color[n] = 2
        return False

    for n in sorted(adj):
        if color.get(n) is None and visit(n):
            return
