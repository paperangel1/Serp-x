import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Layer-shell window (centered, takes the keyboard while open) around ServerTerminalView.
PanelWindow {
    id: win

    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    color: "transparent"
    visible: XServers.termVisible
    WlrLayershell.namespace: "qs-x-servers-terminal"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: view.implicitWidth
    implicitHeight: view.implicitHeight

    ServerTerminalView { id: view; anchors.fill: parent; onCloseRequested: XServers.closeTerminal() }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: XServers.closeTerminal()
    }
}
