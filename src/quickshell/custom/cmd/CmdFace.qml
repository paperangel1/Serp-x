import QtQuick
import Quickshell
import "../../"
import ".."

// Bar module «Команды» (horizontal bar): icon button. Click opens the palette; right click / long press opens the menu of
// pinned commands. A dot shows paused automations (yellow) or a failed run in the last 15 minutes (red).
// Registered at runtime in BarModuleRegistry by XCmdLaunchHost. Polls `cmd pulse` only while the face is alive and visible.
Item {
    id: root

    property var module: null
    property var widget: module

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    function s(v) { return barWindow ? barWindow.s(v) : v; }

    property bool showFace: false
    property alias cmdPill: pill
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

    function openMenu() {
        const p = pill.mapToItem(null, pill.width / 2, 0);
        XCmdLaunch.openMenu(p.x, barWindow ? (barWindow.baseOffsetY || 0) + (barWindow.barHeight || s(40)) : s(46));
    }

    Rectangle {
        id: pill
        anchors.centerIn: parent
        height: s(root.isCompact ? 28 : 30)
        implicitWidth: height + s(4)
        width: implicitWidth
        radius: Math.max(0, ThemeBackend.borderRadius - s(2))
        color: root.failed ? Qt.alpha(ThemeBackend.red, 0.14) : Qt.alpha(ThemeBackend.surface0, root.isCompact ? 0.5 : 0.8)
        border.width: root.failed ? 1 : 0
        border.color: Qt.alpha(ThemeBackend.red, 0.75)
        scale: ma.pressed ? 0.95 : 1.0
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutQuint } }

        Rectangle {
            anchors.fill: parent; radius: parent.radius; color: "white"
            opacity: ma.containsMouse ? 0.08 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
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
            onPressAndHold: (e) => { root.held = true; root.openMenu(); }
            onClicked: (e) => {
                if (root.held) { root.held = false; return; }
                if (e.button === Qt.RightButton) root.openMenu();
                else XCmdLaunch.togglePalette();
            }
        }
    }
}
