import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../"
import "../../reusables"
import ".."
import "ColorUtil.js" as ColorUtil

// View of the colour history (see ColorHistory.qml for the window around it).
// Colour history panel (last 30 picked colours). Click copies the colour (Shift = other format).
Item {
    id: root

    property bool open: false
    property var items: []
    property int selected: 0
    property real nowMs: Date.now()
    readonly property real panelOpacity: panel.opacity

    signal copiedColor(string text, string hexValue)

    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    function show() { reload(); selected = 0; nowMs = Date.now(); open = true; }
    function hide() { open = false; }
    function toggle() { open ? hide() : show(); }
    function reload() { listProc.running = true; }

    function copyAt(i, alt) {
        if (i < 0 || i >= items.length) return;
        let k = alt ? ColorUtil.altKind(XToolsConf.picker.format) : XToolsConf.picker.format;
        root.copyKind(items[i].hex, k);
    }
    function copyKind(hexValue, k) {
        Quickshell.execDetached(["bash", XToolsConf.scriptsDir + "/x_colors.sh", "copy", hexValue, k]);
        root.copiedColor(ColorUtil.format(hexValue, k), hexValue);
        hide();
    }

    Process {
        id: listProc
        command: ["bash", XToolsConf.scriptsDir + "/x_colors.sh", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { let a = JSON.parse(this.text.trim()); root.items = Array.isArray(a) ? a : []; }
                catch (e) { XLog.warn("tools", "ColorHistoryView.qml: could not parse JSON output (a)"); root.items = []; }
            }
        }
    }
    Process { id: clearProc; command: ["bash", XToolsConf.scriptsDir + "/x_colors.sh", "clear"]; onExited: root.reload() }


    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true; }
            else if (e.key === Qt.Key_Left) { root.selected = Math.max(0, root.selected - 1); e.accepted = true; }
            else if (e.key === Qt.Key_Right) { root.selected = Math.min(root.items.length - 1, root.selected + 1); e.accepted = true; }
            else if (e.key === Qt.Key_Up) { root.selected = Math.max(0, root.selected - 4); e.accepted = true; }
            else if (e.key === Qt.Key_Down) { root.selected = Math.min(root.items.length - 1, root.selected + 4); e.accepted = true; }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.copyAt(root.selected, (e.modifiers & Qt.ShiftModifier) !== 0); e.accepted = true; }
        }

        MouseArea { anchors.fill: parent; onClicked: root.hide() }

        Rectangle {
            id: panel
            anchors.centerIn: parent
            width: s(640)
            height: header.height + s(20) + grid.height + s(30) + footer.height + s(36)
            radius: ThemeBackend.borderRadius + s(4)
            color: ThemeBackend.crust
            border.width: 1
            border.color: Qt.alpha(ThemeBackend.surface1, 0.8)
            opacity: root.open ? 1 : 0
            scale: root.open ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

            MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

            RowLayout {
                id: header
                x: s(20); y: s(18)
                width: parent.width - s(40)
                height: s(40)
                spacing: s(12)

                Rectangle {
                    Layout.preferredWidth: s(40); Layout.preferredHeight: s(40)
                    radius: ThemeBackend.borderRadius
                    color: ThemeBackend.surface0
                    Text { anchors.centerIn: parent; text: "󰈊"; font.family: "Iosevka Nerd Font"; font.pixelSize: XUi.s(20); color: ThemeBackend.mauve }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: s(1)
                    Text { Layout.fillWidth: true; elide: Text.ElideRight; text: t("tools.history.title", undefined, "История цветов"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fTitle; font.weight: Font.DemiBold; color: ThemeBackend.text }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: root.items.length === 0 ? t("tools.history.empty", undefined, "Пока пусто — выберите цвет пипеткой")
                                                     : t("tools.history.sub", { n: root.items.length, max: XToolsConf.picker.max }, root.items.length + " из " + XToolsConf.picker.max + "  ·  клик — копировать, Shift+клик — другой формат")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                    }
                }
                IconButton {
                    size: s(36); Layout.preferredWidth: s(36); Layout.preferredHeight: s(36)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰅖"; iconFontSize: XUi.fHead
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    onClicked: root.hide()
                }
            }

            GridLayout {
                id: grid
                x: s(20); y: header.y + header.height + s(20)
                width: parent.width - s(40)
                columns: 4
                columnSpacing: s(12); rowSpacing: s(12)
                readonly property real cellW: (width - 3 * columnSpacing) / 4

                Repeater {
                    model: root.items
                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        required property int index
                        readonly property bool isSel: root.selected === index
                        readonly property bool isNew: index === 0 && (root.nowMs / 1000 - modelData.ts) < 120
                        Layout.preferredWidth: grid.cellW
                        Layout.preferredHeight: s(92)
                        radius: ThemeBackend.borderRadius + s(2)
                        color: ma.containsMouse ? ThemeBackend.surface1 : ThemeBackend.mantle
                        border.width: isSel ? 2 : 0
                        border.color: ThemeBackend.mauve
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Rectangle {
                            x: s(8); y: s(8)
                            width: parent.width - s(16); height: s(46)
                            radius: s(8)
                            color: card.modelData.hex
                            border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.18)
                        }
                        Text {
                            x: s(10); y: s(62)
                            text: card.modelData.hex
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.weight: Font.DemiBold
                            color: ThemeBackend.text
                        }
                        Rectangle {
                            visible: card.isNew
                            anchors.right: parent.right; anchors.rightMargin: s(8)
                            y: s(60)
                            width: newLabel.implicitWidth + s(16); height: s(20)
                            radius: height / 2
                            color: ThemeBackend.mauve
                            Text { id: newLabel; anchors.centerIn: parent; text: t("tools.history.new", undefined, "новый"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.DemiBold; color: ThemeBackend.crust }
                        }
                        MouseArea {
                            id: ma
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (m) => { root.selected = card.index; root.copyAt(card.index, (m.modifiers & Qt.ShiftModifier) !== 0); }
                        }
                    }
                }
            }

            RowLayout {
                id: footer
                x: s(20); y: grid.y + grid.height + s(30)
                width: parent.width - s(40)
                spacing: s(8)
                ClickButton {
                    Layout.preferredHeight: s(36)
                    buttonIcon: "󰆏"; buttonText: t("tools.history.copy_hex", undefined, "Копировать HEX")
                    cornerRadius: ThemeBackend.borderRadius
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    enabled: root.items.length > 0
                    onClicked: if (root.selected < root.items.length) root.copyKind(root.items[root.selected].hex, "hex")
                }
                ClickButton {
                    Layout.preferredHeight: s(36)
                    buttonIcon: "󰆏"; buttonText: t("tools.history.copy_rgb", undefined, "Копировать RGB")
                    cornerRadius: ThemeBackend.borderRadius
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    enabled: root.items.length > 0
                    onClicked: if (root.selected < root.items.length) root.copyKind(root.items[root.selected].hex, "rgb")
                }
                Item { Layout.fillWidth: true }
                ClickButton {
                    Layout.preferredHeight: s(36)
                    buttonIcon: "󰩺"; buttonText: t("tools.history.clear", undefined, "Очистить")
                    cornerRadius: ThemeBackend.borderRadius
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    enabled: root.items.length > 0
                    onClicked: clearProc.running = true
                }
            }
        }
    }
}
