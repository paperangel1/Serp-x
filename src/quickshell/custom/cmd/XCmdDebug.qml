pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."
import "DebugLogic.js" as DL

// Debugger state of the Commands editor (design §5 / §11). One connection to the daemon socket (topics trace + run) feeds the
// overlay on the canvas: node badges, wire pulses and value chips, the step timeline, variables and the error panel.
//   run / rehearse / step: `run` request over the socket with {debug: true, rehearse, step, breakpoints, event}; trace events
//   arrive as pushed lines. Without a daemon the run goes through the CLI (rehearsals only make sense then) and its stored
//   trace is loaded afterwards (`cmd trace`).
// Performance: pushed events are only queued; one timer applies them at most every `flushMs` (>= 30 ms) and publishes ONE
// new `ov` object, so the canvas never re-evaluates per event and pan/zoom is not touched.
// Breakpoints live here (editor session), never in the command file.
Item {
    id: root
    visible: false

    // XCMD_DEBUG_SOCKET (tests only) points the debugger at a fake daemon while the CLI keeps running in-process
    readonly property string socketPath: Quickshell.env("XCMD_DEBUG_SOCKET") || Quickshell.env("XCMD_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/serpantinum/cmdd.sock")
    readonly property int flushMs: 40
    property var ov: DL.snapshot(DL.create())        // overlay state (replaced, never mutated in place)
    readonly property bool active: ov.run !== ""
    readonly property bool connected: sock.connected
    property bool panelOpen: false
    property string tab: "steps"                      // steps | log | vars
    property bool errorsOnly: false
    property var breakpoints: ({})                    // {ref: {nodeId: true}}, session only
    property var runs: []                             // run log of the open command (newest first)
    property string busy: ""                          // "" | live | rehearse
    property string fakeAnswer: ""                    // rehearsal: answer to ask-nodes ("" = the pin default; "2" = option 2; "да"; text)
    property string simEvent: ""                      // rehearsal / run: start from this trigger event instead of «Вручную»
    property string note: ""                          // last problem to show in the panel (no daemon, ...)
    readonly property var steps: DL.filterSteps(ov.steps, errorsOnly)

    property var _st: DL.create()
    property var _queue: []
    property var _pending: ({})
    property int _n: 0
    property string _track: ""                        // id of the run being watched
    property string _cmdId: ""

    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    // ---- breakpoints ------------------------------------------------------------------------------------------
    function bpFor(ref) { return breakpoints[ref] || ({}); }
    function hasBp(ref, id) { return !!(breakpoints[ref] && breakpoints[ref][id]); }
    function toggleBp(ref, id) {
        const all = Object.assign({}, breakpoints), cur = Object.assign({}, all[ref] || ({}));
        if (cur[id]) delete cur[id]; else cur[id] = true;
        all[ref] = cur;
        breakpoints = all;
        XLog.info("cmd", "UI: breakpoint " + (cur[id] ? "set" : "cleared"));
        if (_track !== "" && ov.live) rpc("debug_breakpoints", { run: _track, nodes: Object.keys(cur) }, null);
    }

    // ---- start / control --------------------------------------------------------------------------------------
    function answerParam() {
        const a = fakeAnswer.trim();
        if (a === "") return undefined;
        if (/^[0-9]+$/.test(a)) return { index: Math.max(0, parseInt(a) - 1) };
        if (/^(да|yes|true)$/i.test(a)) return { answer: true };
        if (/^(нет|no|false)$/i.test(a)) return { answer: false };
        return { value: a };
    }
    function start(mode, step) {
        const ref = XCmd.selectedRef, c = XCmd.find(ref);
        if (!c || c.example || busy !== "") return;
        if (XCmd.editing && XEdit.dirty) { XEdit.save(function () { root.start(mode, step); }); return; }
        panelOpen = true; tab = "steps"; note = "";
        _st = DL.create(); _queue = []; _track = ""; _cmdId = c.id;
        ov = DL.snapshot(_st);
        busy = mode;
        if (mode === "rehearse") XCmdTutorial.notify("rehearsed", "", false);
        XLog.info("cmd", "UI: debug start mode=" + mode + (step ? " step" : "") + (sock.connected ? "" : " (no daemon: CLI)"));
        const params = { ref: c.id, debug: true, step: !!step, breakpoints: Object.keys(bpFor(ref)) };
        if (mode === "rehearse") {
            const ans = answerParam(), ro = {};
            if (ans !== undefined) ro.answer = ans;
            params.rehearse = Object.keys(ro).length > 0 ? ro : true;
        }
        if (simEvent.trim() !== "") params.event = { type: simEvent.trim(), data: ({}) };
        if (sock.connected) {
            rpc("run", params, (ok, res) => root.finished(ok, res));
        } else {
            if (step) { note = t("cmd.debug.no_daemon", "Служба команд не запущена: по шагам не получится, репетиция выполнится напрямую"); }
            const args = ["run", c.name];
            if (mode === "rehearse") {
                args.push("--rehearse");
                if (params.rehearse !== true && params.rehearse.answer !== undefined) { args.push("--answer"); args.push(JSON.stringify(params.rehearse.answer)); }
            }
            if (params.event) { args.push("--event"); args.push(params.event.type); }
            XCmd.cli(args, res => { if (res.run) root.loadRun(res.run, () => root.finished(true, res)); else root.finished(true, res); },
                     msg => { root.note = msg; root.finished(false, null); });
        }
    }
    function finished(ok, res) {
        busy = "";
        _flush();
        if (ok && res && res.status && res.status !== "ok" && res.status !== "cancelled" && !_st.error && res.message) {
            _st.status = res.status; _st.message = res.message; ov = DL.snapshot(_st);
        }
        XLog.info("cmd", "UI: debug run finished status=" + (res && res.status ? res.status : "?"));
        if (XCmd.selected) refreshLog(XCmd.selectedRef);
    }
    function step() {
        if (busy !== "" && ov.live) { if (_track !== "") rpc("debug_step", { run: _track }, null); }
        else start("live", true);
    }
    function cont() { if (_track !== "" && ov.live) rpc("debug_continue", { run: _track }, null); }
    function stop() {
        if (_track !== "" && ov.live) rpc("debug_stop", { run: _track }, null);
        else if (_track !== "") rpc("cancel", { run: _track }, null);
    }
    function clear() { _st = DL.create(); _queue = []; _track = ""; ov = DL.snapshot(_st); busy = ""; }
    function focusError() { return ov.error ? ov.error.node : ""; }

    // ---- stored runs ------------------------------------------------------------------------------------------
    function loadRun(rid, done) {
        XCmd.cli(["trace", rid], rec => {
            root._st = DL.fromTrace(rec); root._queue = []; root._track = "";
            root.ov = DL.snapshot(root._st); root.panelOpen = true; root.tab = "steps";
            XLog.info("cmd", "UI: trace loaded steps=" + root._st.steps.length);
            if (done) done();
        }, msg => { root.note = msg; if (done) done(); });
    }
    function refreshLog(ref) {
        const c = XCmd.find(ref);
        if (!c || c.example) { runs = []; return; }
        XCmd.cli(["log", "-c", c.id, "-n", "30"], r => { root.runs = (r.runs || []).slice().reverse(); }, msg => { root.runs = []; });
    }

    // ---- socket ------------------------------------------------------------------------------------------------
    function rpc(method, params, cb) {
        if (!sock.connected) { if (cb) cb(false, null); return; }
        _n += 1;
        if (cb) { const p = Object.assign({}, _pending); p[_n] = cb; _pending = p; }
        sock.write(JSON.stringify({ id: _n, method: method, params: params }) + "\n");
        sock.flush();
    }
    function onLine(line) {
        let m = null;
        try { m = JSON.parse(line); } catch (e) { XLog.warn("cmd", "XCmdDebug.qml: could not parse a daemon line"); return; }
        if (m.id !== undefined && m.id !== null) {
            const cb = _pending[m.id];
            if (cb) { const p = Object.assign({}, _pending); delete p[m.id]; _pending = p; if (m.ok) cb(true, m.result); else { root.note = (m.error && m.error.message) || ""; cb(false, null); } }
            return;
        }
        if (busy === "" && _track === "") return;
        if (m.ev === "run.start") { if (_track === "" && m.cmd === _cmdId) _track = m.run; else return; }
        else if (m.run !== _track) return;
        _queue.push(m);
        if (!flushTimer.running) flushTimer.start();
    }
    function _flush() {
        if (_queue.length === 0) return;
        const q = _queue; _queue = [];
        _st = DL.reduceAll(_st, q);
        ov = DL.snapshot(_st);
    }
    Timer { id: flushTimer; interval: root.flushMs; repeat: true; onTriggered: { if (root._queue.length === 0) flushTimer.stop(); else root._flush(); } }

    Socket {
        id: sock
        path: root.socketPath
        parser: SplitParser { onRead: data => root.onLine(data) }
        onConnectedChanged: {
            if (connected) {
                XLog.info("cmd", "UI: debugger connected to the daemon");
                root.rpc("subscribe", { topics: ["trace", "run"] }, null);
            } else {
                XLog.info("cmd", "UI: debugger disconnected from the daemon");
                if (root.busy !== "") { root.busy = ""; root.note = root.t("cmd.debug.lost", "Связь со службой команд потеряна"); }
            }
        }
    }
    Process { id: probe; command: ["test", "-S", root.socketPath]; onExited: (code) => { if (code === 0 && !sock.connected) sock.connected = true; } }
    // look for the daemon only while a graph is open (no idle cost, nothing in the log when the daemon is stopped)
    Timer {
        interval: 4000; repeat: true; triggeredOnStart: true
        running: XCmd.open && XCmd.screen === "graph"
        onTriggered: if (!sock.connected && !probe.running) probe.running = true
    }
    Connections {
        target: XCmd
        function onSelectedRefChanged() { root.clear(); root.runs = []; root.note = ""; }
        function onScreenChanged() { if (XCmd.screen !== "graph") { root.clear(); root.panelOpen = false; } else if (XCmd.selected) root.refreshLog(XCmd.selectedRef); }
    }
}
