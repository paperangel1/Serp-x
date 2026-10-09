import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"

// Layer-shell window around NoteEditorView, anchored to the configured corner. Takes the keyboard
// exclusively while open (on demand when the note is pinned).
PanelWindow {
    id: win

    required property var ctl

    screen: ctl.targetScreen
    color: "transparent"
    visible: view.shown
    WlrLayershell.namespace: "qs-x-notes-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: ctl.mode === "editor" ? (view.pinned ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive) : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: ctl.mode === "editor"
    anchors { bottom: ctl.atBottom; top: !ctl.atBottom; right: ctl.atRight; left: !ctl.atRight }
    implicitWidth: view.implicitWidth
    implicitHeight: view.implicitHeight

    NoteEditorView { id: view; anchors.fill: parent; ctl: win.ctl }
}
