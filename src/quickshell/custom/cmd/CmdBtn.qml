import QtQuick
import "../../"

// kind: normal | primary | ghost. A disabled button is dimmed and ignores clicks.
Rectangle {
    id: b
    property string text: ""
    property string icon: ""
    property string kind: "normal"
    property int h: 32
    property int padX: 12
    property bool hot: false
    signal clicked()
    readonly property color fg: kind === "primary" || kind === "danger" ? ThemeBackend.crust : ThemeBackend.text
    implicitHeight: h
    implicitWidth: row.implicitWidth + padX * 2
    radius: ThemeBackend.borderRadius
    opacity: enabled ? 1 : 0.45
    color: kind === "danger" ? (mouse.containsMouse && enabled ? Qt.lighter("#f38ba8", 1.08) : "#f38ba8")
        : kind === "primary" ? (mouse.containsMouse && enabled ? Qt.lighter(ThemeBackend.mauve, 1.08) : ThemeBackend.mauve)
        : kind === "ghost" ? "transparent" : (mouse.containsMouse && enabled ? ThemeBackend.surface1 : ThemeBackend.surface0)
    border.width: kind === "ghost" ? 1 : 0
    border.color: Qt.alpha(ThemeBackend.text, 0.14)
    Behavior on color { ColorAnimation { duration: 120 } }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        CT { visible: b.icon !== ""; icon: true; text: b.icon; size: 15; c: b.fg; anchors.verticalCenter: parent.verticalCenter }
        CT { visible: b.text !== ""; text: b.text; size: 12; c: b.fg; font.bold: b.kind === "primary" || b.kind === "danger"; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: b.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: b.clicked()
    }
}
