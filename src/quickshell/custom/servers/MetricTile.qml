import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// One metric of the detailed view: small caption, big value, optional progress bar and a secondary line.
Rectangle {
    id: tile
    property string caption: ""
    property string value: "—"
    property string unit: ""
    property string note: ""
    property real fraction: -1            // 0..1, <0 = no bar
    property color tone: ThemeBackend.mauve

    function s(v) { return Scaler.s(v); }

    implicitHeight: Math.max(s(64), body.implicitHeight + s(18))
    radius: s(10)
    color: Qt.alpha(ThemeBackend.surface0, 0.55)

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.leftMargin: tile.s(12)
        anchors.rightMargin: tile.s(12)
        anchors.topMargin: tile.s(9)
        anchors.bottomMargin: tile.s(9)
        spacing: tile.s(2)

        Text {
            text: tile.caption
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fCaption
            color: ThemeBackend.subtext0
        }
        Row {
            spacing: tile.s(3)
            Text {
                text: tile.value
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fTitle
                font.weight: Font.DemiBold
                color: ThemeBackend.text
            }
            Text {
                visible: tile.unit !== ""
                anchors.baseline: parent.children[0].baseline
                text: tile.unit
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fCaption
                color: ThemeBackend.subtext0
            }
        }
        Item { Layout.fillHeight: true }
        Rectangle {
            visible: tile.fraction >= 0
            Layout.fillWidth: true
            Layout.preferredHeight: tile.s(3)
            radius: height / 2
            color: Qt.alpha(ThemeBackend.surface2, 0.5)
            Rectangle {
                width: parent.width * Math.max(0.02, Math.min(1, tile.fraction))
                height: parent.height
                radius: height / 2
                color: tile.fraction > 0.85 ? ThemeBackend.red : (tile.fraction > 0.65 ? ThemeBackend.yellow : tile.tone)
                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
            }
        }
        Text {
            visible: tile.note !== ""
            text: tile.note
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fCaption
            color: ThemeBackend.subtext0
        }
    }
}
