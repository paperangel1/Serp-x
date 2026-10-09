import QtQuick
import "../../"
import ".."

// Thumbnail of a graph (boxes in category colours + straight links), used in the detail panel.
Rectangle {
    id: mp
    property var graph: null
    readonly property var b: graph && graph.nodes.length > 0 ? graph.bounds : null
    readonly property real k: b ? Math.min((width - 28) / Math.max(1, b.w), (height - 36) / Math.max(1, b.h)) : 1
    radius: 12
    color: ThemeBackend.base
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.text, 0.10)
    clip: true
    function px(n) { return 14 + (n.x - b.x) * k; }
    function py(n) { return 14 + (n.y - b.y) * k; }
    Repeater {
        model: mp.b ? mp.graph.wires : []
        delegate: Rectangle {
            readonly property var a: mp.graph.nodes.find(n => n.id === modelData.from[0])
            readonly property var c: mp.graph.nodes.find(n => n.id === modelData.to[0])
            visible: a !== undefined && c !== undefined
            x: a ? mp.px(a) + a.w * mp.k : 0
            y: a ? mp.py(a) + 6 : 0
            width: a && c ? Math.max(1, mp.px(c) - (mp.px(a) + a.w * mp.k)) : 0
            height: modelData.t === "exec" ? 2 : 1
            color: Qt.alpha(modelData.t === "exec" ? ThemeBackend.text : CK.tc(modelData.t), 0.45)
        }
    }
    Repeater {
        model: mp.b ? mp.graph.nodes : []
        delegate: Rectangle {
            x: mp.px(modelData); y: mp.py(modelData)
            width: Math.max(6, modelData.w * mp.k); height: Math.max(8, Math.min(14, modelData.h * mp.k * 0.5)); radius: 3
            color: Qt.alpha(CK.cc(modelData.cat), 0.8)
        }
    }
    CT { x: 14; y: parent.height - 20; width: parent.width - 28; size: 10; c: ThemeBackend.subtext0
         text: mp.graph ? XI18n.t("cmd.detail.preview", { n: mp.graph.nodes.length }, mp.graph.nodes.length + " узлов · предпросмотр") : "" }
}
