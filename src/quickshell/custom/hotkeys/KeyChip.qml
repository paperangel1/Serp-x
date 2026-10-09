import QtQuick
import "../../"
import ".."

// One key cap of a combination ("SUPER", "F", "←" ...).
Rectangle {
    id: chip

    property string text: ""
    property bool accent: false          // highlighted (capture / conflict)
    property color accentColor: ThemeBackend.mauve
    property bool dimmed: false
    property int pixelSize: XUi.fCaption

    implicitWidth: Math.max(Scaler.s(26), label.implicitWidth + Scaler.s(16))
    implicitHeight: Scaler.s(26)
    radius: Scaler.s(6)
    color: accent ? Qt.alpha(accentColor, 0.16) : Qt.alpha(ThemeBackend.surface1, 0.55)
    border.width: 1
    border.color: accent ? Qt.alpha(accentColor, 0.9) : Qt.alpha(ThemeBackend.surface2, 0.7)
    opacity: dimmed ? 0.45 : 1.0

    Behavior on color { ColorAnimation { duration: 150 } }
    Behavior on border.color { ColorAnimation { duration: 150 } }

    Text {
        id: label
        anchors.centerIn: parent
        text: chip.text
        font.family: ThemeBackend.fontFamily
        font.pixelSize: Math.max(XUi.fCaption, chip.pixelSize)
        font.bold: true
        color: chip.accent ? chip.accentColor : ThemeBackend.text
    }
}
