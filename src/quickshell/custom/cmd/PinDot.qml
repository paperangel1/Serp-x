import QtQuick
import "../../"

// Exec pin = rotated square (diamond), data pin = circle; filled when wired.
Item {
    id: pin
    property string kind: "any"
    property bool filled: false
    property bool bad: false
    property bool lit: false
    property bool dim: false
    opacity: dim ? 0.28 : 1
    width: 12; height: 12
    readonly property color col: bad ? "#f38ba8" : CK.tc(kind)
    Rectangle {
        anchors.centerIn: parent
        width: pin.kind === "exec" ? 9 : 11
        height: width
        rotation: pin.kind === "exec" ? 45 : 0
        radius: pin.kind === "exec" ? 1 : 6
        color: pin.filled || pin.lit ? pin.col : ThemeBackend.mantle
        border.width: 2
        border.color: pin.col
    }
    Rectangle {
        visible: pin.bad
        anchors.centerIn: parent
        width: 20; height: 20; radius: 10
        color: "transparent"
        border.width: 2
        border.color: Qt.alpha("#f38ba8", 0.5)
    }
}
