import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"

// Layer-shell window around ColorHistoryView: full-screen click-catcher, keyboard focus while open.
PanelWindow {
    id: win

    signal copiedColor(string text, string hexValue)

    function show() { view.show(); }
    function hide() { view.hide(); }
    function toggle() { view.toggle(); }

    color: "transparent"
    visible: view.open || view.panelOpacity > 0.01
    WlrLayershell.namespace: "qs-x-colors"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: view.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: view.open
    anchors { top: true; bottom: true; left: true; right: true }

    ColorHistoryView { id: view; anchors.fill: parent; onCopiedColor: (text, hex) => win.copiedColor(text, hex) }
}
