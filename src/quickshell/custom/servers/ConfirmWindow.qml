import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Layer-shell window around ConfirmView, shown while XServers.pending is set.
PanelWindow {
    id: win

    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    color: "transparent"
    visible: XServers.pending !== null
    WlrLayershell.namespace: "qs-x-servers-confirm"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: view.implicitWidth
    implicitHeight: view.implicitHeight

    ConfirmView {
        id: view
        anchors.fill: parent
        onAccepted: typed => XServers.confirmPending(typed)
        onCancelled: XServers.cancelPending()
    }
}
