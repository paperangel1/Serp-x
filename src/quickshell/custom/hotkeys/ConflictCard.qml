import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// Shown when the captured combination is already used. `conflict` is an XHotkeys row.
Rectangle {
    id: root

    property var conflict: null
    signal replace()
    signal chooseOther()

    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + Scaler.s(24)
    radius: ThemeBackend.borderRadius
    color: Qt.alpha(ThemeBackend.red, 0.07)
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.red, 0.55)

    ColumnLayout {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Scaler.s(12)
        spacing: Scaler.s(10)

        RowLayout {
            Layout.fillWidth: true
            spacing: Scaler.s(10)
            Text {
                text: "󰀪"
                font.family: ThemeBackend.iconFont
                font.pixelSize: XUi.s(20)
                color: ThemeBackend.red
                Layout.alignment: Qt.AlignTop
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(2)
                Text {
                    text: XHotkeys.t("hotkeys.conflict.title", undefined, "This combination is already in use")
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fRow
                    font.bold: true
                    color: ThemeBackend.text
                }
                Text {
                    Layout.fillWidth: true
                    text: XHotkeys.t("hotkeys.conflict.desc", undefined, "If you replace it, the action below loses its keys; you can assign it a new combination later.")
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                    wrapMode: Text.WordWrap
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Scaler.s(40)
            radius: ThemeBackend.borderRadius
            color: Qt.alpha(ThemeBackend.surface0, 0.7)
            visible: root.conflict !== null

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Scaler.s(10)
                anchors.rightMargin: Scaler.s(10)
                spacing: Scaler.s(10)

                AppIcon {
                    size: 24
                    icon: root.conflict ? root.conflict.icon.image : ""
                    glyph: root.conflict ? root.conflict.icon.glyph : ""
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    text: root.conflict ? root.conflict.label : ""
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fBody
                    font.bold: true
                    color: ThemeBackend.text
                    Layout.alignment: Qt.AlignVCenter
                }
                Text {
                    Layout.fillWidth: true
                    text: root.conflict ? (root.conflict.source === "custom"
                            ? XHotkeys.t("hotkeys.conflict.own", undefined, "your hotkey")
                            : XHotkeys.t("hotkeys.conflict.system", undefined, "system hotkey")) : ""
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                    elide: Text.ElideRight
                    Layout.alignment: Qt.AlignVCenter
                }
                ComboChips {
                    Layout.alignment: Qt.AlignVCenter
                    mods: root.conflict ? root.conflict.mods : []
                    key: root.conflict ? root.conflict.key : ""
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Scaler.s(8)

            ClickButton {
                Layout.preferredHeight: Scaler.s(34)
                horizontalPadding: Scaler.s(14)
                cornerRadius: ThemeBackend.borderRadius
                buttonText: XHotkeys.t("hotkeys.conflict.replace", undefined, "Replace")
                buttonIcon: "󰓡"
                textFontSize: XUi.fBody
                iconFontSize: XUi.fSub
                accentColor: Qt.alpha(ThemeBackend.red, 0.75)
                textColor: ThemeBackend.crust
                onTriggered: root.replace()
            }
            ClickButton {
                Layout.preferredHeight: Scaler.s(34)
                horizontalPadding: Scaler.s(14)
                cornerRadius: ThemeBackend.borderRadius
                buttonText: XHotkeys.t("hotkeys.conflict.other", undefined, "Choose another")
                buttonIcon: "󰌌"
                textFontSize: XUi.fBody
                iconFontSize: XUi.fSub
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.crust
                onTriggered: root.chooseOther()
            }
            Item { Layout.fillWidth: true }
        }
    }
}
