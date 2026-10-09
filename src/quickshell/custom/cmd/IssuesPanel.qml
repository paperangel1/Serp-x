import QtQuick
import "../../"
import ".."

// «Проблемы» (C4): errors and warnings of the live validation; a click jumps to the node.
Rectangle {
    id: ip
    signal jumpTo(string nodeId)
    signal fixIssue(var issue)
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    readonly property var items: XEdit.issues.list
    function titleOf(id) { const v = XEdit.view; if (v) for (let i = 0; i < v.nodes.length; i++) if (v.nodes[i].id === id) return v.nodes[i].title; return ""; }
    function pinLabel(it) {
        if (!it.node || !it.pin) return "";
        const v = XEdit.view;
        if (v) for (let i = 0; i < v.nodes.length; i++) if (v.nodes[i].id === it.node) {
            const n = v.nodes[i], all = n.ins.concat(n.outs);
            for (let j = 0; j < all.length; j++) if (all[j].id === it.pin) return all[j].n;
        }
        return it.pin;
    }

    width: 360
    height: Math.min(360, 62 + Math.max(1, items.length) * 74)
    radius: 12
    color: ThemeBackend.mantle
    border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.14)
    z: 30

    CT { id: ttl; x: 16; y: 14; size: 12; font.bold: true; text: ip.t("cmd.edit.problems", "Проблемы") }
    CmdChip {
        x: 16 + ttl.implicitWidth + 12; y: 15
        visible: XEdit.errors + XEdit.warnings > 0
        text: (XEdit.errors > 0 ? ip.t("cmd.check.n_errors", XEdit.errors + " ош.", { n: XEdit.errors }) : "") + (XEdit.errors > 0 && XEdit.warnings > 0 ? " · " : "")
              + (XEdit.warnings > 0 ? ip.t("cmd.check.n_warnings", XEdit.warnings + " предупр.", { n: XEdit.warnings }) : "")
        tone: XEdit.errors > 0 ? "#f38ba8" : "#f9e2af"
    }
    CT { visible: ip.items.length === 0; x: 16; y: 44; size: 11; c: "#a6e3a1"; text: ip.t("cmd.check.clean", "Ошибок и замечаний нет") }
    Flickable {
        x: 8; y: 44; width: parent.width - 16; height: parent.height - 52
        contentWidth: width; contentHeight: col.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: parent.width; spacing: 6
            Repeater {
                model: ip.items
                delegate: Rectangle {
                    width: col.width; height: 68; radius: 8; color: Qt.alpha(ThemeBackend.base, 0.8)
                    Rectangle { x: 0; y: 0; width: 3; height: parent.height; radius: 2; color: modelData.level === "error" ? "#f38ba8" : "#f9e2af" }
                    CT { x: 14; y: 8; width: parent.width - 24; size: 11; font.bold: true
                         text: modelData.node ? (ip.titleOf(modelData.node) + (modelData.pin ? " · «" + ip.pinLabel(modelData) + "»" : "")) : ip.t("cmd.check.whole", "Вся команда") }
                    CT { x: 14; y: 26; width: parent.width - 24; height: 36; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideRight; text: modelData.message }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (modelData.node) ip.jumpTo(modelData.node); } }
                }
            }
        }
    }
}
