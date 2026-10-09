import QtQuick
import "../../"

Rectangle {
    property string text: ""
    property color tone: ThemeBackend.mauve
    implicitHeight: 18
    implicitWidth: ct.implicitWidth + 12
    radius: 6
    color: Qt.alpha(tone, 0.16)
    CT { id: ct; anchors.centerIn: parent; text: parent.text; size: 10; c: parent.tone }
}
