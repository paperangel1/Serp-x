import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../"
import ".."

// Bar module «VPN» (horizontal bar): state, current node with its flag, live download speed.
// Registered at runtime in BarModuleRegistry by XVpnHost; click opens the VPN popup.
Item {
    id: root

    property var module: null
    property var widget: module

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    function s(v) { return barWindow ? barWindow.s(v) : v; }

    property bool showFace: false
    property alias vpnPill: pill

    readonly property string vstate: XVpn.vstate
    readonly property bool failed: vstate === "failed"
    readonly property bool on: vstate === "on"

    Component.onCompleted: XVpn.watch(1)
    Component.onDestruction: XVpn.watch(-1)

    readonly property string label: {
        if (on) return XVpn.plainName(XVpn.node);
        if (vstate === "starting") return XVpn.t("vpn.bar.connecting", undefined, "Подключение…");
        if (vstate === "switching") return XVpn.t("vpn.bar.switching", undefined, "Смена узла…");
        if (failed) return XVpn.t("vpn.bar.failed", undefined, "Нет связи с узлом");
        return XVpn.t("vpn.bar.off", undefined, "VPN выкл.");
    }

    property real targetWidth: ((!module || module.moduleActive) && pill.implicitWidth > 0) ? pill.implicitWidth + s(isCompact ? 6 : 8) : 0
    property bool isFaceVisible: showFace && targetWidth > 0

    implicitWidth: targetWidth
    implicitHeight: parent ? parent.height : 0

    Timer {
        running: (!module || module.moduleActive) && (!barWindow || (barWindow.isStartupReady && barWindow.isDataReady))
        interval: 100
        onTriggered: root.showFace = true
    }

    transform: Translate {
        x: root.showFace ? 0 : s(60)
        Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
    }

    Rectangle {
        id: pill
        anchors.centerIn: parent
        height: s(root.isCompact ? 28 : 30)
        implicitWidth: row.implicitWidth + s(root.isCompact ? 20 : 24)
        width: implicitWidth
        radius: Math.max(0, ThemeBackend.borderRadius - s(2))
        color: root.on ? ThemeBackend.mauve
               : root.failed ? Qt.alpha(ThemeBackend.red, 0.14)
               : Qt.alpha(ThemeBackend.surface0, root.isCompact ? 0.5 : 0.8)
        border.width: root.failed ? 1 : 0
        border.color: Qt.alpha(ThemeBackend.red, 0.75)
        scale: ma.pressed ? 0.97 : 1.0
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

        readonly property color fg: root.on ? ThemeBackend.crust : root.failed ? ThemeBackend.red : ThemeBackend.text

        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "white"
            opacity: ma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }

        Row {
            id: row
            anchors.centerIn: parent
            spacing: s(7)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰖂"
                font.family: ThemeBackend.iconFont
                font.pixelSize: s(15)
                color: pill.fg
                opacity: root.vstate === "off" ? 0.8 : 1.0
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.label
                font.family: ThemeBackend.fontFamily
                font.pixelSize: s(12)
                font.weight: Font.DemiBold
                color: pill.fg
                elide: Text.ElideRight
                width: Math.min(implicitWidth, s(150))
            }
            Rectangle {
                visible: root.on
                anchors.verticalCenter: parent.verticalCenter
                width: 1; height: s(12)
                color: Qt.alpha(ThemeBackend.crust, 0.35)
            }
            Text {
                visible: root.on
                anchors.verticalCenter: parent.verticalCenter
                text: "↓ " + XVpn.fmtRate(XVpn.speedDown)
                font.family: ThemeBackend.fontFamily
                font.pixelSize: s(11)
                color: Qt.alpha(ThemeBackend.crust, 0.78)
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (e) => {
                if (e.button === Qt.RightButton || e.button === Qt.MiddleButton) { XVpn.toggle(); return; }
                let p = pill.mapToItem(null, pill.width / 2, 0);
                XVpn.anchorX = p.x;
                XVpn.anchorY = barWindow ? (barWindow.baseOffsetY || 0) + (barWindow.barHeight || s(40)) : s(46);
                XVpn.popupOpen = !XVpn.popupOpen;
            }
        }
    }
}
