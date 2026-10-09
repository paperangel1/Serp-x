import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Layer-shell window around CmdPaletteView: full-screen click-catcher, the card centred a bit above the middle, keyboard
// focus while open. Esc / Ctrl+Q live at WINDOW level (like CmdWindow): a Keys handler inside the view never sees them
// once the search field holds the focus.
PanelWindow {
    id: win
    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    color: "transparent"
    visible: XCmdLaunch.paletteOpen
    WlrLayershell.namespace: "qs-x-commands-palette"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    anchors { top: true; bottom: true; left: true; right: true }

    Shortcut { sequences: ["Escape"]; onActivated: XCmdLaunch.closePalette() }
    Shortcut { sequences: ["Ctrl+Q"]; onActivated: XCmdLaunch.closePalette() }

    onVisibleChanged: if (visible) { view.reset(); view.focusSearch(); }

    MouseArea { anchors.fill: parent; onClicked: XCmdLaunch.closePalette() }
    Rectangle { anchors.fill: parent; color: Qt.alpha(ThemeBackend.crust, 0.35) }

    CmdPaletteView {
        id: view
        width: implicitWidth
        height: implicitHeight
        x: Math.round((parent.width - width) / 2)
        y: Math.round(parent.height * 0.18)
        onCloseRequested: XCmdLaunch.closePalette()
    }
}
