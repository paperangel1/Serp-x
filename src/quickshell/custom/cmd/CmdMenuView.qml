import QtQuick
import "../../"
import ".."
import "LaunchLogic.js" as LL

// Small menu of the bar button (see CmdMenu.qml): pinned commands (a click runs), the palette, the Commands app and the
// global pause of automations.
Rectangle {
    id: root
    signal closeRequested()
    readonly property var items: XCmdLaunch.pinnedCommands
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    implicitWidth: XUi.s(280)
    implicitHeight: col.implicitHeight + XUi.gapSm * 2
    radius: XUi.radiusCtl
    color: Qt.alpha(ThemeBackend.mantle, 0.98)
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.surface1, 0.7)

    component MenuRow: Rectangle {
        id: it
        property string icon: ""
        property string label: ""
        property string sub: ""
        property color iconColor: ThemeBackend.mauve
        property bool dim: false
        property bool toggle: false
        property bool on: false
        signal triggered()
        width: parent ? parent.width : 0
        height: XUi.rowH + XUi.gapXs
        radius: XUi.radiusBtn
        color: ia.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : "transparent"
        opacity: dim ? 0.6 : 1
        Text { id: ic; anchors { left: parent.left; leftMargin: XUi.gapSm; verticalCenter: parent.verticalCenter } width: XUi.iconMd * 1.4
               text: it.icon; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconMd; color: it.iconColor }
        Text { anchors { left: ic.right; leftMargin: XUi.gapXs; right: sw.visible ? sw.left : parent.right; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
               text: it.label; elide: Text.ElideRight; color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody }
        Text { id: sw; visible: it.toggle || it.sub !== ""
               anchors { right: parent.right; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
               text: it.toggle ? (it.on ? "●" : "○") : it.sub
               color: it.toggle ? (it.on ? ThemeBackend.yellow : ThemeBackend.subtext0) : ThemeBackend.subtext0
               font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
        MouseArea { id: ia; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: it.triggered() }
    }

    Column {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: XUi.gapSm }
        spacing: XUi.gapXxs
        Text { text: root.t("cmd.menu.pinned", "Закреплённые"); color: ThemeBackend.subtext0; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
               bottomPadding: XUi.gapXxs; leftPadding: XUi.gapSm }
        Repeater {
            model: root.items
            delegate: MenuRow {
                required property var modelData
                objectName: "menuPinned"
                icon: CK.glyph(modelData.icon)
                label: modelData.name
                dim: LL.blockReason(modelData) !== null
                sub: XCmdLaunch.stateOf(modelData.id) === "running" ? "…" : XCmdLaunch.stateOf(modelData.id) === "ok" ? "✓" : XCmdLaunch.stateOf(modelData.id) === "error" ? "✗" : ""
                onTriggered: { XCmdLaunch.run(modelData); root.closeRequested(); }
            }
        }
        Text { objectName: "menuNoPins"; visible: root.items.length === 0; width: parent.width; wrapMode: Text.WordWrap; leftPadding: XUi.gapSm; rightPadding: XUi.gapSm
               text: root.t("cmd.menu.no_pins", "Нет закреплённых команд. Откройте палитру и нажмите ☆ у команды.")
               color: ThemeBackend.subtext0; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
        Rectangle { width: parent.width; height: 1; color: Qt.alpha(ThemeBackend.surface1, 0.6) }
        MenuRow { objectName: "menuPalette"; icon: "󰍉"; label: root.t("cmd.menu.palette", "Палитра команд"); onTriggered: { XCmdLaunch.openPalette(); root.closeRequested(); } }
        MenuRow { objectName: "menuApp"; icon: "󰏌"; label: root.t("cmd.menu.open_app", "Открыть приложение"); onTriggered: { XCmdLaunch.openInApp(""); root.closeRequested(); } }
        MenuRow { objectName: "menuPause"; icon: "󰏤"; iconColor: ThemeBackend.yellow; toggle: true; on: XCmdLaunch.pausedAll
                label: root.t("cmd.menu.pause", "Пауза автоматизаций"); onTriggered: XCmdLaunch.setPaused(!XCmdLaunch.pausedAll) }
    }
}
