import QtQuick
import QtQuick.Layouts
import "../../"

// Card with the same surface as the stock SettingsRow (used for the larger blocks of the
// Updates tab that are not a single title/description row).
Rectangle {
    id: card
    required property var rootObj
    default property alias content: col.data
    property real pad: rootObj.s(14)
    property real contentSpacing: rootObj.s(10)
    property color borderColor: "transparent"

    Layout.fillWidth: true
    radius: ThemeBackend.borderRadius
    color: Qt.alpha(ThemeBackend.surface0, 0.4)
    border.width: borderColor.a > 0 ? 1 : 0
    border.color: borderColor
    implicitHeight: col.implicitHeight + pad * 2
    Behavior on border.color { ColorAnimation { duration: 180 } }

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: card.pad
        spacing: card.contentSpacing
    }
}
