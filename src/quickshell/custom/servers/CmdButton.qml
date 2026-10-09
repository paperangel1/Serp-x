import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// Command button of the detailed view (diagnostics / actions / custom). `danger` outlines it in red.
Rectangle {
    id: btn
    property string icon: ""
    property string label: ""
    property bool danger: false
    property bool dashed: false
    property bool busy: false
    signal clicked()

    function s(v) { return Scaler.s(v); }

    implicitHeight: s(34)
    radius: s(9)
    color: ma.pressed ? Qt.alpha(ThemeBackend.surface1, 0.9) : (ma.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : Qt.alpha(ThemeBackend.surface0, 0.6))
    border.width: 1
    border.color: danger ? Qt.alpha(ThemeBackend.red, ma.containsMouse ? 0.8 : 0.45) : (ma.containsMouse ? Qt.alpha(ThemeBackend.mauve, 0.5) : "transparent")
    scale: ma.pressed ? 0.98 : 1
    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutQuint } }

    RowLayout {
        anchors.centerIn: parent
        spacing: btn.s(7)
        Text {
            text: btn.icon
            font.family: ThemeBackend.iconFont
            font.pixelSize: XUi.fSub
            color: btn.danger ? ThemeBackend.red : ThemeBackend.mauve
        }
        Text {
            text: btn.label
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fCaption
            font.weight: Font.Medium
            color: btn.danger ? ThemeBackend.red : ThemeBackend.text
            elide: Text.ElideRight
            Layout.maximumWidth: btn.width - btn.s(40)
        }
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
