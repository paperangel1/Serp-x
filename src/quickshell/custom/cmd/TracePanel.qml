import QtQuick
import "../../"
import ".."
import "DebugLogic.js" as DL

// «Ход выполнения» (C3) + run log (C6) + variable watch + runtime error panel. Bottom panel of the graph screen. All data
// comes from XCmdDebug (trace overlay state); a click on a step focuses its node on the canvas.
Rectangle {
    id: tp
    property var canvas: null
    signal focusNode(string id)
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    readonly property var ov: XCmdDebug.ov
    readonly property bool live: ov.live
    readonly property bool paused: ov.paused !== null
    function titleOf(id) { const n = canvas && canvas.byId ? canvas.byId[id] : null; return n ? n.title : id; }
    function statusText(s) {
        const m = { ok: t("cmd.debug.st_ok", "ок"), err: t("cmd.debug.st_err", "ошибка"), cancelled: t("cmd.debug.st_cancelled", "отменено"),
                    skipped: t("cmd.debug.st_skipped", "пропущено"), rolled_back: t("cmd.debug.st_rolled_back", "откат выполнен"),
                    invalid: t("cmd.debug.st_invalid", "не прошла проверку"), denied: t("cmd.debug.st_denied", "нет прав"), running: t("cmd.debug.st_running", "идёт") };
        return m[s] || s || "";
    }
    function statusTone(s) { return s === "ok" ? "#a6e3a1" : (s === "err" || s === "error" || s === "invalid" || s === "denied") ? "#f38ba8" : s === "running" ? ThemeBackend.mauve : "#f9e2af"; }
    function dur(d) { return d === undefined || d === null ? "" : (d < 10 ? d.toFixed(2) : d.toFixed(1)) + " " + t("cmd.debug.sec", "с"); }

    color: ThemeBackend.mantle
    Rectangle { width: parent.width; height: 1; color: Qt.alpha(ThemeBackend.text, 0.10) }

    // ---- toolbar -----------------------------------------------------------------------------------------------
    Item {
        id: bar
        x: 0; y: 1; width: parent.width; height: 48
        CT { x: 20; y: 15; icon: true; text: "\u{f04b5}"; size: 16; c: ThemeBackend.mauve }
        CT { id: ttl; x: 46; y: 15; text: tp.t("cmd.debug.title", "Ход выполнения"); size: 13; font.bold: true }
        Row {
            x: 46 + ttl.implicitWidth + 14; y: 15; spacing: 6
            CmdChip {
                visible: tp.ov.run !== ""
                text: (tp.ov.rehearse ? tp.t("cmd.debug.mode_rehearse", "репетиция") : tp.t("cmd.debug.mode_live", "запуск")) + " " + tp.ov.run
                tone: ThemeBackend.mauve
            }
            CmdChip {
                id: stChip
                visible: tp.ov.run !== ""
                text: tp.live ? (tp.paused ? tp.t("cmd.debug.paused", "пауза") : tp.t("cmd.debug.running", "идёт") + " " + tp.dur(tp.ov.t)) : tp.statusText(tp.ov.status) + (tp.ov.dur ? " · " + tp.dur(tp.ov.dur) : "")
                tone: tp.live ? (tp.paused ? "#f9e2af" : ThemeBackend.mauve) : tp.statusTone(tp.ov.status)
            }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: 16; y: 8; spacing: 8
            CmdBtn { id: runBtn; h: 32; icon: "\u{f040a}"; text: tp.t("cmd.debug.run_live", "Запуск"); enabled: XCmdDebug.busy === ""; onClicked: XCmdDebug.start("live", false) }
            CmdBtn { id: rehBtn; h: 32; icon: "\u{f0d60}"; text: tp.t("cmd.debug.rehearse", "Репетиция"); enabled: XCmdDebug.busy === ""; onClicked: XCmdDebug.start("rehearse", false) }
            CmdBtn { id: stepBtn; h: 32; icon: "\u{f04e7}"; text: tp.t("cmd.debug.step", "По шагам"); enabled: XCmdDebug.busy === "" || tp.paused; onClicked: XCmdDebug.step() }
            CmdBtn { id: contBtn; h: 32; icon: "\u{f040a}"; kind: "ghost"; text: tp.t("cmd.debug.cont", "Продолжить"); enabled: tp.paused; onClicked: XCmdDebug.cont() }
            CmdBtn { id: stopBtn; h: 32; kind: "danger"; icon: "\u{f04db}"; text: tp.t("cmd.debug.stop", "Остановить"); enabled: tp.live; onClicked: XCmdDebug.stop() }
            CmdBtn { h: 32; kind: "ghost"; icon: "\u{f0156}"; onClicked: XCmdDebug.panelOpen = false }
        }
    }
    readonly property alias runButton: runBtn
    readonly property alias rehearseButton: rehBtn
    readonly property alias stepButton: stepBtn
    readonly property alias continueButton: contBtn
    readonly property alias stopButton: stopBtn

    // ---- tabs + options ------------------------------------------------------------------------------------------
    Row {
        id: tabs
        x: 20; y: 52; spacing: 6
        Repeater {
            model: [ { k: "steps", ru: "Шаги", n: tp.ov.steps.length }, { k: "log", ru: "Журнал запусков", n: XCmdDebug.runs.length }, { k: "vars", ru: "Переменные", n: Object.keys(tp.ov.vars).length } ]
            delegate: Rectangle {
                height: 26; width: tl.implicitWidth + 22; radius: 8
                color: XCmdDebug.tab === modelData.k ? ThemeBackend.mauve : ThemeBackend.surface0
                CT { id: tl; anchors.centerIn: parent; size: 11; c: XCmdDebug.tab === modelData.k ? ThemeBackend.crust : ThemeBackend.text
                     text: tp.t("cmd.debug.tab_" + modelData.k, modelData.ru) + (modelData.n > 0 ? " · " + modelData.n : "") }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmdDebug.tab = modelData.k }
            }
        }
    }
    Row {
        anchors.right: parent.right; anchors.rightMargin: 20; y: 52; spacing: 10
        Rectangle {
            visible: XCmdDebug.tab === "steps"
            height: 26; width: oe.implicitWidth + 22; radius: 8; color: XCmdDebug.errorsOnly ? Qt.alpha("#f38ba8", 0.25) : ThemeBackend.surface0
            CT { id: oe; anchors.centerIn: parent; size: 11; text: tp.t("cmd.debug.only_errors", "Только ошибки"); c: XCmdDebug.errorsOnly ? "#f38ba8" : ThemeBackend.text }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmdDebug.errorsOnly = !XCmdDebug.errorsOnly }
        }
        CT { anchors.verticalCenter: parent.verticalCenter; size: 10; c: ThemeBackend.subtext0; text: tp.t("cmd.debug.fake_answer", "Ответ на вопросы") }
        Rectangle {
            width: 110; height: 26; radius: 8; color: ThemeBackend.surface0; clip: true
            TextInput { id: faIn; x: 8; width: parent.width - 16; anchors.verticalCenter: parent.verticalCenter; color: ThemeBackend.text; font.pixelSize: XUi.cmdFont(11); font.family: ThemeBackend.fontFamily
                        text: XCmdDebug.fakeAnswer; onTextEdited: XCmdDebug.fakeAnswer = text; selectByMouse: true }
        }
        CT { anchors.verticalCenter: parent.verticalCenter; size: 10; c: ThemeBackend.subtext0; text: tp.t("cmd.debug.sim_event", "Событие") }
        Rectangle {
            width: 120; height: 26; radius: 8; color: ThemeBackend.surface0; clip: true
            TextInput { id: seIn; x: 8; width: parent.width - 16; anchors.verticalCenter: parent.verticalCenter; color: ThemeBackend.text; font.pixelSize: XUi.cmdFont(11); font.family: ThemeBackend.fontFamily
                        text: XCmdDebug.simEvent; onTextEdited: XCmdDebug.simEvent = text; selectByMouse: true }
        }
    }

    // ---- runtime error panel ---------------------------------------------------------------------------------------
    Rectangle {
        id: errBox
        visible: tp.ov.error !== null || tp.ov.status === "err" && tp.ov.message !== "" || XCmdDebug.note !== ""
        readonly property string msg: tp.ov.error ? tp.ov.error.message : (tp.ov.message !== "" ? tp.ov.message : XCmdDebug.note)
        readonly property string nodeId: tp.ov.error ? tp.ov.error.node : (tp.ov.failed || "")
        x: 20; y: 84; width: parent.width - 40; height: visible ? 52 : 0; radius: 8
        color: Qt.alpha("#f38ba8", 0.10); border.width: 1; border.color: Qt.alpha("#f38ba8", 0.45)
        CT { x: 14; y: 8; width: parent.width - 260; size: 11; font.bold: true; c: "#f38ba8"
             text: errBox.nodeId !== "" ? tp.t("cmd.debug.err_title", "Ошибка в узле «" + tp.titleOf(errBox.nodeId) + "»", { name: tp.titleOf(errBox.nodeId) }) : tp.t("cmd.debug.err_run", "Запуск не удался") }
        CT { id: errMsg; x: 14; y: 28; width: parent.width - 260; size: 10; c: ThemeBackend.subtext1; text: errBox.msg + (tp.ov.error && tp.ov.error.fn ? "  (" + tp.t("cmd.debug.err_fn", "в функции") + " " + tp.ov.error.fn.join(" → ") + ")" : "") }
        CmdBtn { id: showBtn; visible: errBox.nodeId !== ""; x: parent.width - width - 12; y: 10; h: 30; padX: 10; kind: "ghost"; text: tp.t("cmd.debug.show_node", "Показать узел"); onClicked: tp.focusNode(errBox.nodeId) }
    }
    readonly property alias errorBox: errBox
    readonly property real listY: 84 + (errBox.visible ? 60 : 0)

    // ---- steps -------------------------------------------------------------------------------------------------------
    ListView {
        id: stepList
        visible: XCmdDebug.tab === "steps"
        x: 20; y: tp.listY; width: parent.width - 40; height: parent.height - tp.listY - 8
        clip: true; spacing: 4; boundsBehavior: Flickable.StopAtBounds
        model: XCmdDebug.steps
        onCountChanged: if (tp.live) Qt.callLater(positionViewAtEnd)
        delegate: Rectangle {
            width: stepList.width; height: 36; radius: 8
            color: tp.paused && tp.ov.paused.node === modelData.node && index === stepList.count - 1 ? Qt.alpha(ThemeBackend.mauve, 0.14) : (ma.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.8) : Qt.alpha(ThemeBackend.base, 0.8))
            readonly property color tone: modelData.status === "ok" ? "#a6e3a1" : modelData.status === "error" ? "#f38ba8" : modelData.status === "running" ? ThemeBackend.mauve : "#6c7086"
            Rectangle { x: 12; y: 12; width: 12; height: 12; radius: 6; color: parent.tone }
            CT { x: 36; y: 10; width: 66; size: 10; c: ThemeBackend.subtext0; text: modelData.status === "skipped" ? "—" : DL.stepTime(modelData.t) }
            CT { x: 108; y: 10; width: 220; size: 11; font.bold: true
                 text: tp.titleOf(modelData.node) + (modelData.iter && modelData.iter.length ? "  #" + modelData.iter.map(i => i + 1).join(".") : "") }
            CT { x: 340; y: 11; width: parent.width - 360; size: 10; c: modelData.status === "error" ? "#f38ba8" : ThemeBackend.subtext1
                 text: modelData.status === "skipped" ? tp.t("cmd.debug.skipped_row", "пропущен: ветка не выбрана")
                       : modelData.error ? modelData.error
                       : (modelData.plan ? "→ " + modelData.plan + (modelData.would_undo ? "; " + modelData.would_undo : "") : modelData.summary)
                         + (modelData.ff ? " · " + tp.t("cmd.debug.fast_forward", "ожидание " + modelData.ff + " с пропущено", { s: modelData.ff }) : "")
                         + (modelData.dur ? " · " + tp.dur(modelData.dur) : "") }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tp.focusNode(modelData.node) }
        }
        CT { visible: stepList.count === 0; anchors.centerIn: parent; size: 11; c: ThemeBackend.subtext0
             text: tp.t("cmd.debug.empty_steps", "Запустите команду или репетицию, чтобы увидеть ход выполнения") }
    }

    // ---- run log -------------------------------------------------------------------------------------------------------
    ListView {
        id: logList
        visible: XCmdDebug.tab === "log"
        x: 20; y: tp.listY; width: parent.width - 40; height: parent.height - tp.listY - 8
        clip: true; spacing: 4; boundsBehavior: Flickable.StopAtBounds
        model: XCmdDebug.runs
        delegate: Rectangle {
            width: logList.width; height: 36; radius: 8
            color: lma.containsMouse && modelData.trace ? Qt.alpha(ThemeBackend.surface0, 0.8) : Qt.alpha(ThemeBackend.base, 0.8)
            border.width: modelData.status === "err" ? 1 : 0; border.color: Qt.alpha("#f38ba8", 0.4)
            CT { x: 14; y: 10; width: 120; size: 10; c: ThemeBackend.subtext0; text: XCmd.when(modelData.ts) }
            CmdChip { x: 140; y: 9; text: tp.statusText(modelData.status); tone: tp.statusTone(modelData.status) }
            CT { x: 300; y: 10; width: 180; size: 10; c: ThemeBackend.subtext1; text: (modelData.dry_run ? tp.t("cmd.debug.mode_rehearse", "репетиция") + " · " : "") + (modelData.trigger || "") }
            CT { x: 490; y: 10; width: parent.width - 640; size: 10; c: modelData.status === "err" ? "#f38ba8" : ThemeBackend.subtext1; text: modelData.message || "" }
            CT { x: parent.width - 140; y: 10; width: 60; horizontalAlignment: Text.AlignRight; size: 10; c: ThemeBackend.subtext0; text: tp.dur(modelData.dur) }
            CT { x: parent.width - 70; y: 10; width: 60; size: 10; c: modelData.trace ? ThemeBackend.mauve : ThemeBackend.subtext0
                 text: modelData.trace ? tp.t("cmd.debug.open_trace", "трасса ›") : "" }
            MouseArea { id: lma; anchors.fill: parent; hoverEnabled: true; cursorShape: modelData.trace ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: { if (modelData.trace) XCmdDebug.loadRun(modelData.run); else XCmd.showToast(tp.t("cmd.debug.no_trace", "Для этого запуска трассы нет")); } }
        }
        CT { visible: logList.count === 0; anchors.centerIn: parent; size: 11; c: ThemeBackend.subtext0; text: tp.t("cmd.debug.empty_log", "Запусков этой команды пока нет") }
    }

    // ---- variables -----------------------------------------------------------------------------------------------------
    ListView {
        id: varList
        visible: XCmdDebug.tab === "vars"
        x: 20; y: tp.listY; width: parent.width - 40; height: parent.height - tp.listY - 8
        clip: true; spacing: 4; boundsBehavior: Flickable.StopAtBounds
        model: Object.keys(tp.ov.vars)
        delegate: Rectangle {
            width: varList.width; height: 32; radius: 8; color: Qt.alpha(ThemeBackend.base, 0.8)
            CT { x: 14; y: 8; width: 200; size: 11; font.bold: true; text: modelData }
            CT { x: 230; y: 9; width: parent.width - 250; size: 11; c: "#f5c2e7"; text: DL.valueText(tp.ov.vars[modelData]) }
        }
        CT { visible: varList.count === 0; anchors.centerIn: parent; size: 11; c: ThemeBackend.subtext0; text: tp.t("cmd.debug.empty_vars", "Переменные появятся, когда команда их изменит") }
    }
}
