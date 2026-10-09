import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"

// Layer-shell window around ToolToastView: click-through, top or bottom centre of the screen.
PanelWindow {
    id: win

    property alias title: view.title
    property alias subtitle: view.subtitle
    property alias icon: view.icon
    property alias accent: view.accent
    property alias shown: view.shown

    function show(titleText, subText, swatchColor, edgeName, ms) { view.show(titleText, subText, swatchColor, edgeName, ms); }
    function hide() { view.hide(); }

    color: "transparent"
    visible: view.cardOpacity > 0.01
    WlrLayershell.namespace: "qs-x-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: false
    mask: Region {}
    anchors { top: view.edge === "top"; bottom: view.edge === "bottom"; left: true; right: true }
    implicitHeight: view.implicitHeight

    ToolToastView { id: view; anchors.fill: parent }
}
