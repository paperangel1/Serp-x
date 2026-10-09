import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Layer-shell window around CmdMenuView: full-screen click-catcher (a click outside or Esc closes), the menu below the bar button.
PanelWindow {
    id: win
    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    color: "transparent"
    visible: XCmdLaunch.menuOpen
    WlrLayershell.namespace: "qs-x-commands-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }

    Shortcut { sequences: ["Escape"]; onActivated: XCmdLaunch.closeMenu() }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: XCmdLaunch.closeMenu() }

    CmdMenuView {
        id: view
        width: implicitWidth
        height: implicitHeight
        readonly property bool placed: XCmdLaunch.menuX >= 0
        x: placed ? Math.max(XUi.gapSm, Math.min(parent.width - width - XUi.gapSm, XCmdLaunch.menuX - width / 2)) : Math.round((parent.width - width) / 2)
        y: placed ? XCmdLaunch.menuY : Math.round(parent.height * 0.18)
        onCloseRequested: XCmdLaunch.closeMenu()
    }
}
