import QtQuick
import "../../"

// Widget face: compact list of servers (double click / «подробнее» opens the detailed view in place).
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 320
    property real minHeight: 210
    property real maxWidth: 560
    property real maxHeight: 760
    property real minAspect: 0.5
    property real maxAspect: 2.2
    property bool isRound: false

    ServersView { anchors.fill: parent; mode: "list" }
}
