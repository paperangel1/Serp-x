import QtQuick
import "../../"
import ".."
import "EditorLogic.js" as EL
import "DebugLogic.js" as DL

// Graph screen of the Commands window: header, canvas, zoom bar, minimap, node help panel. Read-only for examples and
// until «Изменить» is pressed; in edit mode the canvas draws XEdit.view and the header becomes the editor toolbar (C2):
// undo / redo / node search, enable switch, Проверить, Запустить, Сохранить; palette, value editor, problem bubble and the
// «Проблемы» panel live here too.
Item {
    id: gv
    readonly property var g: XCmd.graph
    readonly property bool editing: XCmd.editing && g !== null
    readonly property bool isExample: g !== null && !!g.file
    property bool issuesOpen: false
    readonly property alias canvasItem: canvas
    readonly property alias paletteItem: pal
    readonly property alias valueEditor: ve
    readonly property alias bubbleItem: bubble
    readonly property alias saveButton: saveBtn
    readonly property alias debugButton: debugBtn
    readonly property alias issuesButton: issuesBtn
    readonly property alias editButton: editBtn
    readonly property alias selectionBar: selBar
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    readonly property var selType: canvas.selNode !== "" && canvas.byId[canvas.selNode] ? canvas.byId[canvas.selNode].type : ""
    readonly property var help: selType !== "" ? (XCmd.helpFor(selType) || (g ? g.help[selType] : null) || null) : null
    readonly property bool helpOpen: canvas.selNode !== "" && !gv.editing
    readonly property int nErr: editing ? XEdit.errors : (g ? g.report.errors : 0)
    readonly property int nWarn: editing ? XEdit.warnings : (g ? g.report.warnings : 0)
    readonly property string cmdName: editing && XEdit.command ? XEdit.command.name : (g ? g.name : "")
    readonly property bool inFn: editing && XEdit.mode === "function"
    readonly property string crumb: inFn && XEdit.parentName !== "" ? XEdit.parentName : ""

    Rectangle { anchors.fill: parent; color: Qt.darker(ThemeBackend.base, 1.18) }

    GraphCanvas {
        id: canvas
        Component.onCompleted: XCmdTutorial.reg("canvas", this)
        x: 0; y: 56; width: parent.width - (gv.helpOpen ? helpPanel.width : 0); height: parent.height - 56 - (gv.debugOpen ? tracePanel.height : 0)
        graph: gv.editing ? XEdit.view : gv.g
        editable: gv.editing
        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        onEmptyActivated: { gv.issuesOpen = gv.issuesOpen && !gv.editing ? false : gv.issuesOpen; gv.forceActiveFocus(); }
        onPaletteRequested: (wx, wy, from) => gv.openPalette(wx, wy, from)
        onEditValue: (id, pin, item) => gv.editLiteral(id, pin, item)
        onEditComment: (id, field, item) => gv.editCommentField(id, field, item)
        onBreakpointToggled: (id) => XCmdDebug.toggleBp(XCmd.selectedRef, id)
    }

    // ---- debugger (stage 7): trace panel, hover values --------------------------------------------------------------
    readonly property bool debugOpen: XCmdDebug.panelOpen && g !== null && !isExample
    readonly property alias tracePanelItem: tracePanel
    function focusStep(id) {
        if (gv.editing) XEdit.selectNode(id, false); else canvas.selNode = id;
        canvas.revealNode(id);
    }
    TracePanel {
        id: tracePanel
        visible: gv.debugOpen
        x: 0; y: parent.height - height; width: parent.width; height: 270
        canvas: canvas
        z: 26
        onFocusNode: (id) => gv.focusStep(id)
    }
    readonly property var hoverDbg: XCmdDebug.active && canvas.hoverNode !== "" ? (XCmdDebug.ov.nodes[canvas.hoverNode] || null) : null
    readonly property var hoverRows: hoverDbg ? DL.tooltipRows(hoverDbg).slice(0, 7) : []
    Rectangle {
        id: hoverTip
        visible: gv.hoverRows.length > 0
        readonly property var n: canvas.hoverNode !== "" ? canvas.byId[canvas.hoverNode] : null
        readonly property point pos: n ? gv.clampTo(gv.toView(n.x, n.y + n.h).x, gv.toView(n.x, n.y + n.h).y + 8, width, height) : Qt.point(0, 0)
        x: pos.x; y: pos.y; z: 28
        width: 300; height: tipCol.implicitHeight + 24; radius: 10
        color: ThemeBackend.mantle; border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.2)
        Column {
            id: tipCol
            x: 12; y: 12; width: parent.width - 24; spacing: 5
            CT { size: 10; c: ThemeBackend.subtext0; width: parent.width
                 text: hoverTip.n ? hoverTip.n.title + (gv.hoverDbg && gv.hoverDbg.dur ? " · " + gv.hoverDbg.dur + " " + gv.t("cmd.debug.sec", "с") : "") : "" }
            Repeater {
                model: gv.hoverRows
                delegate: Row {
                    spacing: 8; width: tipCol.width
                    CT { width: 70; size: 10; c: modelData.k === "error" ? "#f38ba8" : ThemeBackend.subtext0
                         text: modelData.k === "error" ? gv.t("cmd.debug.tip_error", "ошибка") : (modelData.k === "plan" ? gv.t("cmd.debug.tip_plan", "сделал бы") : modelData.k) }
                    CT { width: tipCol.width - 78; size: 11; c: modelData.k === "error" ? "#f38ba8" : "#f5c2e7"; text: modelData.v; elide: Text.ElideRight }
                }
            }
        }
    }

    // ---- header ------------------------------------------------------------------------------------------------
    Rectangle {
        id: header
        x: 0; y: 0; width: parent.width; height: 56
        color: ThemeBackend.mantle
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Qt.alpha(ThemeBackend.text, 0.10) }
        Rectangle {
            x: 14; y: 10; width: 36; height: 36; radius: 10; color: backMa.containsMouse ? ThemeBackend.surface0 : "transparent"
            CT { anchors.centerIn: parent; icon: true; text: "\u{f004d}"; size: 18 }
            MouseArea { id: backMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { if (gv.editing) XCmd.leaveEditor(); else XCmd.closeGraph(); } }
        }
        CT { id: crumbText; visible: gv.crumb !== ""; x: 62; y: 11; text: gv.crumb + "  \u203a  "; size: 12; c: "#94e2d5"; width: Math.min(220, implicitWidth)
             MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.closeFunctionEditor() } }
        readonly property real nameX: 62 + (gv.crumb !== "" ? crumbText.width : 0)
        CT { id: nameText; x: header.nameX; y: 9; text: gv.cmdName; size: 14; font.bold: true; width: 420 }
        MouseArea {
            enabled: gv.editing
            x: header.nameX; y: 6; width: Math.min(420, nameMeasure.implicitWidth) + 8; height: 26
            cursorShape: Qt.IBeamCursor
            onClicked: { if (gv.inFn) XCmd.dialog = { kind: "fn_rename", ref: XEdit.command.id, name: XEdit.command.name };
                         else XCmd.dialog = { kind: "rename", ref: XEdit.command.id, name: XEdit.command.name }; }
        }
        CT { x: 62; y: 31; size: 10; c: ThemeBackend.subtext0
             text: !gv.editing ? (gv.isExample ? gv.t("cmd.graph.subtitle_example", "Пример · только просмотр") : gv.t("cmd.graph.subtitle", "Команда · только просмотр"))
                               : (XEdit.saving ? gv.t("cmd.edit.saving", "Сохранение…") : (gv.inFn ? (XEdit.dirty ? gv.t("cmd.fn.dirty", "Функция · есть несохранённые изменения") : gv.t("cmd.fn.clean", "Функция · сохранена"))
                                  : (XEdit.dirty ? gv.t("cmd.edit.dirty", "Команда · есть несохранённые изменения") : gv.t("cmd.edit.clean", "Команда · сохранена")))) }
        CmdChip {
            id: kindChip
            visible: gv.g !== null
            x: header.nameX + Math.min(420, nameMeasure.implicitWidth) + 14; y: 11
            text: gv.inFn ? gv.t("cmd.fn.badge", "Функция") + (gv.nErr > 0 ? " · " + gv.t("cmd.check.n_errors_long", gv.nErr + " ош.", { n: gv.nErr }) : "")
                  : gv.g ? (gv.g.kind === "auto" ? gv.t("cmd.kind.auto_badge", "Автоматизация") : gv.t("cmd.kind.manual_badge", "Вручную"))
                         + (gv.nErr > 0 ? " · " + gv.t("cmd.check.n_errors_long", gv.nErr + " ош.", { n: gv.nErr }) : "") : ""
            tone: gv.nErr > 0 ? "#f38ba8" : (gv.inFn ? "#94e2d5" : (gv.g && gv.g.kind === "auto" ? "#f38ba8" : "#89b4fa"))
        }
        CmdChip {
            id: dbgChip
            visible: XCmdDebug.active && gv.debugOpen
            x: kindChip.x + kindChip.width + 8; y: 11
            text: gv.t("cmd.debug.badge", "Отладка") + " · " + XCmdDebug.ov.run
            tone: ThemeBackend.mauve
        }
        CT { id: nameMeasure; visible: false; text: gv.cmdName; size: 14; font.bold: true }

        Row {   // undo / redo / search (editor)
            visible: gv.editing
            x: kindChip.x + kindChip.width + 22 + (dbgChip.visible ? dbgChip.width + 8 : 0); y: 10; spacing: 6
            Repeater {
                model: [ { ic: "\u{f054c}", act: "undo" }, { ic: "\u{f044e}", act: "redo" }, { ic: "\u{f0349}", act: "search" } ]
                delegate: Rectangle {
                    width: 36; height: 36; radius: 10
                    readonly property bool on: modelData.act === "undo" ? XEdit.canUndo : (modelData.act === "redo" ? XEdit.canRedo : true)
                    opacity: on ? 1 : 0.4
                    color: ma.containsMouse && on ? ThemeBackend.surface0 : "transparent"
                    CT { anchors.centerIn: parent; icon: true; text: modelData.ic; size: 18 }
                    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (!parent.on) return; if (modelData.act === "undo") XEdit.undo(); else if (modelData.act === "redo") XEdit.redo(); else gv.openPaletteCentered(); } }
                }
            }
        }

        Row {
            anchors.right: parent.right; anchors.rightMargin: 16; y: 12; spacing: 10
            Row {   // enabled switch (automations)
                visible: gv.g !== null && gv.g.kind === "auto" && !gv.isExample && !gv.inFn
                anchors.verticalCenter: parent.verticalCenter; spacing: 8
                CT { anchors.verticalCenter: parent.verticalCenter; size: 11; c: ThemeBackend.subtext1; text: gv.g && gv.g.enabled ? gv.t("cmd.edit.enabled", "Включена") : gv.t("cmd.edit.disabled", "Выключена") }
                Rectangle {
                    width: 40; height: 22; radius: 11; anchors.verticalCenter: parent.verticalCenter
                    color: gv.g && gv.g.enabled ? ThemeBackend.mauve : ThemeBackend.surface0
                    Rectangle { x: gv.g && gv.g.enabled ? 20 : 2; y: 2; width: 18; height: 18; radius: 9; color: gv.g && gv.g.enabled ? ThemeBackend.crust : ThemeBackend.subtext0
                                Behavior on x { NumberAnimation { duration: 120 } } }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.setEnabled(XCmd.selectedRef, !(gv.g && gv.g.enabled)) }
                }
            }
            CmdBtn {
                id: issuesBtn
                visible: gv.g !== null
                icon: gv.nErr > 0 ? "\u{f0026}" : "\u{f012c}"
                text: gv.nErr > 0 ? gv.t("cmd.check.errors", "Ошибок: " + gv.nErr, { n: gv.nErr }) : (gv.nWarn > 0 ? gv.t("cmd.check.warnings", "Замечаний: " + gv.nWarn, { n: gv.nWarn }) : gv.t("cmd.check.ok", "Проверка: ок"))
                kind: "ghost"
                onClicked: { gv.issuesOpen = !gv.issuesOpen; if (gv.editing) XEdit.validateNow(); }
            }
            CmdBtn {
                visible: gv.g !== null && !gv.isExample && !gv.inFn
                icon: "\u{f040a}"; text: gv.t("cmd.run.now", "Запустить")
                enabled: XCmd.selected !== null && !XCmd.selected.example && !XEdit.saving
                onClicked: { if (gv.editing && XEdit.dirty) XEdit.save(function () { XCmd.run(XCmd.selectedRef); }); else XCmd.run(XCmd.selectedRef); }
            }
            CmdBtn {
                id: debugBtn
                Component.onCompleted: XCmdTutorial.reg("debug_button", this)
                visible: gv.g !== null && !gv.isExample && !gv.inFn
                icon: "\u{f00e4}"; text: gv.t("cmd.debug.button", "Отладка"); kind: XCmdDebug.panelOpen ? "primary" : "ghost"
                onClicked: { XCmdDebug.panelOpen = !XCmdDebug.panelOpen; if (XCmdDebug.panelOpen) XCmdDebug.refreshLog(XCmd.selectedRef); }
            }
            CmdBtn {
                id: editBtn
                visible: gv.g !== null && !gv.editing && !gv.isExample && !gv.inFn
                kind: "primary"; icon: "\u{f03eb}"; text: gv.t("cmd.edit.start", "Изменить")
                onClicked: XCmd.startEdit()
            }
            CmdBtn {
                visible: gv.isExample
                kind: "primary"; icon: "\u{f0415}"; text: gv.t("cmd.example.copy", "Добавить в мои команды")
                onClicked: XCmd.copyExample(XCmd.selectedRef)
            }
            CmdBtn {
                id: saveBtn
                Component.onCompleted: XCmdTutorial.reg("save_button", this)
                visible: gv.editing
                kind: "primary"; icon: "\u{f0193}"; text: gv.t("cmd.edit.save", "Сохранить")
                enabled: !XEdit.saving && (XEdit.dirty || XEdit.saveError !== "")
                onClicked: XEdit.save()
            }
        }
    }

    CT {
        visible: g === null
        anchors.centerIn: canvas
        text: XCmd.graphLoading ? gv.t("cmd.loading", "Загрузка…") : gv.t("cmd.graph.failed", "Не удалось открыть команду")
        size: 13; c: ThemeBackend.subtext0
    }

    // ---- selection bar (C5): collapse the selected nodes into one function node; expand / edit a call node ----------------
    Rectangle {
        id: selBar
        visible: gv.editing && XEdit.selNodeCount > 0 && !pal.shown && !ve.shown
        x: Math.max(8, (canvas.width - width) / 2); y: 66
        width: selRow.implicitWidth + 24; height: 40; radius: 10; z: 25
        color: Qt.alpha(ThemeBackend.mantle, 0.97); border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.55)
        Row {
            id: selRow
            x: 12; anchors.verticalCenter: parent.verticalCenter; spacing: 8
            CT { anchors.verticalCenter: parent.verticalCenter; size: 11; c: ThemeBackend.subtext1
                 text: XEdit.selFnType !== "" ? gv.t("cmd.fn.selected_call", "Выбрана функция") : gv.t("cmd.fn.selected_n", "Выбрано узлов: " + XEdit.selNodeCount, { n: XEdit.selNodeCount }) }
            CmdBtn { visible: XEdit.selFnType === ""; h: 28; padX: 10; kind: "primary"; icon: "\u{f03d7}"; text: gv.t("cmd.fn.collapse", "Свернуть в узел") + "  Ctrl+G"; onClicked: XCmd.collapseSelection() }
            CmdBtn { visible: XEdit.selFnType !== ""; h: 28; padX: 10; kind: "primary"; icon: "\u{f03eb}"; text: gv.t("cmd.fn.edit", "Редактировать функцию"); onClicked: XCmd.editSelectedFunction() }
            CmdBtn { visible: XEdit.selFnType !== ""; h: 28; padX: 10; kind: "ghost"; icon: "\u{f03d6}"; text: gv.t("cmd.fn.expand", "Развернуть") + "  Ctrl+Shift+G"; onClicked: XCmd.expandSelected() }
            CmdBtn { h: 28; padX: 10; kind: "ghost"; text: gv.t("cmd.edit.copy", "Копировать"); onClicked: XEdit.copySel() }
            CmdBtn { h: 28; padX: 10; kind: "ghost"; text: gv.t("cmd.edit.delete", "Удалить"); onClicked: XEdit.deleteSelection() }
        }
    }

    // ---- zoom bar ----------------------------------------------------------------------------------------------
    Rectangle {
        x: 16; y: canvas.y + canvas.height - 52; width: 160; height: 36; radius: 10
        color: Qt.alpha(ThemeBackend.mantle, 0.96); border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.12)
        z: 20
        Rectangle { x: 4; y: 4; width: 28; height: 28; radius: 7; color: zmMa.containsMouse ? ThemeBackend.surface0 : "transparent"
            CT { anchors.centerIn: parent; icon: true; text: "\u{f0374}"; size: 16 }
            MouseArea { id: zmMa; anchors.fill: parent; hoverEnabled: true; onClicked: canvas.zoomAt(1 / 1.25, canvas.width / 2, canvas.height / 2) } }
        CT { x: 36; y: 0; width: 56; height: parent.height; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; text: Math.round(canvas.zoom * 100) + "%"; size: 11 }
        Rectangle { x: 94; y: 4; width: 28; height: 28; radius: 7; color: zpMa.containsMouse ? ThemeBackend.surface0 : "transparent"
            CT { anchors.centerIn: parent; icon: true; text: "\u{f0415}"; size: 16 }
            MouseArea { id: zpMa; anchors.fill: parent; hoverEnabled: true; onClicked: canvas.zoomAt(1.25, canvas.width / 2, canvas.height / 2) } }
        Rectangle { x: 126; y: 4; width: 28; height: 28; radius: 7; color: ftMa.containsMouse ? ThemeBackend.surface0 : "transparent"
            CT { anchors.centerIn: parent; icon: true; text: "\u{f0293}"; size: 15 }
            MouseArea { id: ftMa; anchors.fill: parent; hoverEnabled: true; onClicked: { canvas._userMoved = false; canvas.fit(); } } }
    }

    MiniMap {
        canvas: canvas
        visible: gv.g !== null && gv.g.nodes.length > 0
        width: 200; height: 120
        x: canvas.width - width - 16; y: canvas.y + canvas.height - height - 16
        z: 20
    }

    // ---- problems (editor) ---------------------------------------------------------------------------------------
    IssuesPanel {
        id: issues
        visible: gv.issuesOpen && gv.editing
        x: canvas.width - width - 16; y: canvas.y + canvas.height - 120 - 28 - height
        onJumpTo: (id) => { XEdit.selectNode(id, false); canvas.revealNode(id); gv.forceActiveFocus(); }
    }
    // viewer: plain list of messages as before
    Rectangle {
        visible: gv.issuesOpen && gv.g !== null && !gv.editing
        x: parent.width - width - (gv.helpOpen ? helpPanel.width : 0) - 16; y: 64
        width: 420; height: Math.min(300, issuesCol.implicitHeight + 28); radius: 12
        color: ThemeBackend.mantle; border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.14)
        z: 30
        Column {
            id: issuesCol
            x: 14; y: 14; width: parent.width - 28; spacing: 8
            CT { text: gv.t("cmd.check.title", "Проверка команды"); size: 12; font.bold: true }
            CT { visible: gv.g !== null && gv.g.report.items.length === 0; text: gv.t("cmd.check.clean", "Ошибок и замечаний нет"); size: 11; c: "#a6e3a1" }
            Repeater {
                model: gv.g ? gv.g.report.items : []
                delegate: CT { width: issuesCol.width; text: "• " + modelData.message; size: 10; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone }
            }
        }
    }

    // ---- problem bubble: a refused wire, or the first error of the selected node ---------------------------------
    readonly property var nodeIssue: {
        if (!editing || canvas.selNode === "") return null;
        const l = XEdit.issues.list;
        for (let i = 0; i < l.length; i++) if (l[i].level === "error" && l[i].node === canvas.selNode && l[i].pin) return l[i];
        return null;
    }
    function toView(wx, wy) { const p = canvas.mapToItem(gv, canvas.panX + wx * canvas.zoom, canvas.panY + wy * canvas.zoom); return p; }
    function clampTo(px, py, w, h) { return Qt.point(Math.max(8, Math.min(gv.width - w - 8, px)), Math.max(64, Math.min(gv.height - h - 8, py))); }
    ProblemBubble {
        id: bubble
        readonly property var rej: canvas.rejected
        visible: gv.editing && (rej !== null || gv.nodeIssue !== null)
        title: rej ? gv.t("cmd.edit.cant_connect", "Нельзя соединить") : (gv.nodeIssue ? gv.issueTitle(gv.nodeIssue) : "")
        message: rej ? rej.text : (gv.nodeIssue ? gv.nodeIssue.message : "")
        fixLabel: rej ? (rej.fix ? rej.fix.label : "") : (gv.nodeIssue && gv.nodeIssue.fix ? gv.nodeIssue.fix.label : "")
        canDisconnect: !rej && gv.nodeIssue !== null && gv.nodeIssue.code === "type_mismatch"
        footer: !rej && gv.nodeIssue ? gv.t("cmd.edit.issue_n", "Ошибка 1 из " + XEdit.errors, { i: 1, n: XEdit.errors }) : ""
        readonly property point pos: {
            if (rej) return gv.clampTo(gv.toView(rej.tx, rej.ty).x + 16, gv.toView(rej.tx, rej.ty).y + 16, width, height);
            const n = gv.nodeIssue ? canvas.byId[gv.nodeIssue.node] : null;
            if (!n) return Qt.point(0, 0);
            const p = gv.toView(n.x, n.y + n.h);
            return gv.clampTo(p.x, p.y + 12 * canvas.zoom + 8, width, height);
        }
        x: pos.x; y: pos.y
        onFixClicked: {
            if (rej) { XEdit.connectWithConverter(rej.from, rej.to, { kind: "insert_converter", node_type: rej.fix.node_type }); canvas.rejected = null; }
            else XEdit.applyFix(gv.nodeIssue);
        }
        onDisconnectClicked: {
            const ws = XEdit.command.wires;
            for (let i = 0; i < ws.length; i++) if (ws[i].to[0] === gv.nodeIssue.node && ws[i].to[1] === gv.nodeIssue.pin) { XEdit.disconnectKey(EL.wireKey(ws[i])); break; }
        }
        onDismissed: { if (rej) canvas.rejected = null; else XEdit.clearSel(); }
    }
    function issueTitle(it) {
        const m = { type_mismatch: t("cmd.err.type_mismatch", "Не тот тип данных"), missing_input: t("cmd.err.missing_input", "Не заполнен вход"),
                    bad_literal: t("cmd.err.bad_literal", "Неверное значение"), multi_input: t("cmd.err.multi_input", "Лишний провод"),
                    exec_cycle: t("cmd.err.exec_cycle", "Цикл выполнения"), data_cycle: t("cmd.err.data_cycle", "Цикл данных") };
        return m[it.code] || t("cmd.err.generic", "Проблема в узле");
    }

    NodeHelp {
        id: helpPanel
        x: parent.width - (gv.helpOpen ? width : 0); y: 56; width: 390; height: parent.height - 56
        visible: x < gv.width
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        help: gv.help
        node: canvas.selNode !== "" ? canvas.byId[canvas.selNode] : null
        onCloseRequested: canvas.selNode = ""
    }

    // ---- palette / value editor ---------------------------------------------------------------------------------
    property point palAnchor: Qt.point(0, 0)
    NodePalette {
        id: pal
        x: Math.max(8, Math.min(gv.width - width - 8, gv.palAnchor.x))
        y: Math.max(64, Math.min(gv.height - height - 8, gv.palAnchor.y))
        onChosen: (entry, pinId, wx, wy) => {
            const from = pal.fromPin;
            const px = from && !from.out ? wx - 300 : wx;
            const id = XEdit.addNodeAt(entry, px, wy, from, pinId);
            canvas.revealNode(id);
            gv.forceActiveFocus();
        }
        onCommentChosen: (wx, wy) => { XEdit.addCommentAt(wx, wy); gv.forceActiveFocus(); }
        onClosed: gv.forceActiveFocus()
    }
    function openPalette(wx, wy, from) {
        if (!editing) return;
        ve.shown = false;
        palAnchor = Qt.point(toView(wx, wy).x + 10, toView(wx, wy).y + 10);
        pal.openAt(wx, wy, from);
    }
    function openPaletteCentered() { openPalette(canvas.cursor.x !== 0 || canvas.cursor.y !== 0 ? canvas.cursor.x : (canvas.width / 2 - canvas.panX) / canvas.zoom,
                                                   canvas.cursor.x !== 0 || canvas.cursor.y !== 0 ? canvas.cursor.y : (canvas.height / 2 - canvas.panY) / canvas.zoom, null); }

    ValueEditor {
        id: ve
        property var apply: null
        onCommitted: (value, clear) => { if (apply) apply(value, clear); gv.forceActiveFocus(); }
        onCancelled: gv.forceActiveFocus()
    }
    function placeEditor(item) {
        const p = item.mapToItem(gv, 0, item.height + 6);
        const q = clampTo(p.x, p.y, ve.width, ve.height);
        ve.x = q.x; ve.y = q.y;
    }
    function editLiteral(nodeId, pinId, item) {
        const n = EL.findNode(XEdit.command, nodeId), e = n ? XCmd.catalog[n.type] : null, pin = e ? EL.pinOf(e, pinId, true) : null;
        if (!pin) return;
        pal.shown = false;
        const props = n.props || ({});
        const cur = props[pinId] !== undefined ? props[pinId] : (pin.default !== undefined ? pin.default : undefined);
        const full = pin.full;
        if (full === "bool") { XEdit.setLiteral(nodeId, pinId, !cur); return; }
        let kind = "text", opts = ({});
        if (pin.choices) { kind = "choice"; opts.choices = pin.choices; opts.labels = pin.choice_labels || ({}); }
        else if (full === "int") { kind = "int"; opts.min = pin.min; opts.max = pin.max; }
        else if (full === "float" || full === "duration") { kind = "float"; opts.min = pin.min; opts.max = pin.max; }
        else if (full === "color") kind = "color";
        else if (full === "time") kind = "time";
        else if (EL.listInner(full) !== null) { kind = "list"; const inner = EL.listInner(full); opts.itemType = (inner === "int" || inner === "float") ? inner : "text"; }
        ve.apply = function (value, clear) { XEdit.setLiteral(nodeId, pinId, clear ? undefined : value); };
        ve.openWith(kind, pin.n, EL.typeName(full, "ru"), cur, opts);
        placeEditor(item);
    }
    function editCommentField(id, field, item) {
        if (typeof field === "object") { XEdit.editComment(id, field); return; }
        const cl = XEdit.command.comments || [];
        let cur = "";
        for (let i = 0; i < cl.length; i++) if (cl[i].id === id) cur = cl[i][field] || "";
        pal.shown = false;
        ve.apply = function (value) { const f = ({}); f[field] = value; XEdit.editComment(id, f); };
        ve.openWith(field === "title" ? "comment_title" : "comment_text", field === "title" ? t("cmd.edit.comment_title", "Заголовок комментария") : t("cmd.edit.comment_text", "Текст комментария"), "", cur, ({}));
        placeEditor(item);
    }

    // ---- keyboard -----------------------------------------------------------------------------------------------
    Keys.onPressed: (e) => {
        const ctrl = (e.modifiers & Qt.ControlModifier) !== 0, shift = (e.modifiers & Qt.ShiftModifier) !== 0;
        if (e.key === Qt.Key_Escape) {
            if (pal.shown) pal.close();
            else if (ve.shown) { ve.shown = false; }
            else if (canvas.wireDrag) canvas.wireCancel();
            else if (canvas.rejected) canvas.rejected = null;
            else if (gv.editing && XEdit.selCount > 0) XEdit.clearSel();
            else if (gv.editing) XCmd.leaveEditor();
            else if (canvas.selNode !== "") canvas.selNode = "";
            else XCmd.closeGraph();
            e.accepted = true;
            return;
        }
        if (gv.editing) {
            if (e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) { XEdit.deleteSelection(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_Z) { if (shift) XEdit.redo(); else XEdit.undo(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_Y) { XEdit.redo(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_C) { XEdit.copySel(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_V) { XEdit.pasteAt(40, 40); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_D) { XEdit.duplicateSel(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_G) { if (shift) XCmd.expandSelected(); else XCmd.collapseSelection(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_A) { XEdit.selectAll(); e.accepted = true; return; }
            if (ctrl && e.key === Qt.Key_S) { XEdit.save(); e.accepted = true; return; }
            if (e.key === Qt.Key_Space) { gv.openPaletteCentered(); e.accepted = true; return; }
        }
        if (e.key === Qt.Key_F && !ctrl) { canvas._userMoved = false; canvas.fit(); e.accepted = true; }
        else if (e.key === Qt.Key_Plus || e.key === Qt.Key_Equal) { canvas.zoomAt(1.25, canvas.width / 2, canvas.height / 2); e.accepted = true; }
        else if (e.key === Qt.Key_Minus) { canvas.zoomAt(1 / 1.25, canvas.width / 2, canvas.height / 2); e.accepted = true; }
        else if (e.key === Qt.Key_0) { canvas._userMoved = false; canvas.fit(); e.accepted = true; }
    }
}
