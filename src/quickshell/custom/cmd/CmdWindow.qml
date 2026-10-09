import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../"
import ".."

// Layer-shell window (centred, takes the keyboard while open) around CmdView. Content is designed at 1600x860 design
// pixels (10-13 px type) and shown at k = XUi.cmdZoom (1.1: that type lands on the stock 11-14 px) or, when the screen
// is too small for that, at the largest k that still fits it.
PanelWindow {
    id: win
    screen: {
        let name = (typeof Hyprland !== "undefined" && Hyprland.focusedMonitor) ? Hyprland.focusedMonitor.name : "";
        for (let i = 0; i < Quickshell.screens.length; i++) if (Quickshell.screens[i].name === name) return Quickshell.screens[i];
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }
    readonly property real k: screen ? Math.min(XUi.cmdZoom, (screen.width - 48) / 1600, (screen.height - 110) / 860) : XUi.cmdZoom
    color: "transparent"
    visible: XCmd.open
    WlrLayershell.namespace: "qs-x-commands"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Math.round(1600 * k)
    implicitHeight: Math.round(860 * k)

    // Esc / Ctrl+Q live at WINDOW level: a Keys handler on a sibling Item never sees the key once a field inside
    // CmdView holds the focus, which left the window impossible to close. (Super+Q cannot work: it is a compositor
    // bind that kills a client window, and this is a layer-shell surface.)
    function back() {
        if (XCmd.dialog !== null) XCmd.dialog = null;
        else if (XCmd.screen === "graph") XCmd.closeGraph();
        else if (XCmd.screen === "gallery" || XCmd.screen === "docs") XCmd.closeSub();
        else XCmd.closeWindow();
    }
    Shortcut { sequences: ["Escape"]; onActivated: win.back() }
    Shortcut { sequences: ["Ctrl+Q"]; onActivated: XCmd.closeWindow() }

    CmdView {
        scale: win.k
        transformOrigin: Item.TopLeft
    }

    Rectangle {
        id: closeBtn
        z: 1000
        width: XUi.iconBoxSm + XUi.gapXxs; height: width; radius: XUi.radius
        anchors.top: parent.top; anchors.right: parent.right
        anchors.topMargin: XUi.gapSm; anchors.rightMargin: XUi.gapSm
        color: closeArea.containsMouse ? Qt.alpha(ThemeBackend.red, 0.35) : Qt.alpha(ThemeBackend.surface0, 0.9)
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
            anchors.centerIn: parent
            text: "✕"
            color: ThemeBackend.text
            font.pixelSize: XUi.fRow
        }
        MouseArea {
            id: closeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: XCmd.closeWindow()
        }
    }
}
