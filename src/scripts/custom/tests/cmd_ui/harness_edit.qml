import QtQuick
import QtTest
import Quickshell
import "custom"
import "custom/cmd"

// Offscreen test of the Commands EDITOR with REAL pointer / keyboard events (QtTest helpers) on the REAL window, the REAL CLI
// and temp command files. Prints "T-PASS <what>" / "T-FAIL <what>" and screenshots E1..E5 into HARNESS_OUT.
// Steps run one after another; waitFor() polls a condition.
ShellRoot {
    id: shell
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    property int passed: 0
    property int failed: 0
    property var steps: []
    property int at: 0
    property string scratch: Quickshell.env("HARNESS_TMP") || "/tmp"

    function ok(c, m) { if (c) { passed++; console.log("T-PASS " + m); } else { failed++; console.log("T-FAIL " + m); } }
    function eq(a, b, m) { ok(JSON.stringify(a) === JSON.stringify(b), m + " (got " + JSON.stringify(a) + ", want " + JSON.stringify(b) + ")"); }
    function refByName(name) { for (let i = 0; i < XCmd.all.length; i++) if (XCmd.all[i].name === name) return XCmd.refOf(XCmd.all[i]); return ""; }
    function snapshot(name, then) { view.grabToImage(function (r) { r.saveToFile(shell.outDir + "/" + name + ".png"); if (then) then(); }); }

    // ---- tiny sequencer --------------------------------------------------------------------------------------
    function run(list) { steps = list; at = 0; Qt.callLater(next); }
    function next() {
        if (at >= steps.length) { finish(); return; }
        const s = steps[at++];
        if (s.wait) { waitFor(s.wait, s.timeout || 8000, s.label || ("wait #" + at)); return; }
        try { s.f(); } catch (e) { failed++; console.log("T-FAIL step " + at + " threw: " + e); }
        stepTimer.interval = s.d === undefined ? 120 : s.d;
        stepTimer.restart();
    }
    function waitFor(cond, timeout, label) {
        const t0 = Date.now();
        poll.cond = cond; poll.t0 = t0; poll.timeout = timeout; poll.label = label;
        poll.restart();
    }
    function finish() {
        console.log("T-RESULT passed=" + passed + " failed=" + failed);
        Qt.exit(failed > 0 ? 1 : 0);
    }
    Timer { id: stepTimer; onTriggered: shell.next() }
    Timer {
        id: poll
        interval: 40; repeat: true
        property var cond: null
        property real t0: 0
        property real timeout: 0
        property string label: ""
        onTriggered: {
            let done = false;
            try { done = cond(); } catch (e) { done = false; }
            if (done) { stop(); shell.next(); }
            else if (Date.now() - t0 > timeout) { stop(); shell.failed++; console.log("T-FAIL timeout waiting for: " + label); shell.next(); }
        }
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 1600; implicitHeight: 860
        color: "#0f0e14"
        CmdView { id: view }
        TestCase { id: tc; name: "editor"; when: false }

        readonly property var gv: view.graphView
        readonly property var cv: view.graphView.canvasItem

        // ---- geometry helpers: world (graph) coordinates -> canvas-local points -----------------------------------
        function wp(wx, wy) { return Qt.point(cv.panX + wx * cv.zoom, cv.panY + wy * cv.zoom); }
        function nodeOf(id) { const l = XEdit.command.nodes; for (let i = 0; i < l.length; i++) if (l[i].id === id) return l[i]; return null; }
        function vnode(id) { return cv.byId[id]; }
        function pinPt(id, pin, out) { return cv.pinPoint(id, pin, out); }
        function press(p) { const q = wp(p.x, p.y); tc.mousePress(cv, q.x, q.y); }
        function moveTo(p) { const q = wp(p.x, p.y); tc.mouseMove(cv, q.x, q.y); }
        function release(p) { const q = wp(p.x, p.y); tc.mouseRelease(cv, q.x, q.y); }
        function click(p) { const q = wp(p.x, p.y); tc.mouseClick(cv, q.x, q.y); }
        function dragWorld(a, b) {
            press(a);
            for (let i = 1; i <= 4; i++) moveTo(Qt.point(a.x + (b.x - a.x) * i / 4, a.y + (b.y - a.y) * i / 4));
            release(b);
        }
        function focusGraph() { gv.forceActiveFocus(); }
        function key(k, mod) { focusGraph(); tc.keyClick(k, mod || 0); }
        function typeText(s) { for (let i = 0; i < s.length; i++) tc.keyClick(s[i]); }
        function clickItem(it) { tc.mouseClick(it, it.width / 2, it.height / 2); }
        function nodeCount() { return XEdit.command.nodes.length; }
        function hasWire(a, ap, b, bp) { return XEdit.command.wires.some(w => w.from[0] === a && w.from[1] === ap && w.to[0] === b && w.to[1] === bp); }

        readonly property var perfSteps: [
            { d: 300, f: function () { XCmd.openWindow(); } },
            { wait: function () { return XCmd.loaded && Object.keys(XCmd.catalog).length > 0; }, label: "list + catalogue loaded" },
            { d: 600, f: function () { XCmd.openEditor(shell.refByName("Большой граф")); } },
            { wait: function () { return XCmd.editing && XEdit.view !== null; }, timeout: 30000, label: "big graph in the editor" },
            { d: 800, f: function () { cv.zoom = 0.4; cv.panX = 10; cv.panY = 10; XEdit.selectAll(); } },
            { d: 400, f: function () {
                shell.ok(XEdit.view.nodes.length === 200, "200 nodes in the editor");
                let t0 = Date.now();
                for (let i = 0; i < 100; i++) cv.dragUpdate(i * 3, i * 2);       // every call re-evaluates the wire geometry of the whole graph
                const dt = Date.now() - t0;
                console.log("PERF-EDIT drag: 100 updates of 200 nodes / " + XEdit.view.wires.length + " wires in " + dt + " ms (" + (dt / 100).toFixed(1) + " ms each)");
                shell.ok(dt / 100 < 60, "dragging a 200-node selection costs " + (dt / 100).toFixed(1) + " ms per update (< 60)");
                t0 = Date.now();
                cv.dragDx = 0; cv.dragDy = 0;
                XEdit.moveSelection(10, 10);
                const nv = XEdit.view.nodes.length;
                const dt2 = Date.now() - t0;
                console.log("PERF-EDIT commit: move + rebuild of the view in " + dt2 + " ms (" + nv + " nodes)");
                shell.ok(dt2 < 400, "one edit of a 200-node graph rebuilds the view in " + dt2 + " ms (< 400)");
                t0 = Date.now();
                for (let i = 0; i < 20; i++) XEdit.undoStack = XEdit.undoStack.concat([JSON.stringify(XEdit.command)]);
                XEdit.undo();
                const dt3 = Date.now() - t0;
                shell.ok(dt3 < 800, "undo on a 200-node graph takes " + dt3 + " ms (< 800)");
            } }
        ]

        // ---- functions (stage 6): collapse -> one undo step -> expand -> edit the function -> breadcrumbs -> library ----------
        readonly property var fnSteps: [
            { d: 300, f: function () { XCmd.openWindow(); } },
            { wait: function () { return XCmd.loaded && Object.keys(XCmd.catalog).length > 0; }, label: "list + catalogue loaded" },
            { d: 500, f: function () { XCmd.openEditor(shell.refByName("Вечер")); } },
            { wait: function () { return XCmd.editing && XEdit.view !== null; }, label: "«Вечер» in the editor" },
            { d: 400, f: function () {
                shell.eq(nodeCount(), 4, "four nodes: sunset + three actions");
                shell.ok(XCmd.fnById("quiet-evening") !== null, "the library function is known to the window");
                shell.ok(XCmd.catalog["fn.quiet-evening@1"] !== undefined, "and is in the node catalogue (palette)");
                cv.zoom = 1; cv.panX = 30; cv.panY = 30;
                XEdit.setSel({ n2: true, n3: true, n4: true }, {}, {});
            } },
            { d: 300, f: function () {
                shell.ok(gv.selectionBar.visible, "selecting nodes shows the selection bar (C5)");
                shell.snapshot("E6_collapse_bar", null);
                key(Qt.Key_G, Qt.ControlModifier);
            } },
            { wait: function () { return XCmd.dialog !== null && XCmd.dialog.kind === "fn_collapse"; }, label: "Ctrl+G opens the collapse dialog" },
            { d: 200, f: function () {
                shell.eq(XCmd.dialog.pins.inputs.map(p => p.id), ["percent"], "the dialog previews the inferred input");
                XCmd.collapseConfirm("Тихий вечер 2", "проверка");
            } },
            { wait: function () { return nodeCount() === 2; }, label: "the group is replaced by one call node" },
            { d: 300, f: function () {
                const call = XEdit.command.nodes.filter(n => n.type.indexOf("fn.") === 0)[0];
                shell.ok(call !== undefined && call.props.percent === 30, "the call node keeps the numeric literal as its input");
                shell.eq(XEdit.undoStack.length, 1, "collapse is exactly ONE undo step");
                shell.ok(XCmd.dialog === null, "the dialog is closed");
                shell.ok(XEdit.sel.nodes[call.id], "the new node is selected");
                key(Qt.Key_Z, Qt.ControlModifier);
            } },
            { d: 250, f: function () { shell.eq(nodeCount(), 4, "one Ctrl+Z brings all three nodes back"); key(Qt.Key_Y, Qt.ControlModifier); } },
            { d: 250, f: function () {
                shell.eq(nodeCount(), 2, "Ctrl+Y collapses again");
                const call = XEdit.command.nodes.filter(n => n.type.indexOf("fn.") === 0)[0];
                XEdit.setSel(({ [call.id]: true }), {}, {});
            } },
            { d: 250, f: function () { shell.ok(XEdit.selFnType !== "", "a single call node is recognised"); shell.snapshot("E7_call_node", null); key(Qt.Key_G, Qt.ControlModifier | Qt.ShiftModifier); } },
            { wait: function () { return nodeCount() === 4; }, label: "Ctrl+Shift+G expands the call node" },
            { d: 250, f: function () {
                shell.eq(XEdit.command.nodes.map(n => n.type).slice(1), ["action.night_filter@1", "action.dark_theme@1", "action.brightness@1"], "the nodes are back, in order");
                key(Qt.Key_Z, Qt.ControlModifier);
            } },
            { d: 250, f: function () {
                shell.eq(nodeCount(), 2, "expand is one undo step too");
                const call = XEdit.command.nodes.filter(n => n.type.indexOf("fn.") === 0)[0];
                XEdit.setSel(({ [call.id]: true }), {}, {});
                XCmd.editSelectedFunction();
            } },
            { wait: function () { return XEdit.mode === "function" && XEdit.view !== null; }, label: "«Редактировать функцию» opens the function graph" },
            { d: 500, f: function () {
                shell.eq(XEdit.view.nodes.length, 5, "function graph: interface nodes around three inner nodes");
                shell.eq(gv.crumb, "Вечер", "breadcrumb shows the command underneath");
                shell.ok(XCmd.catalog["function.input@1"] !== undefined, "interface nodes are in the catalogue while editing a function");
                cv.zoom = 0.8; cv.panX = 20; cv.panY = 40;
                XEdit.selectNode("fn_in", false);
                key(Qt.Key_Delete);
            } },
            { d: 250, f: function () { shell.eq(nodeCount(), 5, "the interface nodes cannot be deleted"); shell.snapshot("E8_function_graph", null); } },
            { wait: function () { return !XEdit.validating && XEdit.report !== null; }, label: "function validated as a function" },
            { d: 100, f: function () { shell.eq(XEdit.errors, 0, "the collapsed function validates without errors"); XEdit.setLiteral("n2", "on", false); } },
            { d: 200, f: function () { shell.ok(XEdit.dirty, "editing the function marks it dirty"); XCmd.leaveEditor(); } },
            { d: 250, f: function () { shell.ok(XCmd.dialog !== null && XCmd.dialog.kind === "fn_unsaved", "leaving a changed function asks what to do"); XEdit.save(); } },
            { wait: function () { return !XEdit.saving && !XEdit.dirty; }, label: "function saved" },
            { d: 200, f: function () { XCmd.dialog = null; XCmd.leaveEditor(); } },
            { wait: function () { return XEdit.mode === "command"; }, label: "back to the command through the breadcrumb" },
            { d: 300, f: function () {
                shell.eq(nodeCount(), 2, "the command is back with its call node");
                XCmd.cli(["fn", "show", XCmd.functions.filter(f => f.name === "Тихий вечер 2")[0].id], function (r) { win.saved = r; }, function (m) { win.saved = { error: m }; });
            } },
            { wait: function () { return win.saved !== null; }, label: "fn show" },
            { d: 100, f: function () {
                shell.eq(win.saved.nodes.filter(n => n.id === "n2")[0].props.on, false, "the function edit reached the library file");
                XCmd.dialog = null; XCmd.stopEdit(); XCmd.screen = "list"; XCmd.filter = "functions";
            } },
            { d: 600, f: function () {
                shell.ok(XCmd.functions.length >= 2, "the library lists the old and the new function");
                shell.snapshot("E9_function_library", null);
            } }
        ]
        Component.onCompleted: {
            if (Quickshell.env("HARNESS_MODE") === "fn") { shell.run(fnSteps); return; }
            if (Quickshell.env("HARNESS_MODE") === "perf") { shell.run(perfSteps); return; }
            shell.run([
                { d: 300, f: function () { XCmd.openWindow(); } },
                { wait: function () { return XCmd.loaded && Object.keys(XCmd.catalog).length > 0; }, label: "list + catalogue loaded" },
                // ---- E5: the list screen with the enabled buttons -------------------------------------------------
                { d: 700, f: function () { XCmd.select(shell.refByName("Наушники")); } },
                { wait: function () { return XCmd.graph !== null; }, label: "graph of the selected command" },
                { d: 500, f: function () {
                    shell.ok(true, "list screen shown");
                    shell.snapshot("E5_list_actions", null);
                } },
                // ---- open the editor through the real «Изменить» button -------------------------------------------
                { d: 600, f: function () { XCmd.openGraph(shell.refByName("Наушники")); } },
                { wait: function () { return XCmd.screen === "graph" && gv.g !== null; }, label: "graph screen" },
                { d: 400, f: function () { clickItem(gv.editButton); } },
                { wait: function () { return XCmd.editing && XEdit.view !== null; }, label: "editor open" },
                { d: 400, f: function () {
                    shell.ok(XEdit.active && !XEdit.dirty, "editor starts clean");
                    shell.eq(XEdit.command.nodes.length, 6, "six nodes loaded");
                    cv.zoom = 1; cv.panX = 30; cv.panY = 20;
                } },
                { wait: function () { return !XEdit.validating && XEdit.report !== null; }, label: "first validation" },
                { d: 100, f: function () { shell.eq(XEdit.errors, 0, "the example command validates without errors"); } },

                // ---- drag a node with the mouse; undo / redo through the keyboard --------------------------------
                { d: 200, f: function () {
                    const n = vnode("n5");
                    dragWorld(Qt.point(n.x + 90, n.y + 12), Qt.point(n.x + 190, n.y + 62));
                } },
                { d: 150, f: function () {
                    shell.eq(nodeOf("n5").pos, [500, 380], "node dragged by (100, 50), snapped to the grid");
                    shell.ok(XEdit.dirty && XEdit.canUndo, "a move marks the command dirty");
                    key(Qt.Key_Z, Qt.ControlModifier);
                } },
                { d: 150, f: function () {
                    shell.eq(nodeOf("n5").pos, [400, 330], "Ctrl+Z restores the position");
                    shell.ok(!XEdit.dirty, "undo back to the saved state is clean again");
                    key(Qt.Key_Y, Qt.ControlModifier);
                } },
                { d: 150, f: function () { shell.eq(nodeOf("n5").pos, [500, 380], "Ctrl+Y redoes the move"); key(Qt.Key_Z, Qt.ControlModifier); } },

                // ---- palette: double click on empty canvas, search, Enter ---------------------------------------
                { d: 200, f: function () {
                    const q = wp(700, 560);
                    tc.mouseDoubleClickSequence(cv, q.x, q.y);
                } },
                { d: 250, f: function () {
                    shell.ok(gv.paletteItem.shown, "double click on empty canvas opens the palette");
                    gv.paletteItem.query = "установить громк";
                } },
                { d: 250, f: function () {
                    shell.ok(gv.paletteItem.results.length >= 1 && gv.paletteItem.results[0].entry.id === "action.volume_set", "palette finds «Установить громкость» first");
                    shell.snapshot("E1_palette", null);
                } },
                { d: 400, f: function () { tc.keyClick(Qt.Key_Return); } },
                { d: 250, f: function () {
                    shell.eq(nodeCount(), 7, "Enter adds the node");
                    const added = XEdit.command.nodes[6];
                    shell.eq(added.type, "action.volume_set@1", "the added node is «Установить громкость»");
                    shell.ok(Math.abs(added.pos[0] - 700) <= 10 && Math.abs(added.pos[1] - 560) <= 10, "it is placed at the pointer");
                    shell.ok(XEdit.sel.nodes["n7"], "and selected");
                } },

                // ---- wires: drag with compatibility highlighting ---------------------------------------------------
                { d: 200, f: function () {
                    const a = pinPt("n4", "exec_out", true);
                    press(a);
                    moveTo(Qt.point(a.x + 60, a.y + 120));
                } },
                { d: 250, f: function () {
                    shell.ok(cv.wireDrag !== null, "pressing an output pin starts a wire");
                    shell.eq(cv.pinModes["n7"]["i:exec_in"], 1, "a fitting exec input lights up");
                    shell.eq(cv.pinModes["n7"]["i:percent"], -1, "a data input dims for an exec wire");
                    moveTo(Qt.point(pinPt("n4", "exec_out", true).x + 120, pinPt("n4", "exec_out", true).y + 240));
                    shell.snapshot("E2_wire_drag", null);
                } },
                { d: 500, f: function () {
                    release(pinPt("n7", "exec_in", false));
                } },
                { d: 200, f: function () {
                    shell.ok(hasWire("n4", "exec_out", "n7", "exec_in"), "dropping on a fitting pin creates the wire");
                    shell.ok(cv.wireDrag === null, "the drag state is cleared");
                } },
                // a wire of the wrong type is refused with the reason and a converter offer
                { d: 150, f: function () { dragWorld(pinPt("n1", "device", true), pinPt("n7", "percent", false)); } },
                { d: 300, f: function () {
                    shell.ok(!XEdit.command.wires.some(w => w.to[0] === "n7" && w.to[1] === "percent"), "a text output cannot feed a number input");
                    shell.ok(cv.rejected !== null && cv.rejected.text.indexOf("Этому входу нужен") === 0, "the refusal carries the reason");
                    shell.ok(gv.bubbleItem.visible && gv.bubbleItem.fixLabel.indexOf("Текст") >= 0, "the bubble offers a converter");
                } },
                { d: 200, f: function () { clickItem(gv.bubbleItem.fixButton); } },
                { d: 300, f: function () {
                    const conv = XEdit.command.nodes.filter(n => n.type === "convert.to_int@1");
                    shell.eq(conv.length, 1, "«Вставить конвертер» adds the converter node");
                    shell.ok(hasWire("n1", "device", conv[0].id, "text") && hasWire(conv[0].id, "value", "n7", "percent"), "and wires it between source and target");
                } },
                // exec fan-out is replaced (Unreal-like), not duplicated
                { d: 100, f: function () {
                    dragWorld(pinPt("n4", "exec_out", true), pinPt("n6", "exec_in", false));
                } },
                { d: 250, f: function () {
                    const fan = XEdit.command.wires.filter(w => w.from[0] === "n4" && w.from[1] === "exec_out");
                    shell.eq(fan.length, 1, "an exec output keeps one wire");
                    shell.eq(fan[0].to[0], "n6", "the new wire replaced the old one");
                    key(Qt.Key_Z, Qt.ControlModifier);
                } },
                { d: 200, f: function () { shell.ok(hasWire("n4", "exec_out", "n7", "exec_in"), "undo brings the replaced wire back"); } },

                // ---- literal editing -----------------------------------------------------------------------------
                { d: 200, f: function () {
                    const n = vnode("n3"), y = n.y + 32 + 6 + 1 * 26 + 13;
                    click(Qt.point(n.x + 40, y));
                } },
                { d: 250, f: function () {
                    shell.ok(gv.valueEditor.shown && gv.valueEditor.kind === "int", "clicking a number input opens the number editor");
                    typeText("55"); tc.keyClick(Qt.Key_Return);
                } },
                { d: 250, f: function () {
                    shell.eq(nodeOf("n3").props.percent, 55, "the literal is stored as a number");
                    shell.ok(!gv.valueEditor.shown, "the editor closes on Enter");
                } },
                { d: 150, f: function () {
                    const n = vnode("n3"), y = n.y + 32 + 6 + 1 * 26 + 13;
                    click(Qt.point(n.x + 40, y));
                } },
                { d: 250, f: function () { typeText("500"); tc.keyClick(Qt.Key_Return); } },
                { d: 200, f: function () {
                    shell.ok(gv.valueEditor.shown && gv.valueEditor.error !== "", "a value above the maximum stays open with the reason");
                    shell.eq(nodeOf("n3").props.percent, 55, "and is not stored");
                    tc.keyClick(Qt.Key_Escape);
                } },
                { d: 200, f: function () { shell.ok(!gv.valueEditor.shown, "Esc closes the editor"); } },

                // ---- delete / undo ------------------------------------------------------------------------------
                { d: 150, f: function () {
                    const n = vnode("n6");
                    click(Qt.point(n.x + 60, n.y + 12));
                } },
                { d: 150, f: function () { shell.ok(XEdit.sel.nodes["n6"], "click selects a node"); key(Qt.Key_Delete); } },
                { d: 200, f: function () {
                    shell.ok(nodeOf("n6") === null, "Delete removes the selected node");
                    shell.ok(!XEdit.command.wires.some(w => w.from[0] === "n6" || w.to[0] === "n6"), "and its wires");
                    key(Qt.Key_Z, Qt.ControlModifier);
                } },
                { d: 200, f: function () { shell.ok(nodeOf("n6") !== null && hasWire("n5", "exec", "n6", "exec_in"), "undo brings node and wire back"); } },

                // ---- rubber band, copy / paste ------------------------------------------------------------------
                { d: 150, f: function () {
                    const a = vnode("n2"), b = vnode("n3");
                    dragWorld(Qt.point(a.x - 20, a.y - 30), Qt.point(b.x + b.w + 20, b.y + b.h + 20));
                } },
                { d: 200, f: function () {
                    shell.ok(XEdit.sel.nodes["n2"] && XEdit.sel.nodes["n3"], "a rubber band selects the nodes it touches");
                    key(Qt.Key_C, Qt.ControlModifier);
                    key(Qt.Key_V, Qt.ControlModifier);
                } },
                { d: 250, f: function () {
                    shell.eq(nodeCount(), 10, "Ctrl+C / Ctrl+V pasted the two selected nodes");
                    const pasted = XEdit.command.nodes.slice(8).map(n => n.type);
                    shell.eq(pasted, ["action.audio_output@1", "action.volume_set@1"], "the copies keep their types");
                    shell.ok(hasWire("n9", "exec_out", "n10", "exec_in"), "and the wire between them");
                    shell.ok(XEdit.sel.nodes["n9"] && XEdit.sel.nodes["n10"], "the pasted nodes are selected");
                    key(Qt.Key_Z, Qt.ControlModifier);
                } },
                { d: 200, f: function () { shell.eq(nodeCount(), 8, "undo removes the paste in one step"); } },

                // ---- save and verify on disk --------------------------------------------------------------------
                { d: 250, f: function () { clickItem(gv.saveButton); } },
                { wait: function () { return !XEdit.saving && !XEdit.dirty; }, label: "saved" },
                { d: 200, f: function () {
                    XCmd.cli(["get", "Наушники"], function (r) { win.saved = r; }, function (m) { win.saved = { error: m }; });
                } },
                { wait: function () { return win.saved !== null; }, label: "get after save" },
                { d: 100, f: function () {
                    const s = win.saved, n3 = s.nodes.filter(n => n.id === "n3")[0];
                    shell.eq(n3.props.percent, 55, "the saved file has the edited literal");
                    shell.ok(s.nodes.some(n => n.type === "convert.to_int@1"), "and the converter node");
                    shell.eq(s.approved_capabilities.slice().sort(), ["audio.control", "media.control"], "approved rights are untouched by the editor");
                } },

                // ---- unsaved-changes prompt ---------------------------------------------------------------------
                { d: 200, f: function () { const n = vnode("n5"); dragWorld(Qt.point(n.x + 90, n.y + 12), Qt.point(n.x + 90, n.y + 62)); } },
                { d: 200, f: function () { shell.ok(XEdit.dirty, "edit again"); XCmd.leaveEditor(); } },
                { d: 250, f: function () {
                    shell.ok(XCmd.dialog !== null && XCmd.dialog.kind === "unsaved", "leaving with changes asks what to do");
                    XCmd.dialog = null;
                    XCmd.leaveEditor();
                } },
                { d: 200, f: function () {
                    XCmd.dialog = null;
                    XCmd.stopEdit();
                    XCmd.screen = "list";
                } },

                // ---- E3: type mismatch with converter fix-it ----------------------------------------------------
                { d: 700, f: function () { XCmd.openEditor(shell.refByName("Яркость вечером")); } },
                { wait: function () { return XCmd.editing && XEdit.view !== null; }, label: "mismatch command in the editor" },
                { wait: function () { return !XEdit.validating && XEdit.report !== null && XEdit.errors > 0; }, label: "validation finds the mismatch" },
                { d: 300, f: function () {
                    cv.zoom = 1; cv.panX = 40; cv.panY = 40;
                    shell.eq(XEdit.report.errors[0].code, "type_mismatch", "the engine reports a type mismatch");
                    shell.ok(XEdit.report.errors[0].fix && XEdit.report.errors[0].fix.label.indexOf("Текст") >= 0, "with a converter fix-it");
                    const n = vnode("m3");
                    click(Qt.point(n.x + 60, n.y + 12));
                } },
                { d: 300, f: function () {
                    shell.ok(gv.bubbleItem.visible, "selecting the node shows the problem bubble");
                    gv.issuesOpen = true;
                } },
                { d: 500, f: function () { shell.snapshot("E3_type_error", null); } },
                { d: 500, f: function () { clickItem(gv.bubbleItem.fixButton); } },
                { wait: function () { return !XEdit.validating && XEdit.report !== null && XEdit.errors === 0 && XEdit.command.nodes.length === 4; }, label: "the fix clears the error" },
                { d: 100, f: function () { shell.ok(true, "the converter fix-it cleared the type error"); } },
                { d: 200, f: function () { XEdit.undo(); } },
                { wait: function () { return !XEdit.validating && XEdit.errors === 1; }, label: "undo brings the error back" },
                { d: 100, f: function () { XEdit.save(); } },
                { wait: function () { return !XEdit.saving; }, label: "save with errors is allowed" },
                { d: 100, f: function () { shell.ok(XEdit.saveError === "", "a command with errors can still be saved"); XCmd.stopEdit(); XCmd.screen = "list"; } },

                // ---- E4: enabling an unapproved automation shows the rights prompt -----------------------------
                { d: 800, f: function () { XCmd.filter = "auto"; XCmd.select(shell.refByName("Ночной режим")); } },
                { wait: function () { return XCmd.graph !== null && XCmd.selected !== null; }, label: "unapproved command selected" },
                { d: 300, f: function () { XCmd.setEnabled(XCmd.selectedRef, true); } },
                { d: 400, f: function () {
                    shell.ok(XCmd.dialog !== null && XCmd.dialog.kind === "permission", "enabling an unapproved command asks for the rights first");
                    shell.eq(XCmd.dialog.caps.map(c => c.id), ["screen.control"], "the prompt lists the rights from the schema");
                } },
                { d: 400, f: function () { shell.snapshot("E4_permission", null); } },
                { d: 500, f: function () { XCmd.approveAndEnable(XCmd.selectedRef); } },
                { wait: function () { const c = XCmd.find(XCmd.selectedRef); return XCmd.dialog === null && c !== null && c.enabled && c.approved; }, label: "approved and enabled" },
                { d: 100, f: function () { shell.ok(true, "«Разрешить и включить» approves and enables the command"); } },

                // ---- management: create (empty and from an example), rename, duplicate, delete, restore ------------
                { d: 300, f: function () { XCmd.filter = "all"; XCmd.dialog = { kind: "new" }; } },
                { d: 400, f: function () { typeText("Test"); tc.keyClick(Qt.Key_Return); } },
                { wait: function () { return XCmd.editing && XEdit.command !== null && XEdit.command.name === "Test"; }, label: "a new command opens in the editor" },
                { d: 300, f: function () {
                    shell.eq(XEdit.command.nodes.length, 1, "a new command starts with one «Вручную» node");
                    shell.eq(XEdit.command.nodes[0].type, "event.manual@1", "the starting node is the manual event");
                    XCmd.stopEdit(); XCmd.screen = "list";
                } },
                { d: 600, f: function () { XCmd.dialog = { kind: "new" }; } },
                { d: 300, f: function () { typeText("Test"); tc.keyClick(Qt.Key_Return); } },
                { d: 500, f: function () {
                    shell.ok(XCmd.dialog !== null && XCmd.dialog.error !== undefined && XCmd.dialog.error.indexOf("уже есть") >= 0, "a taken name is refused inside the dialog");
                    XCmd.dialog = null;
                    XCmd.duplicateCommand(shell.refByName("Test"));
                } },
                { wait: function () { return shell.refByName("Test (копия)") !== ""; }, label: "duplicate appears" },
                { d: 200, f: function () {
                    XCmd.renameCommand(shell.refByName("Test (копия)"), "Копия 2");
                } },
                { wait: function () { return shell.refByName("Копия 2") !== ""; }, label: "rename applied" },
                { d: 200, f: function () { XCmd.deleteCommand(shell.refByName("Копия 2")); } },
                { wait: function () { return shell.refByName("Копия 2") === "" && XCmd.trash.length === 1; }, label: "deleted into the trash" },
                { d: 300, f: function () {
                    shell.ok(XCmd.toastAction !== null, "the delete toast offers «Вернуть»");
                    XCmd.toastAction.run();
                } },
                { wait: function () { return shell.refByName("Копия 2") !== "" && XCmd.trash.length === 0; }, label: "restored from the trash" },
                { d: 100, f: function () { shell.ok(true, "the toast action restores the command"); } },
                // export + import round trip into a copy
                { d: 200, f: function () { XCmd.exportCommand(shell.refByName("Копия 2"), shell.scratch + "/export.scmd"); } },
                { d: 800, f: function () { XCmd.importFile(shell.scratch + "/export.scmd"); } },
                { wait: function () { return shell.refByName("Копия 2 (импорт)") !== ""; }, label: "imported copy" },
                { d: 200, f: function () {
                    const c = XCmd.find(shell.refByName("Копия 2 (импорт)"));
                    shell.ok(c !== null && !c.enabled, "an imported command arrives disabled");
                    shell.ok(true, "export → import round trip works");
                } }
            ]);
        }
        property var saved: null
    }
}
