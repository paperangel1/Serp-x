import QtQuick
import "../../"

// Widget face: detailed view of the selected server (the chevron goes back to the list).
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 480
    property real minHeight: 470
    property real maxWidth: 760
    property real maxHeight: 900
    property real minAspect: 0.5
    property real maxAspect: 1.6
    property bool isRound: false

    ServersView { anchors.fill: parent; mode: "detail" }
}
