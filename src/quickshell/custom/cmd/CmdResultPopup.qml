import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Overlay window around CmdResultView (the content is a separate item so it can be tested offscreen). Centred like the Commands window.
PanelWindow {
    id: win
    required property var bridge
    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    color: "transparent"
    visible: view.visible
    WlrLayershell.namespace: "qs-x-commands-result"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: view.implicitWidth
    implicitHeight: view.implicitHeight
    CmdResultView { id: view; anchors.fill: parent; bridge: win.bridge }
}
