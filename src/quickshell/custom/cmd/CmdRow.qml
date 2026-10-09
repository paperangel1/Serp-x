import QtQuick
import "../../"
import ".."

// One command in the list: icon, name, description, trigger chips, last run, state / run button.
Rectangle {
    id: row
    property var cmd
    property bool selected: false
    signal chosen()
    signal opened()
    signal runRequested()
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    readonly property var last: cmd.last_run || null
    readonly property bool bad: cmd.errors > 0

    height: 68; radius: 12
    color: selected ? Qt.alpha(ThemeBackend.mauve, 0.07) : (ma.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.55) : ThemeBackend.base)
    border.width: 1
    border.color: selected ? Qt.alpha(ThemeBackend.mauve, 0.6) : Qt.alpha(ThemeBackend.text, 0.10)

    Rectangle { x: 16; y: 14; width: 40; height: 40; radius: 10; color: ThemeBackend.surface0
        CT { anchors.centerIn: parent; icon: true; text: CK.glyph(row.cmd.icon); size: 19; c: ThemeBackend.mauve } }
    CT { x: 68; y: 11; width: parent.width - 450; text: row.cmd.name; size: 12; font.bold: true }
    CT { x: 68; y: 29; width: parent.width - 450; text: row.cmd.description !== "" ? row.cmd.description : row.t("cmd.row.no_desc", "без описания"); size: 11; c: ThemeBackend.subtext1 }
    Text {   // pin: the command appears first in the palette, in the bar menu and in the desktop widget
        id: star
        visible: !row.cmd.example
        x: parent.width - 380; y: 20; width: 28; height: 28
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: row.cmd.pinned ? "★" : "☆"
        color: row.cmd.pinned ? ThemeBackend.yellow : (starMa.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0)
        font.pixelSize: XUi.iconLg
        MouseArea { id: starMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.togglePin(row.cmd.id) }
    }
    Row {
        x: 68; y: 46; spacing: 6
        Repeater {
            model: row.cmd.triggers
            delegate: CmdChip { text: "\u{f140b}  " + modelData; tone: "#cba6f7" }
        }
        CmdChip { visible: row.cmd.kind === "manual"; text: row.t("cmd.row.nodes", row.cmd.nodes + " узлов", { n: row.cmd.nodes }); tone: "#9399b2" }
        CmdChip { visible: row.bad; text: row.t("cmd.row.errors", row.cmd.errors + " ошибок", { n: row.cmd.errors }); tone: "#f38ba8" }
        CmdChip { visible: !row.cmd.approved && !row.cmd.example; text: row.t("cmd.row.unapproved", "права не подтверждены"); tone: "#f9e2af" }
    }
    Item {
        anchors.right: parent.right; anchors.rightMargin: 16; y: 0; width: 330; height: parent.height
        CT { x: 0; y: 14; width: 200; text: row.last ? (XCmd.when(row.last.ts) + " · " + (row.last.status === "ok" ? row.t("cmd.run.ok", "ок") : row.last.status)) : (row.cmd.example ? row.t("cmd.row.example", "пример") : row.t("cmd.row.never", "не запускалась"))
             size: 10; c: row.last && row.last.status !== "ok" ? "#f38ba8" : (row.bad ? "#f38ba8" : ThemeBackend.subtext0) }
        CT { x: 0; y: 34; width: 200; visible: row.bad || row.last !== null; text: row.bad ? row.t("cmd.row.fix", "исправьте ошибки, чтобы включить") : row.t("cmd.row.last", "последний запуск"); size: 10; c: ThemeBackend.subtext0 }
        Rectangle {   // enable switch (automations)
            visible: row.cmd.kind === "auto"
            x: parent.width - 40; y: 22; width: 40; height: 24; radius: 12
            color: row.cmd.enabled && !row.bad ? ThemeBackend.mauve : ThemeBackend.surface0
            Rectangle { x: row.cmd.enabled && !row.bad ? 18 : 2; y: 2; width: 20; height: 20; radius: 10; color: row.cmd.enabled && !row.bad ? ThemeBackend.crust : ThemeBackend.subtext0 }
            MouseArea {
                anchors.fill: parent; enabled: !row.cmd.example; cursorShape: Qt.PointingHandCursor
                onClicked: { if (row.bad && !row.cmd.enabled) XCmd.showToast(row.t("cmd.row.fix_first", "Сначала исправьте ошибки в команде")); else XCmd.setEnabled(XCmd.refOf(row.cmd), !row.cmd.enabled); }
            }
        }
        CmdBtn {
            visible: row.cmd.kind === "manual"
            x: parent.width - width; y: 18
            kind: "primary"; icon: "\u{f040a}"; text: row.t("cmd.run.button", "Запустить")
            enabled: !row.cmd.example && !row.bad
            onClicked: row.runRequested()
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.chosen()
        onDoubleClicked: row.opened()
    }
}
