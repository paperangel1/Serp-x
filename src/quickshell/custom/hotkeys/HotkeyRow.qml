import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// One hotkey: icon, name + badge, details, combination, edit / delete / on-off.
SettingsRow {
    id: root

    required property var rowData              // XHotkeys row
    property bool editing: false
    signal toggleEdit()

    readonly property bool off: rowData.disabled
    // switching a hotkey back on while another one owns its combination would double-bind it
    readonly property var blockedBy: off ? XHotkeys.conflictFor(rowData.ref, rowData.mods, rowData.key) : null

    showIcon: false
    clickable: false
    animateHeight: true
    bottomSpacing: Scaler.s(12)
    innerSpacing: editing ? Scaler.s(12) : 0
    borderWidth: editing ? 1 : 0
    borderColor: Qt.alpha(ThemeBackend.mauve, 0.85)
    baseColor: Qt.alpha(ThemeBackend.surface0, editing ? 0.55 : 0.4)

    customLeftContent: Component {
        RowLayout {
            spacing: Scaler.s(12)
            opacity: root.off ? 0.5 : 1.0
            Behavior on opacity { NumberAnimation { duration: 180 } }

            AppIcon {
                size: 32
                icon: root.rowData.icon.image
                glyph: root.rowData.icon.glyph
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignVCenter
                spacing: Scaler.s(2)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)
                    Text {
                        text: root.rowData.label
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: XUi.fRow
                        color: ThemeBackend.text
                        elide: Text.ElideRight
                        Layout.maximumWidth: Scaler.s(260)
                    }
                    Rectangle {
                        visible: root.rowData.badge !== ""
                        implicitWidth: badgeText.implicitWidth + Scaler.s(12)
                        implicitHeight: Scaler.s(16)
                        radius: Scaler.s(8)
                        color: root.rowData.badge === "own" ? Qt.alpha(ThemeBackend.surface2, 0.6) : Qt.alpha(ThemeBackend.mauve, 0.22)
                        Text {
                            id: badgeText
                            anchors.centerIn: parent
                            text: root.rowData.badge === "own"
                                  ? XHotkeys.t("hotkeys.badge.own", undefined, "own")
                                  : XHotkeys.t("hotkeys.badge.changed", undefined, "changed")
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: XUi.fCaption
                            font.bold: true
                            color: root.rowData.badge === "own" ? ThemeBackend.subtext1 : ThemeBackend.mauve
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
                Text {
                    Layout.fillWidth: true
                    text: root.blockedBy ? XHotkeys.t("hotkeys.row.blocked", { name: root.blockedBy.label }, "Combination is taken by: " + root.blockedBy.label) : root.rowData.detail
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: root.blockedBy ? ThemeBackend.peach : ThemeBackend.subtext0
                    elide: Text.ElideRight
                }
            }
        }
    }

    ComboChips {
        Layout.alignment: Qt.AlignVCenter
        mods: root.rowData.mods
        key: root.rowData.key
        dimmed: root.off
        accent: root.editing
        showPlaceholder: true
    }

    IconButton {
        Layout.alignment: Qt.AlignVCenter
        size: Scaler.s(32)
        Layout.preferredWidth: Scaler.s(32)
        Layout.preferredHeight: Scaler.s(32)
        cornerRadius: ThemeBackend.borderRadius
        buttonIcon: root.editing ? "󰅖" : "󰏫"
        iconFontSize: XUi.fSub
        accentColor: root.editing ? ThemeBackend.mauve : ThemeBackend.surface1
        textColor: root.editing ? ThemeBackend.crust : ThemeBackend.text
        onClicked: root.toggleEdit()
    }

    // Fixed slot: rows without a delete button keep the column, so edit buttons and
    // key chips line up across all rows.
    Item {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Scaler.s(32)
        Layout.preferredHeight: Scaler.s(32)

        IconButton {
            anchors.fill: parent
            visible: root.rowData.source === "custom"
            size: Scaler.s(32)
            cornerRadius: ThemeBackend.borderRadius
            buttonIcon: "󰆴"
            iconFontSize: XUi.fSub
            accentColor: Qt.alpha(ThemeBackend.red, 0.2)
            textColor: ThemeBackend.red
            onClicked: XHotkeys.deleteCustom(root.rowData.custom.id)
        }
    }

    Toggle {
        Layout.alignment: Qt.AlignVCenter
        enabled: !root.blockedBy
        opacity: enabled ? 1.0 : 0.45
        checked: !root.off
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface1
        handleColor: ThemeBackend.crust
        handleOffColor: ThemeBackend.text
        onToggled: function(val) {
            if (root.rowData.source === "custom") XHotkeys.setCustomEnabled(root.rowData.custom.id, val);
            else XHotkeys.setShippedEnabled(root.rowData.bind, val);
        }
    }

    bottomContent: [
        Loader {
            Layout.fillWidth: true
            active: root.editing
            visible: active
            sourceComponent: HotkeyEditor {
                row: root.rowData
                onClosed: root.toggleEdit()
            }
        }
    ]
}
