import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// A combination rendered as key caps joined by "+".
Row {
    id: root

    property var mods: []
    property string key: ""
    property bool accent: false
    property color accentColor: ThemeBackend.mauve
    property bool dimmed: false
    property bool showPlaceholder: false      // show "—" when nothing is set
    property string placeholder: "—"

    readonly property var parts: (mods || []).concat(key !== "" ? [XHotkeys.prettyKey(key)] : [])

    spacing: Scaler.s(4)

    Repeater {
        model: root.parts
        delegate: Row {
            required property string modelData
            required property int index
            spacing: Scaler.s(4)
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined

            Text {
                visible: index > 0
                anchors.verticalCenter: parent.verticalCenter
                text: "+"
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fCaption
                color: ThemeBackend.overlay1
                opacity: root.dimmed ? 0.5 : 1.0
            }
            KeyChip {
                text: modelData
                accent: root.accent
                accentColor: root.accentColor
                dimmed: root.dimmed
            }
        }
    }

    Text {
        visible: root.parts.length === 0 && root.showPlaceholder
        anchors.verticalCenter: parent.verticalCenter
        text: root.placeholder
        font.family: ThemeBackend.fontFamily
        font.pixelSize: XUi.fBody
        color: ThemeBackend.overlay1
    }
}
