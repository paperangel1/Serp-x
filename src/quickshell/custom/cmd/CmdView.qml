import QtQuick
import "../../"
import ".."

// The Commands window content, designed at 1600x860 (the host window scales it down on small screens).
Rectangle {
    id: view
    width: 1600; height: 860
    color: ThemeBackend.base
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.text, 0.12)
    readonly property alias graphView: graphScreen
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    Item {
        id: listScreen
        anchors.fill: parent; anchors.margins: 1
        visible: XCmd.screen === "list"
        CmdSidebar { x: 0; y: 0; width: 248; height: parent.height }
        CmdList { visible: XCmd.filter !== "functions"; x: 248; y: 0; width: parent.width - 248 - 320; height: parent.height }
        CmdDetail { visible: XCmd.filter !== "functions"; x: parent.width - 320; y: 0; width: 320; height: parent.height }
        FnLibrary { visible: XCmd.filter === "functions"; x: 248; y: 0; width: parent.width - 248; height: parent.height }
    }
    GalleryView { anchors.fill: parent; anchors.margins: 1; visible: XCmd.screen === "gallery" }
    DocsView { anchors.fill: parent; anchors.margins: 1; visible: XCmd.screen === "docs" }
    GraphView {
        id: graphScreen
        anchors.fill: parent; anchors.margins: 1
        visible: XCmd.screen === "graph"
        focus: visible
    }

    Rectangle {   // toast (with an optional action, e.g. «Вернуть» after a delete)
        visible: XCmd.toast !== ""
        anchors.horizontalCenter: parent.horizontalCenter; y: parent.height - 70
        width: toastText.implicitWidth + 40 + (XCmd.toastAction ? actionBtn.width + 12 : 0); height: 40; radius: 12
        color: ThemeBackend.mantle; border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.5)
        z: 90
        CT { id: toastText; x: 20; anchors.verticalCenter: parent.verticalCenter; text: XCmd.toast; size: 12 }
        CmdBtn {
            id: actionBtn
            visible: XCmd.toastAction !== null
            x: toastText.x + toastText.implicitWidth + 12; anchors.verticalCenter: parent.verticalCenter
            h: 26; padX: 10; kind: "primary"; text: XCmd.toastAction ? XCmd.toastAction.label : ""
            onClicked: { const a = XCmd.toastAction; if (a) a.run(); }
        }
    }
    TutorialOverlay { }
    CmdDialogs { id: dialogs }
}
