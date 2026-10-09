import QtQuick
import Quickshell
import "../../"
import ".."

// Bar module «Команды» for vertical bars: the same icon button (see CmdFace.qml).
Item {
    id: root

    property var module: null
    property var widget: module

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    function s(v) { return barWindow ? barWindow.s(v) : v; }

    property bool showFace: false
    property alias cmdPill: btn
    readonly property bool watching: !module || module.moduleActive
    readonly property bool failed: (XCmdLaunch.pulse.failed_recent || 0) > 0
    readonly property bool paused: XCmdLaunch.pulse.paused_all === true
    property bool held: false

    property bool counted: false                 // exactly one watch() per visible face, released when it hides or dies
    function sync() {
        if (watching && !counted) { counted = true; XCmdLaunch.watch(1); }
        else if (!watching && counted) { counted = false; XCmdLaunch.watch(-1); }
    }
    onWatchingChanged: sync()
    Component.onCompleted: sync()
    Component.onDestruction: { if (counted) XCmdLaunch.watch(-1); }

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
        color: root.failed ? Qt.alpha(ThemeBackend.red, 0.14) : Qt.alpha(ThemeBackend.surface0, 0.8)
        border.width: root.failed ? 1 : 0
        border.color: Qt.alpha(ThemeBackend.red, 0.75)
        opacity: root.showFace ? 1 : 0
        scale: ma.pressed ? 0.95 : 1.0
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on opacity { NumberAnimation { duration: 450 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

        Text {
            anchors.centerIn: parent
            text: CK.glyph("play")
            font.family: ThemeBackend.iconFont
            font.pixelSize: XUi.iconMd
            color: root.failed ? ThemeBackend.red : ThemeBackend.text
        }
        Rectangle {
            objectName: "cmdDot"
            visible: root.failed || root.paused
            width: s(8); height: width; radius: width / 2
            anchors { top: parent.top; right: parent.right; topMargin: s(3); rightMargin: s(3) }
            color: root.failed ? ThemeBackend.red : ThemeBackend.yellow
            border.width: 1; border.color: ThemeBackend.crust
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onPressed: root.held = false
            onPressAndHold: { root.held = true; XCmdLaunch.openMenu(-1, -1); }
            onClicked: (e) => {
                if (root.held) { root.held = false; return; }
                if (e.button === Qt.RightButton) XCmdLaunch.openMenu(-1, -1);
                else XCmdLaunch.togglePalette();
            }
        }
    }
}
