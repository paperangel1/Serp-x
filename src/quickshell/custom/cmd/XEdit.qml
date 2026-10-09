pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."
import "EditorLogic.js" as EL

// One editing session of the Commands editor: the command document, undo/redo, selection, clipboard, live validation
// (the engine's validator over the CLI, debounced) and saving. All graph edits are the pure functions of EditorLogic.js;
// `view` is the geometry the canvas draws. The engine owns approvals / enabled / imported: save never sends them back.
Item {
    id: root
    visible: false

    property bool active: false
    property var command: null
    property string savedJson: ""
    property var report: null
    property bool validating: false
    property bool saving: false
    property string saveError: ""
    property var undoStack: []
    property var redoStack: []
    property var clipboard: null
    property var sel: ({ nodes: ({}), wires: ({}), comments: ({}) })
    property int pasteCount: 0
    // functions (custom nodes): the same canvas edits a function graph; `fnStack` holds the documents underneath (breadcrumbs)
    property string mode: "command"          // command | function
    property var fnStack: []
    property var fnIface: null               // iface_catalog of the function being edited
    property string fnType: ""
    readonly property var paletteOpts: mode === "function" ? ({ noEvents: true, exclude: fnType }) : ({})
    readonly property int selNodeCount: Object.keys(sel.nodes).length
    readonly property string parentName: fnStack.length > 0 ? (fnStack[fnStack.length - 1].command.name || "") : ""
    readonly property string selFnType: {       // the type of the single selected call node, or ""
        const ids = Object.keys(sel.nodes);
        if (!command || ids.length !== 1 || Object.keys(sel.wires).length + Object.keys(sel.comments).length > 0) return "";
        const n = EL.findNode(command, ids[0]);
        return n && n.type.indexOf("fn.") === 0 ? n.type : "";
    }

    readonly property bool dirty: active && command !== null && JSON.stringify(command) !== savedJson
    readonly property bool canUndo: undoStack.length > 0
    readonly property bool canRedo: redoStack.length > 0
    readonly property var issues: EL.indexIssues(report)
    readonly property var view: {
        if (command === null) return null;
        const v = EL.buildView(command, XCmd.catalog, XCmd.lang, issues);
        v.id = command.id || "new";
        return v;
    }
    readonly property int errors: report ? report.errors.length : 0
    readonly property int warnings: report ? report.warnings.length : 0
    readonly property int selCount: Object.keys(sel.nodes).length + Object.keys(sel.wires).length + Object.keys(sel.comments).length

    // ---- session ----------------------------------------------------------------------------------------------
    // g = ui-get document of the command (nodes carry the auto-layout positions of nodes that have none yet).
    function begin(g) {
        let cmd = JSON.parse(JSON.stringify(g.command));
        cmd.nodes = cmd.nodes || []; cmd.wires = cmd.wires || []; cmd.comments = cmd.comments || [];
        for (let i = 0; i < cmd.nodes.length; i++) {
            if (!Array.isArray(cmd.nodes[i].pos) || cmd.nodes[i].pos.length !== 2) {
                for (let j = 0; j < g.nodes.length; j++) if (g.nodes[j].id === cmd.nodes[i].id) cmd.nodes[i].pos = [g.nodes[j].x, g.nodes[j].y];
            }
            cmd.nodes[i].props = cmd.nodes[i].props || ({});
        }
        for (let i = 0; i < cmd.comments.length; i++) if (!cmd.comments[i].id) cmd.comments[i].id = "c" + (i + 1);
        mode = g["function"] !== undefined ? "function" : "command";
        fnIface = mode === "function" ? (g.iface_catalog || []) : null;
        fnType = mode === "function" ? "fn." + cmd.id + "@1" : "";
        if (mode === "command") fnStack = [];
        command = cmd;
        savedJson = JSON.stringify(cmd);
        undoStack = []; redoStack = [];
        sel = { nodes: ({}), wires: ({}), comments: ({}) };
        report = null; saveError = "";
        active = true;
        validateNow();
    }
    function setFunctionMode(g, parent) { fnStack = parent ? fnStack.concat([parent]) : []; }
    function snapshot() {
        return { command: command, savedJson: savedJson, undoStack: undoStack, redoStack: redoStack, mode: mode, fnIface: fnIface, fnType: fnType };
    }
    function restore(snap) {
        fnStack = fnStack.slice(0, -1);
        mode = snap.mode; fnIface = snap.fnIface; fnType = snap.fnType;
        command = snap.command; savedJson = snap.savedJson; undoStack = snap.undoStack; redoStack = snap.redoStack;
        sel = { nodes: ({}), wires: ({}), comments: ({}) };
        report = null; saveError = "";
        active = true;
        validateNow();
    }
    function end() { mode = "command"; fnStack = []; fnIface = null; fnType = ""; active = false; command = null; report = null; undoStack = []; redoStack = []; sel = { nodes: ({}), wires: ({}), comments: ({}) }; }

    function commit(next) {
        const cur = JSON.stringify(command);
        if (JSON.stringify(next) === cur) return;
        undoStack = undoStack.concat([cur]).slice(-200);
        redoStack = [];
        command = next;
        pruneSel();
        valTimer.restart();
    }
    function undo() {
        if (!undoStack.length) return;
        redoStack = redoStack.concat([JSON.stringify(command)]);
        command = JSON.parse(undoStack[undoStack.length - 1]);
        undoStack = undoStack.slice(0, -1);
        pruneSel(); valTimer.restart();
    }
    function redo() {
        if (!redoStack.length) return;
        undoStack = undoStack.concat([JSON.stringify(command)]);
        command = JSON.parse(redoStack[redoStack.length - 1]);
        redoStack = redoStack.slice(0, -1);
        pruneSel(); valTimer.restart();
    }

    // ---- selection --------------------------------------------------------------------------------------------
    function setSel(n, w, c) { sel = { nodes: n || ({}), wires: w || ({}), comments: c || ({}) }; }
    function clearSel() { setSel(); }
    function selectNode(id, additive) {
        const n = additive ? Object.assign({}, sel.nodes) : ({});
        if (additive && n[id]) delete n[id]; else n[id] = true;
        setSel(n, additive ? sel.wires : ({}), additive ? sel.comments : ({}));
    }
    function selectComment(id, additive) {
        const c = additive ? Object.assign({}, sel.comments) : ({});
        if (additive && c[id]) delete c[id]; else c[id] = true;
        setSel(additive ? sel.nodes : ({}), additive ? sel.wires : ({}), c);
    }
    function selectWire(key) { const w = ({}); if (key !== "") w[key] = true; setSel(({}), w, ({})); }
    function selectRect(x0, y0, x1, y1, additive) {
        const n = additive ? Object.assign({}, sel.nodes) : ({}), c = additive ? Object.assign({}, sel.comments) : ({});
        const nodes = view ? view.nodes : [], cms = view ? view.comments : [];
        for (let i = 0; i < nodes.length; i++) {
            const a = nodes[i];
            if (a.x < x1 && a.x + a.w > x0 && a.y < y1 && a.y + a.h > y0) n[a.id] = true;
        }
        for (let i = 0; i < cms.length; i++) {
            const a = cms[i];
            if (a.x < x1 && a.x + a.w > x0 && a.y < y1 && a.y + a.h > y0) c[a.id] = true;
        }
        setSel(n, additive ? sel.wires : ({}), c);
    }
    function selectAll() {
        const n = ({}), c = ({});
        (command.nodes || []).forEach(a => n[a.id] = true);
        (command.comments || []).forEach(a => c[a.id] = true);
        setSel(n, ({}), c);
    }
    function pruneSel() {
        if (!command) return;
        const ids = ({}), keys = ({}), cids = ({});
        command.nodes.forEach(n => ids[n.id] = true);
        command.wires.forEach(w => keys[EL.wireKey(w)] = true);
        (command.comments || []).forEach(c => cids[c.id] = true);
        const n = ({}), w = ({}), c = ({});
        let changed = false;
        for (const k in sel.nodes) if (ids[k]) n[k] = true; else changed = true;
        for (const k in sel.wires) if (keys[k]) w[k] = true; else changed = true;
        for (const k in sel.comments) if (cids[k]) c[k] = true; else changed = true;
        if (changed) setSel(n, w, c);
    }

    // ---- edits ------------------------------------------------------------------------------------------------
    // from = {node, pin, out: bool}: the pin the palette was opened from (the new node is wired to it).
    function addNodeAt(entry, x, y, from, pinId) {
        const r = EL.addNode(command, entry, x, y);
        let c = r.cmd;
        if (from && pinId) {
            const a = from.out ? [from.node, from.pin] : [r.id, pinId], b = from.out ? [r.id, pinId] : [from.node, from.pin];
            if (EL.canConnect(c, XCmd.catalog, a, b).ok) c = EL.connect(c, XCmd.catalog, a, b);
        }
        commit(c);
        setSel(({ [r.id]: true }), ({}), ({}));
        XCmdTutorial.notify("node_added", entry.type, false);
        if (from && pinId && c !== r.cmd) XCmdTutorial.notify("wire_added", "", isExecPin(from.out ? from.node : r.id, from.out ? from.pin : pinId));
        return r.id;
    }
    function isExecPin(nodeId, pinId) {   // an output pin of the given node: is it an execution pin? (tutorial step rules)
        const n = EL.findNode(command, nodeId), e = n ? XCmd.catalog[n.type] : null;
        if (!e) return false;
        for (let i = 0; i < e.outs.length; i++) if (e.outs[i].id === pinId) return e.outs[i].full === "exec";
        return false;
    }
    function connectPins(from, to) {   // from = [node, outPin], to = [node, inPin]
        const chk = EL.canConnect(command, XCmd.catalog, from, to);
        if (chk.ok) { const ex = isExecPin(from[0], from[1]); commit(EL.connect(command, XCmd.catalog, from, to)); XCmdTutorial.notify("wire_added", "", ex); }
        return chk;
    }
    function rewire(oldKey, from, to) {   // a picked-up wire dropped on another input: one undo step
        commit(EL.connect(EL.disconnect(command, oldKey), XCmd.catalog, from, to));
    }
    function disconnectKey(key) { commit(EL.disconnect(command, key)); clearSel(); }
    function connectWithConverter(from, to, fix) {
        let c = EL.connect(command, XCmd.catalog, from, to);
        const r = EL.applyFix(c, XCmd.catalog, fix, [from[0], from[1], to[0], to[1]]);
        commit(r.cmd);
    }
    function deleteSelection() {
        if (selCount === 0) return;
        commit(EL.deleteItems(command, sel));
        clearSel();
    }
    function moveSelection(dx, dy) { if (dx !== 0 || dy !== 0) commit(EL.moveItems(command, sel, dx, dy)); }
    function setLiteral(nodeId, pinId, value) { commit(EL.setProp(command, nodeId, pinId, value)); }
    function copySel() { if (selCount > 0) clipboard = EL.copySelection(command, sel); }
    function pasteAt(dx, dy) {
        if (!clipboard) return;
        pasteCount++;
        const r = EL.paste(command, clipboard, dx, dy);
        commit(r.cmd);
        setSel(r.nodes, ({}), r.comments);
    }
    function duplicateSel() { copySel(); pasteAt(40, 40); }
    function addCommentAt(x, y) {
        const r = EL.addComment(command, x, y);
        commit(r.cmd);
        setSel(({}), ({}), ({ [r.id]: true }));
        return r.id;
    }
    function editComment(id, fields) { commit(EL.setComment(command, id, fields)); }
    function applyFix(issue) {
        if (!issue || !issue.fix) return;
        const r = EL.applyFix(command, XCmd.catalog, issue.fix, null);
        commit(r.cmd);
        if (r.id) setSel(({ [r.id]: true }), ({}), ({}));
    }
    function setName(name) {
        const c = JSON.parse(JSON.stringify(command));
        c.name = name;
        commit(c);
    }

    // ---- validation (the engine is the single source of truth) --------------------------------------------------
    property bool valPending: false
    function validateNow() {
        if (!command) return;
        if (valProc.running) { valPending = true; return; }
        validating = true;
        valProc.command = mode === "function" ? ["bash", XCmd.script, "--json", "fn", "validate", "--fn-json", JSON.stringify(command)]
                                              : ["bash", XCmd.script, "--json", "validate", "--cmd-json", JSON.stringify(command)];
        valProc.running = true;
    }
    function onValidated(text) {
        validating = false;
        try { const r = JSON.parse(text); if (r && r.errors !== undefined) report = r; } catch (e) { XLog.warn("cmd", "XEdit.qml: could not parse JSON output (r)"); }
        if (valPending) { valPending = false; validateNow(); }
    }
    Timer { id: valTimer; interval: 150; onTriggered: root.validateNow() }
    Process {
        id: valProc
        stdout: StdioCollector { onStreamFinished: root.onValidated(this.text) }
        onExited: (code) => { if (root.validating && code > 1) { root.validating = false; } }
    }

    // ---- saving -------------------------------------------------------------------------------------------------
    property var onSaved: null
    function save(done) { XLog.info("cmd", "UI: editor save requested");
        if (!command || saving) return;
        saving = true; saveError = "";
        onSaved = done || null;
        saveOut = ""; saveErr = "";
        saveProc.command = mode === "function" ? ["bash", XCmd.script, "--json", "fn", "save", "--fn-json", JSON.stringify(command)]
                                                : ["bash", XCmd.script, "--json", "save", "--cmd-json", JSON.stringify(command)];
        saveProc.running = true;
    }
    property string saveOut: ""
    property string saveErr: ""
    function finishSave() {
        saving = false;
        let ok = false, res = null;
        try { res = JSON.parse(saveOut); ok = res && res.id !== undefined; } catch (e) { XLog.warn("cmd", "XEdit.qml: could not parse JSON output (res)"); }
        if (!ok) {
            let msg = XI18n.t("cmd.edit.save_failed", undefined, "Не удалось сохранить команду");
            try { const e = JSON.parse(saveErr); if (e.message) msg = e.message; } catch (e) { XLog.warn("cmd", "XEdit.qml: could not parse JSON output (e)"); }
            saveError = msg;
            XLog.warn("cmd", "UI: editor save failed message=" + msg);
            XCmd.showToast(msg);
            return;
        }
        const c = JSON.parse(JSON.stringify(command));
        c.id = res.id; c.name = res.name;
        command = c;
        savedJson = JSON.stringify(c);
        report = res.report;
        XCmd.afterSave(res);
        XCmdTutorial.notify("saved", "", false);
        if (onSaved) { const f = onSaved; onSaved = null; f(); }
    }
    Process {
        id: saveProc
        stdout: StdioCollector { onStreamFinished: root.saveOut = this.text }
        stderr: StdioCollector { onStreamFinished: root.saveErr = this.text }
        onExited: saveDone.restart()
    }
    Timer { id: saveDone; interval: 40; onTriggered: root.finishSave() }
}
