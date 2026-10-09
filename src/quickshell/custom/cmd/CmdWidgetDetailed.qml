import QtQuick
import "../../"

// Widget face: pinned commands as rows with the last run.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 300
    property real minHeight: 220
    property real maxWidth: 620
    property real maxHeight: 760
    property real minAspect: 0.5
    property real maxAspect: 2.2
    property bool isRound: false

    CmdWidgetView { anchors.fill: parent; mode: "detailed" }
}
