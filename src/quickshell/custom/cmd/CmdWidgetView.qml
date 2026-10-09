import QtQuick
import "../../"
import ".."
import "LaunchLogic.js" as LL

// Content of the «Команды» desktop widget: pinned commands as buttons ("compact": a grid of buttons) or as rows with the
// last run ("detailed"). A click runs the command and the button shows running / ok / error for a few seconds.
// Works without the daemon (manual runs go through the CLI directly). Data: XCmdLaunch.
Item {
    id: root
    property string mode: "compact"            // compact | detailed
    readonly property var items: XCmdLaunch.pinnedCommands
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    function lastText(c) {
        const l = c.last_run;
        if (!l) return t("cmd.launch.never", "не запускалась");
        const when = LL.ago(l.ts, Date.now(), { now: t("cmd.launch.ago_now", "только что"), min: t("cmd.launch.ago_min", "мин назад"), hour: t("cmd.launch.ago_hour", "ч назад"), day: t("cmd.launch.ago_day", "дн назад") });
        return t("cmd.launch.st_" + l.status, l.status) + " · " + when;
    }
    function stateColor(c) {
        const rs = XCmdLaunch.stateOf(c.id);
        if (rs === "running") return ThemeBackend.mauve;
        if (rs === "ok") return ThemeBackend.green;
        if (rs === "error") return ThemeBackend.red;
        return ThemeBackend.surface0;
    }
    function stateGlyph(c, fallback) {
        const rs = XCmdLaunch.stateOf(c.id);
        return rs === "running" ? "󰔟" : rs === "ok" ? "󰄬" : rs === "error" ? "󰅖" : fallback;
    }

    Component.onCompleted: XCmdLaunch.subscribe()
    Component.onDestruction: XCmdLaunch.unsubscribe()

    Rectangle {
        anchors.fill: parent
        radius: XUi.s(16)
        color: Qt.alpha(ThemeBackend.mantle, 0.97)
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface1, 0.6)
        clip: true

        Item {
            id: head
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: XUi.gap }
            height: XUi.iconBox
            Rectangle {
                id: logo
                width: XUi.iconBox; height: width; radius: XUi.radiusBtn; color: Qt.alpha(ThemeBackend.mauve, 0.14)
                Text { anchors.centerIn: parent; text: CK.glyph("play"); font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconLg; color: ThemeBackend.mauve }
            }
            Text {
                anchors { left: logo.right; leftMargin: XUi.gapSm; right: tools.left; verticalCenter: parent.verticalCenter }
                text: root.t("cmd.widget.title", "Команды"); elide: Text.ElideRight
                color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.bold: true
            }
            Row {
                id: tools
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: XUi.gapXs
                Rectangle {
                    objectName: "wgPalette"
                    width: XUi.iconBoxSm; height: width; radius: XUi.radiusBtn; color: pa.containsMouse ? ThemeBackend.surface1 : ThemeBackend.surface0
                    Text { anchors.centerIn: parent; text: "󰍉"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconSm; color: ThemeBackend.text }
                    MouseArea { id: pa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmdLaunch.openPalette() }
                }
                Rectangle {
                    objectName: "wgApp"
                    width: XUi.iconBoxSm; height: width; radius: XUi.radiusBtn; color: oa.containsMouse ? ThemeBackend.surface1 : ThemeBackend.surface0
                    Text { anchors.centerIn: parent; text: "󰏌"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconSm; color: ThemeBackend.text }
                    MouseArea { id: oa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmdLaunch.openInApp("") }
                }
            }
        }

        Text {
            objectName: "wgEmpty"
            visible: root.items.length === 0
            anchors { left: parent.left; right: parent.right; top: head.bottom; margins: XUi.gap }
            wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
            color: XCmdLaunch.error !== "" ? ThemeBackend.red : ThemeBackend.subtext0
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
            text: XCmdLaunch.error !== "" ? XCmdLaunch.error
                  : !XCmdLaunch.loaded ? root.t("cmd.launch.loading", "Загружаю команды…")
                  : root.t("cmd.widget.empty", "Нет закреплённых команд. Откройте палитру (кнопка выше) и нажмите ☆ у нужных.")
        }

        // compact: grid of buttons
        Flow {
            id: grid
            objectName: "wgGrid"
            visible: root.mode === "compact" && root.items.length > 0
            anchors { left: parent.left; right: parent.right; top: head.bottom; margins: XUi.gap }
            spacing: XUi.gapSm
            Repeater {
                model: root.mode === "compact" ? root.items : []
                delegate: Rectangle {
                    id: btn
                    required property var modelData
                    objectName: "wgButton"
                    readonly property string rs: XCmdLaunch.stateOf(modelData.id)
                    readonly property bool blocked: LL.blockReason(modelData) !== null
                    width: Math.max(XUi.s(96), (grid.width - XUi.gapSm * 2) / 3 - 0.5); height: XUi.s(64)
                    radius: XUi.radiusBtn
                    color: rs !== "" ? Qt.alpha(root.stateColor(modelData), 0.28) : (ba.containsMouse ? ThemeBackend.surface1 : Qt.alpha(ThemeBackend.surface0, 0.8))
                    border.width: rs === "error" ? 1 : 0; border.color: ThemeBackend.red
                    opacity: blocked ? 0.6 : 1
                    Behavior on color { ColorAnimation { duration: 160 } }
                    Column {
                        anchors.centerIn: parent; width: parent.width - XUi.gapSm * 2; spacing: XUi.gapXxs
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.stateGlyph(modelData, CK.glyph(modelData.icon)); font.family: ThemeBackend.iconFont
                               font.pixelSize: XUi.iconLg; color: btn.rs === "ok" ? ThemeBackend.green : btn.rs === "error" ? ThemeBackend.red : ThemeBackend.mauve }
                        Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: modelData.name; elide: Text.ElideRight
                               color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
                    }
                    MouseArea { id: ba; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmdLaunch.run(btn.modelData) }
                }
            }
        }

        // detailed: rows with the last run
        ListView {
            id: rows
            objectName: "wgRows"
            visible: root.mode === "detailed" && root.items.length > 0
            anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; margins: XUi.gap }
            clip: true; spacing: XUi.gapXs; boundsBehavior: Flickable.StopAtBounds
            model: root.mode === "detailed" ? root.items : []
            delegate: Rectangle {
                id: rw
                required property var modelData
                objectName: "wgRow"
                readonly property string rs: XCmdLaunch.stateOf(modelData.id)
                readonly property string why: LL.blockReason(modelData) || ""
                width: rows.width; height: XUi.s(56); radius: XUi.radiusBtn
                color: rs !== "" ? Qt.alpha(root.stateColor(modelData), 0.22) : (ra.containsMouse ? ThemeBackend.surface1 : Qt.alpha(ThemeBackend.surface0, 0.7))
                Behavior on color { ColorAnimation { duration: 160 } }
                Text { id: rg; anchors { left: parent.left; leftMargin: XUi.gapSm; verticalCenter: parent.verticalCenter } width: XUi.iconLg * 1.4
                       text: root.stateGlyph(modelData, CK.glyph(modelData.icon)); font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconLg
                       color: rw.rs === "ok" ? ThemeBackend.green : rw.rs === "error" ? ThemeBackend.red : ThemeBackend.mauve }
                Column {
                    anchors { left: rg.right; leftMargin: XUi.gapSm; right: parent.right; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                    spacing: XUi.gapXxs
                    Text { width: parent.width; text: rw.modelData.name; elide: Text.ElideRight; color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.bold: true }
                    Text {
                        objectName: "wgInfo"
                        width: parent.width; elide: Text.ElideRight
                        text: rw.why !== "" ? ("⚠ " + XCmdLaunch.blockText(rw.why))
                              : rw.rs === "running" ? root.t("cmd.launch.running", "выполняется…")
                              : rw.rs === "error" && XCmdLaunch.runStates[rw.modelData.id].message !== "" ? XCmdLaunch.runStates[rw.modelData.id].message
                              : root.lastText(rw.modelData)
                        color: rw.why !== "" ? ThemeBackend.yellow : (rw.rs === "error" || (rw.rs === "" && rw.modelData.last_run && rw.modelData.last_run.status !== "ok")) ? ThemeBackend.red : ThemeBackend.subtext0
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    }
                }
                MouseArea { id: ra; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmdLaunch.run(rw.modelData) }
            }
        }
    }
}
