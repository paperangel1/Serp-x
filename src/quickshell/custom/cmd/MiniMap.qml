import QtQuick
import "../../"
import ".."

// Overview of the whole graph with the visible area; click or drag to move the view.
Rectangle {
    id: mm
    property var canvas
    readonly property var b: canvas && canvas.graph ? canvas.graph.bounds : null
    readonly property real k: b && b.w > 0 ? Math.min((width - 16) / b.w, (height - 28) / Math.max(1, b.h)) : 1
    radius: 10
    color: Qt.alpha(ThemeBackend.mantle, 0.94)
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.text, 0.12)
    CT { x: 8; y: 5; text: XI18n.t("cmd.graph.minimap", undefined, "Обзор"); size: 10; c: ThemeBackend.subtext0 }
    Item {
        id: map
        x: 8; y: 20; width: parent.width - 16; height: parent.height - 28
        clip: true
        Repeater {
            model: mm.canvas && mm.canvas.graph ? mm.canvas.nodes : []
            delegate: Rectangle {
                x: mm.b ? (modelData.x - mm.b.x) * mm.k : 0; y: mm.b ? (modelData.y - mm.b.y) * mm.k : 0
                width: Math.max(3, modelData.w * mm.k); height: Math.max(3, modelData.h * mm.k); radius: 2
                color: Qt.alpha(CK.cc(modelData.cat), 0.75)
            }
        }
        Rectangle {   // visible area
            visible: mm.b !== null
            readonly property real vx: mm.canvas ? -mm.canvas.panX / mm.canvas.zoom : 0
            readonly property real vy: mm.canvas ? -mm.canvas.panY / mm.canvas.zoom : 0
            x: mm.b ? (vx - mm.b.x) * mm.k : 0; y: mm.b ? (vy - mm.b.y) * mm.k : 0
            width: mm.canvas ? mm.canvas.width / mm.canvas.zoom * mm.k : 0
            height: mm.canvas ? mm.canvas.height / mm.canvas.zoom * mm.k : 0
            color: Qt.alpha(ThemeBackend.mauve, 0.08)
            border.width: 1
            border.color: ThemeBackend.mauve
        }
        MouseArea {
            anchors.fill: parent
            function go(m) { if (mm.b) mm.canvas.centerOn(m.x / mm.k + mm.b.x, m.y / mm.k + mm.b.y); }
            onPressed: (m) => go(m)
            onPositionChanged: (m) => { if (pressed) go(m); }
        }
    }
}
