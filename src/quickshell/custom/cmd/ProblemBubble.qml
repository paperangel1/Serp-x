import QtQuick
import "../../"
import ".."

// Bubble next to a problem pin (C4): what is wrong, a quick fix (insert a converter) and «Отключить провод».
Rectangle {
    id: pb
    property string title: ""
    property string message: ""
    property string fixLabel: ""
    property bool canDisconnect: false
    property string footer: ""
    readonly property alias fixButton: fixBtn
    signal fixClicked()
    signal disconnectClicked()
    signal dismissed()
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    width: 416
    height: 74 + msg.implicitHeight + (fixLabel !== "" || canDisconnect ? 52 : 0) + (footer !== "" ? 18 : 0)
    radius: 12
    color: ThemeBackend.mantle
    border.width: 1; border.color: Qt.alpha("#f38ba8", 0.8)
    z: 40

    Rectangle { x: 14; y: 14; width: 28; height: 28; radius: 14; color: Qt.alpha("#f38ba8", 0.2)
        CT { anchors.centerIn: parent; icon: true; size: 15; c: "#f38ba8"; text: "\u{f0026}" } }
    CT { x: 54; y: 12; width: parent.width - 100; size: 12; font.bold: true; c: "#f38ba8"; text: pb.title }
    CT { id: msg; x: 54; y: 34; width: parent.width - 70; size: 11; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: pb.message }
    Rectangle {
        x: parent.width - 36; y: 8; width: 26; height: 26; radius: 7; color: cl.containsMouse ? ThemeBackend.surface0 : "transparent"
        CT { anchors.centerIn: parent; icon: true; text: "\u{f0156}"; size: 14; c: ThemeBackend.subtext1 }
        MouseArea { id: cl; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pb.dismissed() }
    }
    Row {
        visible: pb.fixLabel !== "" || pb.canDisconnect
        x: 14; y: 48 + msg.implicitHeight + 6; spacing: 10
        CmdBtn { id: fixBtn; visible: pb.fixLabel !== ""; kind: "primary"; icon: "\u{f0415}"; text: pb.fixLabel; onClicked: pb.fixClicked() }
        CmdBtn { visible: pb.canDisconnect; kind: "ghost"; text: pb.t("cmd.edit.disconnect", "Отключить провод"); onClicked: pb.disconnectClicked() }
    }
    CT { visible: pb.footer !== ""; anchors.right: parent.right; anchors.rightMargin: 14; y: parent.height - 22; size: 10; c: ThemeBackend.subtext0; text: pb.footer }
}
