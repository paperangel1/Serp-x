import QtQuick
import "../../"

// Status dot with a soft ring: green = online and calm, yellow = online and busy, red = offline, grey = unknown.
Item {
    id: dot
    property var server: null
    property real size: Scaler.s(12)
    implicitWidth: size
    implicitHeight: size

    readonly property color tone: {
        if (!server || server.online === null || server.online === undefined) return ThemeBackend.surface2;
        if (server.online !== true) return ThemeBackend.red;
        let cpu = (server.ssh && server.ssh.status && server.ssh.status.cpu !== undefined) ? server.ssh.status.cpu : -1;
        return cpu >= 80 ? ThemeBackend.yellow : (cpu >= 55 ? ThemeBackend.yellow : ThemeBackend.green);
    }

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Qt.alpha(dot.tone, 0.22)
    }
    Rectangle {
        anchors.centerIn: parent
        width: dot.size * 0.58
        height: width
        radius: width / 2
        color: dot.tone
        Behavior on color { ColorAnimation { duration: 200 } }
    }
}
