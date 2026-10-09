import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../"
import ".."

// View of the toast (see ToolToast.qml for the layer-shell window around it).
// Small click-through toast used by the tools (colour copied, text recognised, errors).
// Top toasts sit under the bar, bottom toasts above the dock.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    property color swatch: "transparent"     // transparent -> show a check icon instead
    property color accent: ThemeBackend.mauve
    property string icon: "󰄬"
    property string edge: "top"              // top | bottom
    property bool shown: false

    function s(v) { return Scaler.s(v); }

    function show(titleText, subText, swatchColor, edgeName, ms) {
        title = titleText || "";
        subtitle = subText || "";
        swatch = swatchColor || "transparent";
        edge = edgeName || "top";
        shown = true;
        hideTimer.interval = ms || 2200;
        hideTimer.restart();
    }
    function hide() { shown = false; hideTimer.stop(); }

    Timer { id: hideTimer; interval: 2200; onTriggered: root.shown = false }


    implicitHeight: s(150)
    readonly property real cardOpacity: card.opacity

    Rectangle {
        id: card
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.edge === "top" ? s(78) + (root.shown ? 0 : -s(10)) : parent.height - height - s(84) + (root.shown ? 0 : s(10))
        width: row.implicitWidth + s(32)
        height: s(56)
        radius: ThemeBackend.borderRadius + s(2)
        color: ThemeBackend.crust
        border.width: 2
        border.color: root.accent
        opacity: root.shown ? 1 : 0

        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 280; easing.type: Easing.OutQuint } }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: s(12)

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: s(22); implicitHeight: s(22)
                radius: s(6)
                color: root.swatch.a > 0 ? root.swatch : "transparent"
                border.width: root.swatch.a > 0 ? 1 : 0
                border.color: Qt.alpha(ThemeBackend.text, 0.25)

                Text {
                    anchors.centerIn: parent
                    visible: root.swatch.a === 0
                    text: root.icon
                    font.family: "Iosevka Nerd Font"
                    font.pixelSize: XUi.s(20)
                    color: root.accent
                }
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: s(1)
                Text {
                    text: root.title
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fRow
                    font.weight: Font.DemiBold
                    color: ThemeBackend.text
                }
                Text {
                    visible: root.subtitle !== ""
                    text: root.subtitle
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }
        }
    }
}
