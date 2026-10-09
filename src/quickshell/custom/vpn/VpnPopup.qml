import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../"
import ".."

// Layer-shell window around VpnPopupView: full-screen click-catcher, keyboard focus while open.
PanelWindow {
    id: win

    color: "transparent"
    visible: view.open || view.panelOpacity > 0.01
    WlrLayershell.namespace: "qs-x-vpn"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: view.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: view.open
    anchors { top: true; bottom: true; left: true; right: true }

    VpnPopupView { id: view; anchors.fill: parent; open: XVpn.popupOpen }
}
