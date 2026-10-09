.pragma library

// Pure reduction of the engine's trace stream (scripts/custom/cmd/xcmd/debug.py, schema v1) into the state the editor draws
// on top of the graph: node badges, last wire values, the step timeline, variables, the pause marker and the error panel.
// No QML types: testable with plain `qml6`. The same reducer plays a live stream (batched) and a stored trace.
//
// state = { run, cmd, name, status, rehearse, live, paused:{node,reason}|null, nodes:{id:{state,dur,runs,pins,error,plan,
//           would_undo,note,iter,fn}}, wires:{key:{seq,exec,value}}, steps:[{seq,t,node,type,status,dur,iter,fn,summary,
//           plan,would_undo,error}], vars:{name:value}, error:{node,message,fn,pins}|null, seq, t, dur, message }
// node states: running | ok | error | skipped | paused

var MAX_STEPS = 2000;

function create(run) {
    return { run: run || "", cmd: "", name: "", status: "", rehearse: false, live: false, paused: null, nodes: {}, wires: {},
             steps: [], vars: {}, error: null, seq: 0, t: 0, dur: 0, message: "", failed: "" };
}

function wireKey(from, to) { return from[0] + ":" + from[1] + ">" + to[0] + ":" + to[1]; }

function valueText(v) {
    if (v === undefined || v === null) return "";
    if (typeof v === "boolean") return v ? "да" : "нет";
    if (typeof v === "string") return v;
    try { return JSON.stringify(v); } catch (e) { return String(v); }
}

// "device = «Sony» · percent = 40" (first three pins)
function summarize(pins) {
    if (!pins) return "";
    var ks = Object.keys(pins), out = [];
    for (var i = 0; i < ks.length && out.length < 3; i++) {
        var t = valueText(pins[ks[i]]);
        if (t.length > 60) t = t.slice(0, 59) + "…";
        out.push(ks[i] + " = " + (typeof pins[ks[i]] === "string" ? "«" + t + "»" : t));
    }
    return out.join(" · ");
}

function lastStep(st, node) {
    for (var i = st.steps.length - 1; i >= 0; i--) if (st.steps[i].node === node && st.steps[i].status === "running") return st.steps[i];
    return null;
}

function nodeOf(st, id) {
    var n = st.nodes[id];
    if (!n) { n = { state: "", runs: 0, pins: {} }; st.nodes[id] = n; }
    return n;
}

function pushStep(st, s) {
    st.steps.push(s);
    if (st.steps.length > MAX_STEPS) st.steps.splice(0, st.steps.length - MAX_STEPS);
}

// Mutates and returns `st` (run.start returns a fresh state).
function reduce(st, ev) {
    var n, s;
    if (!ev || !ev.ev) return st;
    if (ev.seq !== undefined && ev.seq > st.seq) st.seq = ev.seq;
    if (ev.t !== undefined) st.t = ev.t;
    switch (ev.ev) {
    case "run.start":
        st = create(ev.run);
        st.cmd = ev.cmd || ""; st.name = ev.name || ""; st.rehearse = !!ev.rehearse; st.live = true; st.status = "running";
        return st;
    case "run.end":
        st.live = false; st.status = ev.status || st.status; st.message = ev.message || ""; st.dur = ev.dur || st.t; st.failed = ev.failed_node || "";
        st.paused = null;
        for (var k in st.nodes) if (st.nodes[k].state === "running" || st.nodes[k].state === "paused") st.nodes[k].state = ev.status === "ok" ? "ok" : "";
        return st;
    case "enter":
        n = nodeOf(st, ev.node); n.state = "running"; n.runs += 1; n.iter = ev.iter; n.fn = ev.fn; n.error = undefined; n.plan = undefined; n.would_undo = undefined;
        pushStep(st, { seq: ev.seq, t: ev.t, node: ev.node, type: ev.type || "", status: "running", iter: ev.iter, fn: ev.fn, summary: "", dur: 0 });
        return st;
    case "exit":
        n = nodeOf(st, ev.node);
        if (ev.pins) n.pins = ev.pins;
        if (ev.pure) { if (n.state === "") n.state = "ok"; return st; }
        n.state = "ok"; n.dur = ev.dur || 0; n.plan = ev.plan; n.would_undo = ev.would_undo; n.note = ev.note || ev.simulated;
        s = lastStep(st, ev.node);
        if (s) { s.status = "ok"; s.dur = ev.dur || 0; s.summary = summarize(ev.pins); s.plan = ev.plan; s.would_undo = ev.would_undo;
                 s.note = ev.note || ev.simulated; s.ff = ev.fast_forward; s.out = ev.out_pin; }
        return st;
    case "error":
        n = nodeOf(st, ev.node); n.state = "error"; n.error = ev.error; if (ev.pins) n.pins = ev.pins;
        s = lastStep(st, ev.node);
        if (s) { s.status = "error"; s.error = ev.error; s.dur = ev.dur || 0; s.summary = summarize(ev.pins); }
        else if (!ev.pure) pushStep(st, { seq: ev.seq, t: ev.t, node: ev.node, type: "", status: "error", error: ev.error, summary: "", dur: 0 });
        if (!st.error || st.error.node === ev.node || !st.error.fn) st.error = { node: ev.node, message: ev.error, fn: ev.fn, pins: ev.pins || {} };
        return st;
    case "skip":
        n = nodeOf(st, ev.node);
        if (n.state === "") {
            n.state = "skipped";
            pushStep(st, { seq: ev.seq, t: ev.t, node: ev.node, type: "", status: "skipped", summary: "", dur: 0, via: ev.via });
        }
        return st;
    case "wire":
        st.wires[wireKey(ev.from, ev.to)] = { seq: ev.seq, exec: !!ev.exec, value: ev.exec ? undefined : ev.value };
        return st;
    case "iter":
        n = nodeOf(st, ev.node); n.loop = { index: ev.index, total: ev.total };
        return st;
    case "var":
        st.vars[ev.name] = ev.value;
        return st;
    case "pause":
        st.paused = { node: ev.node, reason: ev.reason };
        n = nodeOf(st, ev.node); n.state = "paused";
        return st;
    case "resume":
        st.paused = null;
        n = nodeOf(st, ev.node);
        if (n.state === "paused") n.state = n.runs > 0 ? "ok" : "";
        return st;
    }
    return st;
}

function reduceAll(st, evs) {
    for (var i = 0; i < evs.length; i++) st = reduce(st, evs[i]);
    return st;
}

// a recorded trace (cmd trace --json): header fields + events
function fromTrace(rec) {
    var st = reduce(create(rec.run), { ev: "run.start", run: rec.run, cmd: rec.cmd, name: rec.name, rehearse: rec.rehearse });
    st = reduceAll(st, rec.events || []);
    st = reduce(st, { ev: "run.end", status: rec.status, message: rec.message, failed_node: rec.failed_node, dur: rec.dur });
    st.live = false;
    return st;
}

// shallow copy: QML sees a new object (change notification) while the inner maps stay shared
function snapshot(st) { return Object.assign({}, st); }

function filterSteps(steps, errorsOnly) {
    if (!errorsOnly) return steps;
    return steps.filter(function (s) { return s.status === "error"; });
}

// a batch of queued events for one UI flush: applies them and reports whether anything visible changed
function flush(st, queue) {
    if (queue.length === 0) return { st: st, changed: false };
    return { st: reduceAll(st, queue), changed: true };
}

// "было на 12:04:31.210"-style relative time of a step
function stepTime(t) {
    if (t === undefined) return "";
    return (t < 10 ? t.toFixed(3) : t.toFixed(2)) + " с";
}

// the badge glyph kind of a node state
function badge(state) {
    return state === "ok" ? "ok" : state === "error" ? "error" : state === "running" ? "run" : state === "skipped" ? "skip" : state === "paused" ? "pause" : "";
}

// Tooltip rows of a node: [{k, v}] from the last pin values, error first
function tooltipRows(n) {
    if (!n) return [];
    var rows = [];
    if (n.error) rows.push({ k: "error", v: n.error });
    if (n.plan) rows.push({ k: "plan", v: n.plan + (n.would_undo ? "; " + n.would_undo : "") });
    var ks = Object.keys(n.pins || {});
    for (var i = 0; i < ks.length; i++) rows.push({ k: ks[i], v: valueText(n.pins[ks[i]]) });
    return rows;
}
