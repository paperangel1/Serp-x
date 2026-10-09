import QtQuick
import "../../"
import ".."

// Single-line input for secrets: masked by default, never echoed, cleared with clear().
Rectangle {
    id: root
    property alias text: input.text
    property string placeholder: ""
    property bool masked: true
    property alias inputFocus: input.activeFocus
    signal accepted()

    function s(v) { return Scaler.s(v); }
    function clear() { input.text = ""; }
    function forceFocus() { input.forceActiveFocus(); }

    implicitHeight: s(34)
    implicitWidth: s(240)
    radius: s(9)
    color: Qt.alpha(ThemeBackend.crust, 0.7)
    border.width: 1
    border.color: input.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.7)
    Behavior on border.color { ColorAnimation { duration: 140 } }

    TextInput {
        id: input
        anchors.fill: parent; anchors.leftMargin: root.s(11); anchors.rightMargin: root.s(11)
        verticalAlignment: TextInput.AlignVCenter
        echoMode: root.masked ? TextInput.Password : TextInput.Normal
        passwordCharacter: "•"
        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.text
        selectByMouse: true
        clip: true
        inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhSensitiveData | Qt.ImhNoAutoUppercase
        onAccepted: root.accepted()
    }
    Text {
        visible: input.text === "" && !input.activeFocus
        anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: root.s(11)
        text: root.placeholder
        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay0
    }
}
