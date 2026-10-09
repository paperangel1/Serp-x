import QtQuick
import Quickshell
import "../../"
import ".."

// Bar module «VPN» for vertical bars: icon button coloured by state, click opens the popup.
Item {
    id: root

    property var module: null
    property var widget: module

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    function s(v) { return barWindow ? barWindow.s(v) : v; }

    property bool showFace: false
    property alias vpnPill: btn

    readonly property string vstate: XVpn.vstate

    Component.onCompleted: XVpn.watch(1)
    Component.onDestruction: XVpn.watch(-1)

    property real targetHeight: btn.height + s(isCompact ? 8 : 10)
    property bool isFaceVisible: showFace && targetHeight > 0

    implicitHeight: targetHeight
    implicitWidth: parent ? parent.width : 0

    Timer {
        running: (!module || module.moduleActive) && (!barWindow || (barWindow.isStartupReady && barWindow.isDataReady))
        interval: 100
        onTriggered: root.showFace = true
    }

    Rectangle {
        id: btn
        anchors.centerIn: parent
        width: s(root.isCompact ? 28 : 30)
        height: width
        radius: Math.max(0, ThemeBackend.borderRadius - s(2))
        color: root.vstate === "on" ? ThemeBackend.mauve
               : root.vstate === "failed" ? Qt.alpha(ThemeBackend.red, 0.14)
               : Qt.alpha(ThemeBackend.surface0, 0.8)
        border.width: root.vstate === "failed" ? 1 : 0
        border.color: Qt.alpha(ThemeBackend.red, 0.75)
        opacity: root.showFace ? 1 : 0
        scale: ma.pressed ? 0.95 : 1.0
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on opacity { NumberAnimation { duration: 450 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

        Text {
            anchors.centerIn: parent
            text: "󰖂"
            font.family: ThemeBackend.iconFont
            font.pixelSize: s(16)
            color: root.vstate === "on" ? ThemeBackend.crust : root.vstate === "failed" ? ThemeBackend.red : ThemeBackend.text
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (e) => {
                if (e.button === Qt.RightButton) XVpn.toggle();
                else { XVpn.anchorX = -1; XVpn.anchorY = -1; XVpn.popupOpen = !XVpn.popupOpen; }
            }
        }
    }
}
