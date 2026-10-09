import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../"
import "../../reusables"
import ".."

// «Запустить команду…» picker of the New hotkey flow: search + list of the Commands app's commands (`serpantinum-x cmd list --json`).
// Tests set `commands` directly (nothing is started when `fake` is true).
ColumnLayout {
    id: root
    objectName: "xCmdPicker"

    property string selectedName: ""
    property var commands: []                       // [{id, name, description, enabled}]
    property bool fake: false
    property bool loaded: false
    property string query: ""
    signal picked(string name)

    spacing: Scaler.s(8)

    readonly property string script: Caching.serpantinumDir + "/scripts/custom/cmd/x_cmd.sh"
    readonly property var filtered: {
        let q = root.query.trim().toLowerCase();
        if (q === "") return root.commands;
        return root.commands.filter(c => c.name.toLowerCase().indexOf(q) !== -1 || (c.description || "").toLowerCase().indexOf(q) !== -1);
    }

    Component.onCompleted: if (!fake) proc.running = true

    Process {
        id: proc
        command: ["bash", root.script, "--json", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.commands = (JSON.parse(this.text).commands || []).slice().sort((a, b) => a.name.localeCompare(b.name)); } catch (e) { root.commands = []; }
                root.loaded = true;
            }
        }
        onExited: (code) => { if (code !== 0) root.loaded = true; }
    }

    Input {
        Layout.fillWidth: true
        implicitHeight: Scaler.s(36)
        leadingIcon: "󰍉"
        placeholderText: XHotkeys.t("hotkeys.add.search_cmd", undefined, "Find a command…")
        baseColor: ThemeBackend.surface0
        accentColor: ThemeBackend.mauve
        textColor: ThemeBackend.text
        subTextColor: ThemeBackend.subtext0
        borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
        cornerRadius: ThemeBackend.borderRadius
        fontPixelSize: XUi.fBody
        onTextEdited: function(t) { root.query = t; }
    }

    Flickable {
        id: flick
        Layout.fillWidth: true
        Layout.preferredHeight: Scaler.s(148)
        contentWidth: width
        contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            width: flick.width
            spacing: Scaler.s(4)
            Repeater {
                model: root.filtered
                delegate: Rectangle {
                    id: cell
                    required property var modelData
                    objectName: "xCmdPickerRow"
                    width: col.width
                    height: Scaler.s(44)
                    radius: ThemeBackend.borderRadius
                    readonly property bool sel: root.selectedName === modelData.name
                    color: sel ? Qt.alpha(ThemeBackend.mauve, 0.22) : (cm.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : Qt.alpha(ThemeBackend.surface0, 0.7))
                    border.width: sel ? 1 : 0
                    border.color: ThemeBackend.mauve
                    Column {
                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Scaler.s(12); rightMargin: Scaler.s(12) }
                        spacing: Scaler.s(2)
                        Text { width: parent.width; text: cell.modelData.name; elide: Text.ElideRight; color: ThemeBackend.text
                               font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; font.bold: true }
                        Text { width: parent.width; visible: text !== ""; text: cell.modelData.description || ""; elide: Text.ElideRight; color: ThemeBackend.subtext0
                               font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
                    }
                    MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.picked(cell.modelData.name) }
                }
            }
            Text {
                objectName: "xCmdPickerEmpty"
                visible: root.filtered.length === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: Scaler.s(24)
                text: !root.loaded ? XHotkeys.t("hotkeys.add.cmd_loading", undefined, "Loading commands…")
                      : root.query.trim() !== "" ? XHotkeys.t("hotkeys.add.cmd_none_found", undefined, "Nothing found")
                      : XHotkeys.t("hotkeys.add.cmd_none", undefined, "No commands yet: create one in the Commands app")
                color: ThemeBackend.subtext0
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
            }
        }
    }
}
