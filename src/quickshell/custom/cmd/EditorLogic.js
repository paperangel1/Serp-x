.pragma library

// Pure editing logic of the Commands editor (no QML types, so it is testable with plain `qml6` and has no
// dependency on the shell). The canonical document is the command JSON (design §2); `buildView` turns it into the
// geometry the canvas draws, replicating src/scripts/custom/cmd/xcmd/uiview.py (build_nodes / node_width / bounds):
// a parity test (tests/cmd_ui/editor_logic_test.qml) compares both implementations on the example commands.
// Validation stays in the engine (single source of truth); `canConnect` only gives instant feedback while wiring.

var HDR = 32, ROW = 26, PAD_TOP = 6, FOOT = 12, NOTE_H = 20;
var W_MIN = 230, W_MAX = 340, CHAR_TITLE = 7.4, CHAR_ROW = 6.7;
var GRID = 10;
var UNDO_NOTE = { ru: "откат по завершении", en: "restored when it ends" };
var FN_NOTE = { ru: "функция · %1 узл. внутри · открыть ↗", en: "function · %1 nodes inside · open ↗" };
var FN_IN = "fn_in", FN_OUT = "fn_out", FN_INPUT_TYPE = "function.input@1", FN_OUTPUT_TYPE = "function.output@1";

function clone(o) { return JSON.parse(JSON.stringify(o)); }
function snap(v) { return Math.round(v / GRID) * GRID; }

// ---- catalogue -----------------------------------------------------------------------------------------------------
function indexCatalog(catalog) {
    var idx = {};
    for (var i = 0; i < catalog.length; i++) idx[catalog[i].type] = catalog[i];
    return idx;
}
function pinOf(entry, id, isInput) {
    var list = isInput ? entry.ins : entry.outs;
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
    return null;
}

// ---- types (mirror of ptypes.py) ---------------------------------------------------------------------------------
var NAMES_RU = { exec: "порядок выполнения", bool: "да/нет", int: "число", float: "дробное число", text: "текст", color: "цвет",
                 time: "время", duration: "длительность", path: "путь", url: "ссылка", device: "устройство", json: "данные",
                 any: "любое значение", list: "список" };
var NAMES_EN = { exec: "execution", bool: "yes/no", int: "number", float: "decimal number", text: "text", color: "color",
                 time: "time", duration: "duration", path: "path", url: "link", device: "device", json: "data",
                 any: "any value", list: "list" };
function listInner(t) { var m = /^list<(.+)>$/.exec(t); return m ? m[1] : null; }
function typeName(t, lang) {
    var names = lang === "en" ? NAMES_EN : NAMES_RU, inner = listInner(t);
    if (inner !== null) return (lang === "en" ? "list (%1)" : "список (%1)").replace("%1", typeName(inner, lang));
    return names[t] || t;
}
function baseType(t, generics) {
    if (generics && generics.indexOf(t) >= 0) return "any";
    return listInner(t) !== null ? "list" : t;
}
// A generic parameter (T) of the node is a wildcard: the engine resolves it, the editor must not reject it.
function wild(t, generics) {
    if (!generics || generics.length === 0) return t;
    if (generics.indexOf(t) >= 0) return "any!";
    var inner = listInner(t);
    return inner !== null ? "list<" + wild(inner, generics) + ">" : t;
}
function compatible(src, dst) {
    if (src === "any!" || dst === "any!") return true;
    if (src === "exec" || dst === "exec") return src === dst;
    if (src === dst || dst === "any") return true;
    if (src === "int" && dst === "float") return true;
    var ls = listInner(src), ld = listInner(dst);
    if (ls !== null && ld !== null) return ld === "any" || ls === "any!" || ld === "any!" || ls === ld;
    return false;
}

// ---- view construction (parity with uiview.py) ---------------------------------------------------------------------
function fmtValue(v, lang) {
    if (v === null || v === undefined) return null;
    if (typeof v === "boolean") return lang === "en" ? (v ? "yes" : "no") : (v ? "да" : "нет");
    if (Array.isArray(v)) return (lang === "en" ? "list (%1)" : "список (%1)").replace("%1", v.length);
    if (typeof v === "object") return lang === "en" ? "data" : "данные";
    var s = String(v);
    if (s === "") return null;
    return s.length <= 18 ? s : s.slice(0, 17) + "…";
}
function hasKey(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

function pinRow(pin, props, linked, lang, isInput, generics) {
    var row = { id: pin.id, n: pin.n, t: baseType(pin.full, generics), full: pin.full, linked: linked, required: !!pin.required };
    if (isInput && pin.full !== "exec" && !linked) {
        var val = null;
        if (hasKey(props, pin.id)) val = props[pin.id];
        else if (hasKey(pin, "default")) val = pin.default;
        var shown = fmtValue(val, lang);
        if (shown !== null && typeof val === "string" && pin.choice_labels && hasKey(pin.choice_labels, val)) shown = pin.choice_labels[val];
        if (shown !== null) row.v = shown;
        else if (pin.required) row.missing = true;
    }
    return row;
}
function nodeNote(entry, props, lang) {
    if (entry["function"]) return FN_NOTE[lang].replace("%1", entry["function"].nodes);
    if (entry.undo) {
        var mode = hasKey(props, "restore") ? props.restore : (entry.undo["default"] !== undefined ? entry.undo["default"] : "end");
        if (mode !== "never" && mode !== "off") return UNDO_NOTE[lang];
    }
    return "";
}
function nodeHeight(nIn, nOut, note) { return HDR + PAD_TOP + Math.max(nIn, nOut) * ROW + FOOT + (note ? NOTE_H : 0); }
function nodeWidth(b) {
    var w = 36 + b.title.length * CHAR_TITLE + 30;
    var rows = Math.max(b.ins.length, b.outs.length);
    for (var i = 0; i < rows; i++) {
        var left = 0, right = 0;
        if (i < b.ins.length) {
            var p = b.ins[i];
            left = 14 + p.n.length * CHAR_ROW + (p.v ? (8 + Math.max(34, p.v.length * CHAR_ROW + 14)) : 0);
        }
        if (i < b.outs.length) right = b.outs[i].n.length * CHAR_ROW + 16;
        w = Math.max(w, left + right + 36);
    }
    if (b.note) w = Math.max(w, 28 + b.note.length * 6.2 + 14);
    return Math.floor(Math.min(W_MAX, Math.max(W_MIN, Math.ceil(w / 10) * 10)));
}

// issues: {nodes: {id: {errors: n, warnings: n}}, pins: {"id:pin": message}} (see indexIssues)
// gallery files carry {ru, en} strings in comments; a user command carries plain strings
function loc(v, lang) { return (v && typeof v === "object") ? (v[lang] || v.ru || "") : (v || ""); }
function buildView(cmd, catalog, lang, issues) {
    var wires = cmd.wires || [], lin = {}, lout = {}, i, j;
    for (i = 0; i < wires.length; i++) {
        lout[wires[i].from[0] + ":" + wires[i].from[1]] = true;
        lin[wires[i].to[0] + ":" + wires[i].to[1]] = true;
    }
    var nodes = [], byId = {};
    var nl = cmd.nodes || [];
    for (i = 0; i < nl.length; i++) {
        var n = nl[i], entry = catalog[n.type] || null, props = n.props || {};
        var hasPos = Array.isArray(n.pos) && n.pos.length === 2;
        var base = { id: n.id, type: n.type || "", w: 290, has_pos: hasPos, x: hasPos ? Number(n.pos[0]) : 40 + (i % 4) * 330, y: hasPos ? Number(n.pos[1]) : 40 + Math.floor(i / 4) * 200 };
        if (entry === null) {
            var ins = {}, outs = {}, ia = [], oa = [];
            for (j = 0; j < wires.length; j++) {
                if (wires[j].to[0] === n.id) ins[wires[j].to[1]] = true;
                if (wires[j].from[0] === n.id) outs[wires[j].from[1]] = true;
            }
            Object.keys(ins).sort().forEach(function (k) { ia.push({ id: k, n: k, t: "any", full: "any", linked: true }); });
            Object.keys(outs).sort().forEach(function (k) { oa.push({ id: k, n: k, t: "any", full: "any", linked: true }); });
            base.title = n.type || "?"; base.icon = "unknown"; base.cat = "unknown"; base.unknown = true; base.note = "";
            base.ins = ia; base.outs = oa;
        } else {
            var g = entry.generics;
            base.title = entry.title; base.icon = entry.icon; base.cat = entry.category; base.unknown = false;
            base.note = nodeNote(entry, props, lang); base.deferred = !!entry.deferred;
            base.ins = entry.ins.map(function (p) { return pinRow(p, props, !!lin[n.id + ":" + p.id], lang, true, g); });
            base.outs = entry.outs.map(function (p) { return pinRow(p, props, !!lout[n.id + ":" + p.id], lang, false, g); });
        }
        base.h = nodeHeight(base.ins.length, base.outs.length, !!base.note);
        base.w = nodeWidth(base);
        if (issues) {
            var ni = issues.nodes[n.id];
            if (ni) { base.err = ni.errors; base.warn = ni.warnings; }
            for (j = 0; j < base.ins.length; j++) {
                var msg = issues.pins[n.id + ":" + base.ins[j].id];
                if (msg) { base.ins[j].bad = true; base.ins[j].issue = msg; }
            }
        }
        nodes.push(base);
        byId[n.id] = base;
    }
    var wl = [];
    for (i = 0; i < wires.length; i++) {
        var w = wires[i], A = byId[w.from[0]], B = byId[w.to[0]], pin = null;
        if (A) for (j = 0; j < A.outs.length; j++) if (A.outs[j].id === w.from[1]) pin = A.outs[j];
        wl.push({ from: w.from, to: w.to, t: pin ? pin.t : "any", ok: !!(A && B && pin) });
    }
    var comments = [], cl = cmd.comments || [];
    for (i = 0; i < cl.length; i++) {
        var c = cl[i];
        comments.push({ id: c.id || "c" + (i + 1), x: Number(c.x || 0), y: Number(c.y || 0), w: Number(c.w || 300), h: Number(c.h || 110),
                        title: loc(c.title, lang), text: loc(c.text, lang), color: c.color || "" });
    }
    return { nodes: nodes, wires: wl, comments: comments, bounds: bounds(nodes, comments) };
}
function bounds(nodes, comments) {
    if (nodes.length + comments.length === 0) return { x: 0, y: 0, w: 0, h: 0 };
    var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, i;
    for (i = 0; i < nodes.length; i++) { x0 = Math.min(x0, nodes[i].x); y0 = Math.min(y0, nodes[i].y); x1 = Math.max(x1, nodes[i].x + nodes[i].w); y1 = Math.max(y1, nodes[i].y + nodes[i].h); }
    for (i = 0; i < comments.length; i++) { x0 = Math.min(x0, comments[i].x); y0 = Math.min(y0, comments[i].y); x1 = Math.max(x1, comments[i].x + comments[i].w); y1 = Math.max(y1, comments[i].y + comments[i].h); }
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

// Validation report of the engine -> lookup tables for the canvas.
function indexIssues(report) {
    var out = { nodes: {}, pins: {}, list: [] };
    if (!report) return out;
    var all = (report.errors || []).concat(report.warnings || []);
    for (var i = 0; i < all.length; i++) {
        var it = all[i], isErr = it.level === "error";
        out.list.push(it);
        if (it.node) {
            var e = out.nodes[it.node] || (out.nodes[it.node] = { errors: 0, warnings: 0 });
            if (isErr) e.errors++; else e.warnings++;
        }
        if (it.node && it.pin && isErr) out.pins[it.node + ":" + it.pin] = it;
    }
    return out;
}

// ---- ids / lookups -----------------------------------------------------------------------------------------------
function findNode(cmd, id) { var nl = cmd.nodes || []; for (var i = 0; i < nl.length; i++) if (nl[i].id === id) return nl[i]; return null; }
function newId(list, prefix) {
    var max = 0;
    for (var i = 0; i < list.length; i++) {
        var m = new RegExp("^" + prefix + "(\\d+)$").exec(list[i].id || "");
        if (m) max = Math.max(max, parseInt(m[1], 10));
    }
    return prefix + (max + 1);
}
function wireKey(w) { return w.from[0] + ":" + w.from[1] + ">" + w.to[0] + ":" + w.to[1]; }

// ---- instant wiring feedback ---------------------------------------------------------------------------------------
// from = [nodeId, outPin], to = [nodeId, inPin] -> { ok, reason, code, fix }. reason is Russian (the shell UI language).
function pinTypeFor(cmd, catalog, nodeId, pinId, isInput) {
    var n = findNode(cmd, nodeId), e = n ? catalog[n.type] : null;
    if (!e) return null;
    var p = pinOf(e, pinId, isInput);
    if (!p) return null;
    if (p.type_from_var) return "any!";
    return wild(p.full, e.generics);
}
function reaches(cmd, catalog, startNode, targetNode, execOnly) {
    // is there a path startNode -> ... -> targetNode over wires of the given kind
    var adj = {}, wl = cmd.wires || [], i;
    for (i = 0; i < wl.length; i++) {
        var a = wl[i].from[0], isExec = pinTypeFor(cmd, catalog, a, wl[i].from[1], false) === "exec";
        if (isExec !== execOnly) continue;
        (adj[a] = adj[a] || []).push(wl[i].to[0]);
    }
    var seen = {}, stack = [startNode];
    while (stack.length) {
        var cur = stack.pop();
        if (cur === targetNode) return true;
        if (seen[cur]) continue;
        seen[cur] = true;
        (adj[cur] || []).forEach(function (m) { stack.push(m); });
    }
    return false;
}
function findConverter(catalog, srcT, dstT) {
    var list = [];
    Object.keys(catalog).forEach(function (k) { if (catalog[k].converter) list.push(catalog[k]); });
    list.sort(function (a, b) { return a.id < b.id ? -1 : 1; });
    for (var i = 0; i < list.length; i++) {
        var c = list[i].converter;
        if (compatible(srcT, c.from) && compatible(c.to, dstT)) return list[i];
    }
    return null;
}
function canConnect(cmd, catalog, from, to) {
    var na = findNode(cmd, from[0]), nb = findNode(cmd, to[0]);
    if (!na || !nb) return { ok: false, code: "missing", reason: "Нет такого узла" };
    if (from[0] === to[0]) return { ok: false, code: "self", reason: "Нельзя соединить узел с самим собой" };
    var ea = catalog[na.type], eb = catalog[nb.type];
    if (!ea || !eb) return { ok: false, code: "unknown", reason: "Узел неизвестного типа: его нельзя соединять" };
    var pa = pinOf(ea, from[1], false), pb = pinOf(eb, to[1], true);
    if (!pa || !pb) return { ok: false, code: "pin", reason: "Нет такого пина" };
    if (pb.literal) return { ok: false, code: "literal", reason: "Вход «" + pb.n + "» принимает только значение, а не провод" };
    var st = pinTypeFor(cmd, catalog, from[0], from[1], false), dt = pinTypeFor(cmd, catalog, to[0], to[1], true);
    if ((st === "exec") !== (dt === "exec"))
        return { ok: false, code: "exec_data", reason: "Порядок выполнения соединяется только с порядком выполнения" };
    if (st === "exec") {
        if (reaches(cmd, catalog, to[0], from[0], true)) return { ok: false, code: "cycle", reason: "Порядок выполнения замкнётся в цикл. Для повторов есть узел «Для каждого»" };
        return { ok: true };
    }
    if (!compatible(st, dt)) {
        var conv = findConverter(catalog, st, dt);
        var msg = "Этому входу нужен " + typeName(dt, "ru") + ", а подключено " + typeName(st, "ru");
        return { ok: false, code: "type", reason: msg, fix: conv ? { kind: "insert_converter", node_type: conv.type, label: "Вставить «" + conv.title + "»" } : null };
    }
    if (reaches(cmd, catalog, to[0], from[0], false)) return { ok: false, code: "cycle", reason: "Данные пойдут по кругу" };
    return { ok: true };
}

// ---- edits (each returns a NEW command; the caller keeps the undo stack) --------------------------------------------
function addNode(cmd, entry, x, y) {
    var c = clone(cmd), id = newId(c.nodes, "n");
    c.nodes.push({ id: id, type: entry.type, pos: [snap(x), snap(y)], props: {} });
    return { cmd: c, id: id };
}
function moveItems(cmd, sel, dx, dy) {
    var c = clone(cmd), i;
    for (i = 0; i < c.nodes.length; i++) if (sel.nodes[c.nodes[i].id]) c.nodes[i].pos = [snap(c.nodes[i].pos[0] + dx), snap(c.nodes[i].pos[1] + dy)];
    var cm = c.comments || [];
    for (i = 0; i < cm.length; i++) if (sel.comments[cm[i].id || "c" + (i + 1)]) { cm[i].x = snap(cm[i].x + dx); cm[i].y = snap(cm[i].y + dy); }
    return c;
}
function removeWires(c, pred) { c.wires = (c.wires || []).filter(function (w) { return !pred(w); }); }
// Wires are replaced like in Unreal: one wire per data input, one wire per exec output.
function connect(cmd, catalog, from, to) {
    var c = clone(cmd);
    var isExec = pinTypeFor(c, catalog, from[0], from[1], false) === "exec";
    removeWires(c, function (w) {
        if (w.to[0] === to[0] && w.to[1] === to[1]) return true;
        return isExec && w.from[0] === from[0] && w.from[1] === from[1];
    });
    c.wires.push({ from: [from[0], from[1]], to: [to[0], to[1]] });
    var n = findNode(c, to[0]);                       // a wired input no longer carries a literal
    if (n && n.props && hasKey(n.props, to[1])) delete n.props[to[1]];
    return c;
}
function disconnect(cmd, key) { var c = clone(cmd); removeWires(c, function (w) { return wireKey(w) === key; }); return c; }
function isIface(n) { return n.type === FN_INPUT_TYPE || n.type === FN_OUTPUT_TYPE; }
function deleteItems(cmd, sel) {       // the interface nodes of a function graph cannot be deleted
    var c = clone(cmd), gone = {};
    c.nodes = c.nodes.filter(function (n) { if (sel.nodes[n.id] && !isIface(n)) { gone[n.id] = true; return false; } return true; });
    removeWires(c, function (w) { return gone[w.from[0]] || gone[w.to[0]] || sel.wires[wireKey(w)]; });
    c.comments = (c.comments || []).filter(function (cm, i) { return !sel.comments[cm.id || "c" + (i + 1)]; });
    return c;
}
function setProp(cmd, nodeId, pinId, value) {
    var c = clone(cmd), n = findNode(c, nodeId);
    if (!n) return c;
    n.props = n.props || {};
    if (value === undefined) delete n.props[pinId]; else n.props[pinId] = value;
    return c;
}
function addComment(cmd, x, y) {
    var c = clone(cmd);
    c.comments = c.comments || [];
    var id = newId(c.comments.map(function (cm, i) { return { id: cm.id || "c" + (i + 1) }; }), "c");
    c.comments.push({ id: id, x: snap(x), y: snap(y), w: 300, h: 120, title: "", text: "", color: "" });
    return { cmd: c, id: id };
}
function setComment(cmd, id, fields) {
    var c = clone(cmd), cl = c.comments || [];
    for (var i = 0; i < cl.length; i++) if ((cl[i].id || "c" + (i + 1)) === id) {
        for (var k in fields) cl[i][k] = fields[k];
        if (!cl[i].id) cl[i].id = id;
    }
    return c;
}
var COMMENT_COLORS = ["", "#f9e2af", "#a6e3a1", "#89b4fa", "#f38ba8", "#cba6f7"];
function nextCommentColor(cur) { var i = COMMENT_COLORS.indexOf(cur || ""); return COMMENT_COLORS[(i + 1) % COMMENT_COLORS.length]; }

function copySelection(cmd, sel) {
    var skip = {};
    (cmd.nodes || []).forEach(function (n) { if (isIface(n)) skip[n.id] = true; });
    var nodes = (cmd.nodes || []).filter(function (n) { return sel.nodes[n.id] && !skip[n.id]; }).map(clone);
    var wires = (cmd.wires || []).filter(function (w) { return sel.nodes[w.from[0]] && sel.nodes[w.to[0]] && !skip[w.from[0]] && !skip[w.to[0]]; }).map(clone);
    var comments = (cmd.comments || []).filter(function (cm, i) { return sel.comments[cm.id || "c" + (i + 1)]; }).map(clone);
    return { nodes: nodes, wires: wires, comments: comments };
}
function paste(cmd, clip, dx, dy) {
    var c = clone(cmd), map = {}, ids = {}, i, cids = {};
    for (i = 0; i < clip.nodes.length; i++) {
        var n = clone(clip.nodes[i]), nid = newId(c.nodes, "n");
        map[n.id] = nid;
        n.id = nid;
        n.pos = [snap(n.pos[0] + dx), snap(n.pos[1] + dy)];
        c.nodes.push(n);
        ids[nid] = true;
    }
    for (i = 0; i < clip.wires.length; i++) {
        var w = clone(clip.wires[i]);
        w.from[0] = map[w.from[0]]; w.to[0] = map[w.to[0]];
        c.wires.push(w);
    }
    c.comments = c.comments || [];
    for (i = 0; i < clip.comments.length; i++) {
        var cm = clone(clip.comments[i]);
        cm.id = newId(c.comments.map(function (x, k) { return { id: x.id || "c" + (k + 1) }; }), "c");
        cm.x = snap(cm.x + dx); cm.y = snap(cm.y + dy);
        c.comments.push(cm);
        cids[cm.id] = true;
    }
    return { cmd: c, nodes: ids, comments: cids };
}
// fix = {kind:"insert_converter", node_type, wire:[sn,sp,dn,dp]} (engine report) or {node_type} + explicit wire
function applyFix(cmd, catalog, fix, wire) {
    if (!fix || fix.kind !== "insert_converter") return { cmd: cmd, id: null };
    var w = fix.wire || wire, entry = catalog[fix.node_type];
    if (!w || !entry) return { cmd: cmd, id: null };
    var c = clone(cmd), a = findNode(c, w[0]), b = findNode(c, w[2]);
    if (!a || !b) return { cmd: cmd, id: null };
    var id = newId(c.nodes, "n");
    var x = snap((a.pos[0] + b.pos[0]) / 2), y = snap((a.pos[1] + b.pos[1]) / 2 + 60);
    removeWires(c, function (ww) { return ww.from[0] === w[0] && ww.from[1] === w[1] && ww.to[0] === w[2] && ww.to[1] === w[3]; });
    c.nodes.push({ id: id, type: entry.type, pos: [x, y], props: {} });
    c.wires.push({ from: [w[0], w[1]], to: [id, entry.ins[0].id] });
    c.wires.push({ from: [id, entry.outs[0].id], to: [w[2], w[3]] });
    return { cmd: c, id: id };
}

// ---- palette -------------------------------------------------------------------------------------------------------
// opts: {noEvents: bool, exclude: type string}: inside a function graph there are no events and no call to itself
function paletteOk(e, opts) {
    if (e.hidden) return false;
    if (opts && opts.noEvents && e.flow === "event") return false;
    if (opts && opts.exclude && e.type === opts.exclude) return false;
    return true;
}
function searchCatalog(catalog, query, limit, opts) {
    var q = (query || "").trim().toLowerCase(), toks = q === "" ? [] : q.split(/\s+/), out = [];
    var keys = Object.keys(catalog);
    for (var i = 0; i < keys.length; i++) {
        var e = catalog[keys[i]], ok = paletteOk(e, opts), score = 0, title = e.title.toLowerCase();
        for (var t = 0; t < toks.length; t++) {
            if (e.search.indexOf(toks[t]) < 0) { ok = false; break; }
            if (title.indexOf(toks[t]) === 0) score += 100;
            else if (title.indexOf(toks[t]) >= 0) score += 60;
            else if (e.id.indexOf(toks[t]) >= 0) score += 30;
            else score += 10;
        }
        if (ok) out.push({ entry: e, score: score });
    }
    out.sort(function (a, b) { return b.score - a.score || (a.entry.title < b.entry.title ? -1 : 1); });
    return out.slice(0, limit || 40).map(function (o) { return o.entry; });
}
// Nodes that can take (from an output pin) / feed (from an input pin) the dragged pin: [{entry, pin}]
function entriesFor(catalog, pinType, fromOutput, opts) {
    var res = [], keys = Object.keys(catalog);
    for (var i = 0; i < keys.length; i++) {
        var e = catalog[keys[i]], list = fromOutput ? e.ins : e.outs;
        if (!paletteOk(e, opts)) continue;
        for (var j = 0; j < list.length; j++) {
            var p = list[j];
            if (p.literal) continue;
            var pt = p.type_from_var ? "any!" : wild(p.full, e.generics);
            if (fromOutput ? compatible(pinType, pt) : compatible(pt, pinType)) { res.push({ entry: e, pin: p.id }); break; }
        }
    }
    return res;
}

// ---- functions (custom nodes): collapse a selection into a call node and expand it back --------------------------------
// Pure data in, pure data out: both return a NEW command and never touch the file system. The caller (XEdit) first asks the
// engine to store the function (`fn create`), then applies the result as ONE undo step.
function plainType(t) { return String(t).split("any!").join("any"); }
function pinId(base, used) {
    var id = String(base || "p").toLowerCase().replace(/[^a-z0-9_]+/g, "_").replace(/^_+|_+$/g, "");
    if (!/^[a-z]/.test(id)) id = "p" + (id === "" ? "" : "_" + id);
    id = id.slice(0, 28);
    var out = id, n = 2;
    while (used[out] || out === "exec" || out === "exec_in" || out === "exec_out") out = id + "_" + (n++);
    used[out] = true;
    return out;
}
function isNumeric(t) { return t === "int" || t === "float"; }

// -> {ok:false, code, reason} | {ok:true, fn, plan, pins:{inputs,outputs,exec}, warnings:[], count}
//   sel = {nodeId: true}; opts = {name, description}
function collapseSelection(cmd, catalog, sel, opts) {
    var ids = Object.keys(sel || {}), i, j, w;
    if (ids.length === 0) return { ok: false, code: "empty", reason: "Выделите узлы, которые нужно свернуть" };
    var inside = {}, nodes = [], ent = {};
    for (i = 0; i < ids.length; i++) {
        var nd = findNode(cmd, ids[i]);
        if (!nd) continue;
        var e = catalog[nd.type];
        if (!e) return { ok: false, code: "unknown", reason: "В выделении есть узел неизвестного типа" };
        if (e.flow === "event") return { ok: false, code: "event", reason: "Событие нельзя свернуть в функцию: функцию запускает команда" };
        if (nd.type === FN_INPUT_TYPE || nd.type === FN_OUTPUT_TYPE) return { ok: false, code: "iface", reason: "Вход и выход функции свернуть нельзя" };
        if (e.id === "logic.break") return { ok: false, code: "break", reason: "«Прервать цикл» работает только внутри цикла: выделите вместе с циклом или оставьте снаружи" };
        inside[nd.id] = true; nodes.push(nd); ent[nd.id] = e;
    }
    if (nodes.length === 0) return { ok: false, code: "empty", reason: "Выделите узлы, которые нужно свернуть" };
    var wl = cmd.wires || [], inW = [], outW = [], intW = [];
    for (i = 0; i < wl.length; i++) {
        w = wl[i];
        var a = !!inside[w.from[0]], b = !!inside[w.to[0]];
        if (a && b) intW.push(w); else if (!a && b) inW.push(w); else if (a && !b) outW.push(w);
    }
    var execIn = [], execOut = [], dataIn = [], dataOut = [];
    for (i = 0; i < inW.length; i++) (pinTypeFor(cmd, catalog, inW[i].from[0], inW[i].from[1], false) === "exec" ? execIn : dataIn).push(inW[i]);
    for (i = 0; i < outW.length; i++) (pinTypeFor(cmd, catalog, outW[i].from[0], outW[i].from[1], false) === "exec" ? execOut : dataOut).push(outW[i]);

    var hasExec = false;
    for (i = 0; i < nodes.length; i++) if (ent[nodes[i].id].flow !== "pure") hasExec = true;
    var fnWires = [], inputs = [], outputs = [], usedIn = {}, usedOut = {}, plan = { inputs: [], outputs: [], execIn: [], execOut: null, literals: [] };

    // execution entry: exactly one inside node receives the order from outside (or is the head of the group)
    var entryNode = null, entryPin = "exec_in";
    if (hasExec) {
        var targets = {};
        for (i = 0; i < execIn.length; i++) targets[execIn[i].to[0] + ":" + execIn[i].to[1]] = execIn[i].to;
        var tk = Object.keys(targets);
        if (tk.length > 1) return { ok: false, code: "multi_entry", reason: "В группу порядок выполнения входит в нескольких местах: выделите связный кусок цепочки" };
        if (tk.length === 1) { entryNode = targets[tk[0]][0]; entryPin = targets[tk[0]][1]; }
        else {
            var fed = {};
            for (i = 0; i < intW.length; i++) if (pinTypeFor(cmd, catalog, intW[i].from[0], intW[i].from[1], false) === "exec") fed[intW[i].to[0]] = true;
            var heads = nodes.filter(function (n) { return ent[n.id].flow !== "pure" && !fed[n.id] && ent[n.id].ins.some(function (p) { return p.full === "exec"; }); });
            if (heads.length !== 1) return { ok: false, code: "multi_entry", reason: "У группы должно быть одно начало цепочки: сейчас их " + heads.length };
            entryNode = heads[0].id;
            entryPin = ent[entryNode].ins.filter(function (p) { return p.full === "exec"; })[0].id;
        }
        fnWires.push({ from: [FN_IN, "exec"], to: [entryNode, entryPin] });
        for (i = 0; i < execIn.length; i++) plan.execIn.push(execIn[i].from);
        var exits = {};
        for (i = 0; i < execOut.length; i++) exits[execOut[i].from[0] + ":" + execOut[i].from[1]] = execOut[i].from;
        var ek = Object.keys(exits);
        if (ek.length > 1) return { ok: false, code: "multi_exit", reason: "Из группы выходит несколько веток порядка выполнения: выделите так, чтобы выход был один" };
        if (ek.length === 1) {
            fnWires.push({ from: exits[ek[0]], to: [FN_OUT, "exec_in"] });
            plan.execOut = execOut[0].to;
        }
    }

    // data in: one input per distinct outside source pin (wire), and one per numeric literal (keeps its value as default)
    var srcKey = {}, labelSeen = {};
    function labelFor(p, node) {
        var l = p.n, key = l.toLowerCase();
        if (labelSeen[key]) l = l + " (" + ent[node.id].title + ")";
        labelSeen[key] = true;
        return l;
    }
    for (i = 0; i < dataIn.length; i++) {
        w = dataIn[i];
        var sk = w.from[0] + ":" + w.from[1];
        var pin = pinOf(ent[w.to[0]], w.to[1], true);
        var inp = srcKey[sk];
        if (!inp) {
            var t = plainType(pinTypeFor(cmd, catalog, w.to[0], w.to[1], true));
            if (t === "any") t = plainType(pinTypeFor(cmd, catalog, w.from[0], w.from[1], false));
            inp = { id: pinId(pin.id, usedIn), type: t, label: labelFor(pin, findNode(cmd, w.to[0])) };
            srcKey[sk] = inp; inputs.push(inp);
            plan.inputs.push({ pin: inp.id, from: w.from });
        }
        fnWires.push({ from: [FN_IN, inp.id], to: w.to });
    }
    for (i = 0; i < nodes.length; i++) {
        var n = nodes[i], props = n.props || {}, pins = ent[n.id].ins;
        for (j = 0; j < pins.length; j++) {
            var p = pins[j], wired = wl.some(function (ww) { return ww.to[0] === n.id && ww.to[1] === p.id; });
            if (wired || p.literal || p.choices || p.type_from_var || !hasKey(props, p.id) || !isNumeric(p.full)) continue;
            var lin = { id: pinId(p.id, usedIn), type: p.full, label: labelFor(p, n), "default": props[p.id] };
            inputs.push(lin);
            plan.literals.push({ pin: lin.id, value: props[p.id] });
            fnWires.push({ from: [FN_IN, lin.id], to: [n.id, p.id] });
        }
    }
    // data out: one output per distinct inside source pin
    var outKey = {};
    for (i = 0; i < dataOut.length; i++) {
        w = dataOut[i];
        var ok2 = w.from[0] + ":" + w.from[1];
        var op = pinOf(ent[w.from[0]], w.from[1], false), o = outKey[ok2];
        if (!o) {
            o = { id: pinId(op.id, usedOut), type: plainType(pinTypeFor(cmd, catalog, w.from[0], w.from[1], false)), label: labelFor(op, findNode(cmd, w.from[0])) };
            if (o.type === "any") o.type = plainType(pinTypeFor(cmd, catalog, w.to[0], w.to[1], true));
            outKey[ok2] = o; outputs.push(o);
            plan.outputs.push({ pin: o.id, to: [] });
            fnWires.push({ from: w.from, to: [FN_OUT, o.id] });
        }
        for (j = 0; j < plan.outputs.length; j++) if (plan.outputs[j].pin === o.id) plan.outputs[j].to.push(w.to);
    }
    // inner nodes and wires, positions normalised to the top-left corner of the group
    var minx = 1e9, miny = 1e9, maxx = -1e9;
    for (i = 0; i < nodes.length; i++) { minx = Math.min(minx, nodes[i].pos[0]); miny = Math.min(miny, nodes[i].pos[1]); maxx = Math.max(maxx, nodes[i].pos[0]); }
    var fnNodes = [{ id: FN_IN, type: FN_INPUT_TYPE, pos: [40, 60], props: {} }];
    for (i = 0; i < nodes.length; i++) {
        var cn = clone(nodes[i]);
        cn.pos = [snap(cn.pos[0] - minx + 340), snap(cn.pos[1] - miny + 60)];
        fnNodes.push(cn);
    }
    fnNodes.push({ id: FN_OUT, type: FN_OUTPUT_TYPE, pos: [snap(maxx - minx + 340 + 340), 60], props: {} });
    for (i = 0; i < intW.length; i++) fnWires.push(clone(intW[i]));
    // variables used by the group are declared inside the function (the scope is separate: the value is not shared)
    var warnings = [], vars = [], names = {};
    for (i = 0; i < nodes.length; i++) {
        var pr = nodes[i].props || {}, pl = ent[nodes[i].id].ins.concat(ent[nodes[i].id].outs);
        for (j = 0; j < pl.length; j++) if (pl[j].type_from_var && pr[pl[j].type_from_var] !== undefined) names[pr[pl[j].type_from_var]] = true;
    }
    (cmd.variables || []).forEach(function (v) { if (names[v.name]) { var c2 = clone(v); c2.scope = "run"; vars.push(c2); } });
    if (vars.length > 0) warnings.push("vars");
    var fn = { name: (opts && opts.name) || "", description: (opts && opts.description) || "", icon: "function", exec: hasExec,
               inputs: inputs, outputs: outputs, nodes: fnNodes, wires: fnWires, variables: vars, comments: [] };
    plan.remove = ids.filter(function (id) { return inside[id]; });
    plan.pos = [snap(minx), snap(miny)];
    plan.exec = hasExec;
    return { ok: true, fn: fn, plan: plan, pins: { inputs: inputs, outputs: outputs, exec: hasExec }, warnings: warnings, count: nodes.length };
}

// Replace the selection by one call node of `fnType` (created by the engine from collapseSelection().fn): ONE new document.
function applyCollapse(cmd, plan, fnType) {
    var c = clone(cmd), rm = {}, i;
    for (i = 0; i < plan.remove.length; i++) rm[plan.remove[i]] = true;
    c.nodes = c.nodes.filter(function (n) { return !rm[n.id]; });
    c.wires = c.wires.filter(function (w) { return !rm[w.from[0]] && !rm[w.to[0]]; });
    var id = newId(c.nodes, "n"), props = {};
    for (i = 0; i < plan.literals.length; i++) props[plan.literals[i].pin] = plan.literals[i].value;
    c.nodes.push({ id: id, type: fnType, pos: plan.pos, props: props });
    for (i = 0; i < plan.inputs.length; i++) c.wires.push({ from: plan.inputs[i].from, to: [id, plan.inputs[i].pin] });
    for (i = 0; i < plan.execIn.length; i++) c.wires.push({ from: plan.execIn[i], to: [id, "exec_in"] });
    for (i = 0; i < plan.outputs.length; i++) for (var j = 0; j < plan.outputs[i].to.length; j++) c.wires.push({ from: [id, plan.outputs[i].pin], to: plan.outputs[i].to[j] });
    if (plan.execOut) c.wires.push({ from: [id, "exec_out"], to: plan.execOut });
    return { cmd: c, id: id };
}

// Inline a call node back into the command. fn = the function document. Outside wires are re-joined to the inner nodes;
// unconnected inputs take the call node's literal (or the function's default) as a literal of the inner pin.
function expandCall(cmd, catalog, callId, fn) {
    var c = clone(cmd), call = findNode(c, callId), i, j;
    if (!call) return { ok: false, code: "missing", reason: "Нет такого узла" };
    var iface = {}, map = {}, inner = (fn.nodes || []).filter(function (n) { return n.id !== FN_IN && n.id !== FN_OUT; });
    c.nodes = c.nodes.filter(function (n) { return n.id !== callId; });
    var outerIn = c.wires.filter(function (w) { return w.to[0] === callId; }), outerOut = c.wires.filter(function (w) { return w.from[0] === callId; });
    c.wires = c.wires.filter(function (w) { return w.to[0] !== callId && w.from[0] !== callId; });
    var minx = 1e9, miny = 1e9;
    inner.forEach(function (n) { minx = Math.min(minx, n.pos[0]); miny = Math.min(miny, n.pos[1]); });
    var ids = {};
    for (i = 0; i < inner.length; i++) {
        var nn = clone(inner[i]), nid = newId(c.nodes, "n");
        map[nn.id] = nid; nn.id = nid;
        nn.pos = [snap(call.pos[0] + nn.pos[0] - minx), snap(call.pos[1] + nn.pos[1] - miny)];
        nn.props = nn.props || {};
        c.nodes.push(nn); ids[nid] = true;
    }
    function node(id) { return findNode(c, id); }
    // sources feeding an interface pin from outside: [{wire: [n,p]}] or a literal
    function feeders(pin) {
        var r = outerIn.filter(function (w) { return w.to[1] === pin; }).map(function (w) { return { src: w.from }; });
        if (r.length) return r;
        var props = call.props || {};
        if (hasKey(props, pin)) return [{ lit: props[pin] }];
        var d = (fn.inputs || []).filter(function (p) { return p.id === pin; })[0];
        return d && hasKey(d, "default") ? [{ lit: d["default"] }] : [];
    }
    function sinks(pin) { return outerOut.filter(function (w) { return w.from[1] === pin; }).map(function (w) { return w.to; }); }
    function addWire(a, b) { c.wires.push({ from: a, to: b }); }
    function setLit(to, v) { var n = node(to[0]); if (n) { n.props = n.props || {}; n.props[to[1]] = v; } }
    var fw = fn.wires || [];
    for (i = 0; i < fw.length; i++) {
        var w = fw[i], fromIn = w.from[0] === FN_IN, toOut = w.to[0] === FN_OUT;
        if (!fromIn && !toOut) { addWire([map[w.from[0]], w.from[1]], [map[w.to[0]], w.to[1]]); continue; }
        var srcs = fromIn ? (w.from[1] === "exec" ? outerIn.filter(function (x) { return x.to[1] === "exec_in"; }).map(function (x) { return { src: x.from }; }) : feeders(w.from[1]))
                          : [{ src: [map[w.from[0]], w.from[1]] }];
        var dsts = toOut ? sinks(w.to[1] === "exec_in" ? "exec_out" : w.to[1]) : [[map[w.to[0]], w.to[1]]];
        for (j = 0; j < srcs.length; j++) for (var k = 0; k < dsts.length; k++) {
            if (srcs[j].lit !== undefined) setLit(dsts[k], srcs[j].lit); else addWire(srcs[j].src, dsts[k]);
        }
    }
    // variables the function declared come back as variables of the command (kept if the name is free)
    var warnings = [];
    c.variables = c.variables || [];
    (fn.variables || []).forEach(function (v) {
        var dup = c.variables.filter(function (x) { return x.name === v.name; })[0];
        if (!dup) c.variables.push(clone(v)); else warnings.push("var_shared:" + v.name);
    });
    return { ok: true, cmd: c, ids: ids, warnings: warnings };
}


// ---- tutorial (steps are data: assets/custom-commands/tutorial.json; progress is {active, step, done, skipped}) -------------
// An event is {kind: "command_created"|"node_added"|"wire_added"|"saved"|"rehearsed"|"next", type?: "action.notify@1", exec?: bool}.
// A step advances when its `advance` rule matches: "next" | "command_created" | "saved" | "rehearsed" | "node_added:<id>[*]" | "wire_added:exec|data".
function tutMatch(rule, ev) {
    if (!rule || !ev) return false;
    if (rule === "next") return ev.kind === "next";
    var p = String(rule).split(":");
    if (p[0] !== ev.kind) return false;
    if (p.length === 1) return true;
    if (ev.kind === "node_added") {
        var t = String(ev.type || "").split("@")[0], want = p[1];
        return want.slice(-1) === "*" ? t.indexOf(want.slice(0, -1)) === 0 : t === want;
    }
    if (ev.kind === "wire_added") return p[1] === (ev.exec ? "exec" : "data");
    return false;
}
function tutState(saved) {
    saved = saved || {};
    return { active: false, step: Math.max(0, Number(saved.step || 0)), done: !!saved.done, skipped: !!saved.skipped };
}
function tutStart() { return { active: true, step: 0, done: false, skipped: false }; }
function tutGo(st, steps, i) {
    if (i >= steps.length) return { active: false, step: steps.length, done: true, skipped: false };
    return { active: true, step: Math.max(0, i), done: false, skipped: false };
}
function tutAdvance(st, steps, ev) {
    if (!st.active || st.step >= steps.length) return st;
    return tutMatch(steps[st.step].advance, ev) ? tutGo(st, steps, st.step + 1) : st;
}
function tutNext(st, steps) { return st.active ? tutGo(st, steps, st.step + 1) : st; }
function tutBack(st, steps) { return st.active ? tutGo(st, steps, st.step - 1) : st; }
function tutSkip(st) { return { active: false, step: st.step, done: false, skipped: true }; }
// first launch: never finished, never skipped, not running now
function tutOffer(st) { return !st.active && !st.done && !st.skipped; }
// the arguments of `tutorial set` for a state
function tutPersist(st) { return ["tutorial", "set", "--step", String(st.step), "--done", st.done ? "1" : "0", "--skipped", st.skipped ? "1" : "0"]; }
