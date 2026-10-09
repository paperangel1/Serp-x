import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"

// Layer-shell window around NoteCardView, anchored to the configured corner.
PanelWindow {
    id: win

    required property var ctl

    screen: ctl.targetScreen
    color: "transparent"
    visible: view.shown
    WlrLayershell.namespace: "qs-x-notes-card"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: false
    anchors { bottom: ctl.atBottom; top: !ctl.atBottom; right: ctl.atRight; left: !ctl.atRight }
    implicitWidth: view.implicitWidth
    implicitHeight: view.implicitHeight

    NoteCardView { id: view; anchors.fill: parent; ctl: win.ctl; screen: win.screen }
}
