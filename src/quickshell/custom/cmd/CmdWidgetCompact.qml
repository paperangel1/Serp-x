import QtQuick
import "../../"

// Widget face: grid of pinned commands as buttons.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 260
    property real minHeight: 150
    property real maxWidth: 560
    property real maxHeight: 520
    property real minAspect: 0.5
    property real maxAspect: 3.0
    property bool isRound: false

    CmdWidgetView { anchors.fill: parent; mode: "compact" }
}
