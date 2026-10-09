import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../../"
import "../../reusables"
import ".."

// Settings tab «Горячие клавиши»: shows every hotkey of the Hyprland config (grouped, searchable),
// lets the user change shipped ones, add their own and switch any of them off.
// Changes are applied automatically (XHotkeys.scheduleApply).
Item {
    id: hotkeysTabRoot
    objectName: "xHotkeysTab"
    required property var rootObj
    required property int tabIndex

    anchors.fill: parent
    visible: rootObj.currentTab === tabIndex
    opacity: visible ? 1.0 : 0.0
    property real slideY: visible ? 0 : rootObj.s(10)

    Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
    transform: Translate { y: slideY }
    Behavior on opacity { NumberAnimation { duration: 250 } }

    property string query: ""
    property string editingRef: ""
    property bool adding: false

    onVisibleChanged: if (visible) XHotkeys.init()
    Component.onCompleted: if (visible) XHotkeys.init()

    Reserved {
        anchors.centerIn: parent
        visible: !XHotkeys.isHyprland
        imageSize: rootObj.s(160)
        textSize: rootObj.s(13)
        text: XHotkeys.t("hotkeys.unsupported", undefined, "Hotkey editing is only available on Hyprland")
    }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.margins: rootObj.s(8)
        contentHeight: pageCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: XHotkeys.isHyprland

        ColumnLayout {
            id: pageCol
            width: flick.width
            spacing: rootObj.s(6)

            // ---- header ----------------------------------------------------------------
            SettingsRow {
                Layout.fillWidth: true
                visible: !hotkeysTabRoot.adding
                rootObj: hotkeysTabRoot.rootObj
                searchable: false
                icon: "󰌌"
                title: XHotkeys.t("tabs.hotkeys", undefined, "Hotkeys")
                description: XHotkeys.t("hotkeys.header.desc", undefined, "View, change and add key combinations. Changes apply immediately.")

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    visible: text !== ""
                    text: XHotkeys.applyState === "ok" ? XHotkeys.t("hotkeys.apply.ok", undefined, "Applied")
                        : (XHotkeys.applyState === "pending" || XHotkeys.applyState === "running") ? XHotkeys.t("hotkeys.apply.running", undefined, "Applying…")
                        : ""
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: XHotkeys.applyState === "ok" ? ThemeBackend.green : ThemeBackend.subtext0
                }
                ClickButton {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: rootObj.s(32)
                    horizontalPadding: rootObj.s(14)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonText: XHotkeys.t("hotkeys.header.add", undefined, "Add")
                    buttonIcon: "󰐕"
                    textFontSize: XUi.fBody
                    iconFontSize: XUi.fSub
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.crust
                    onTriggered: { hotkeysTabRoot.editingRef = ""; hotkeysTabRoot.adding = true; }
                }
            }

            // ---- notices ---------------------------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                visible: !hotkeysTabRoot.adding && XHotkeys.importedNames.length > 0
                implicitHeight: impRow.implicitHeight + rootObj.s(16)
                radius: ThemeBackend.borderRadius
                color: Qt.alpha(ThemeBackend.mauve, 0.10)
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.mauve, 0.45)
                RowLayout {
                    id: impRow
                    anchors.fill: parent
                    anchors.margins: rootObj.s(8)
                    anchors.leftMargin: rootObj.s(12)
                    spacing: rootObj.s(10)
                    Text { text: "󰋼"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fTitle; color: ThemeBackend.mauve }
                    Text {
                        Layout.fillWidth: true
                        text: XHotkeys.t("hotkeys.notice.imported", { list: XHotkeys.importedNames.join(", ") }, "Kept hotkeys that were missing from the settings: " + XHotkeys.importedNames.join(", "))
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: XUi.fBody
                        color: ThemeBackend.text
                        wrapMode: Text.WordWrap
                    }
                    IconButton {
                        size: rootObj.s(24)
                        Layout.preferredWidth: rootObj.s(24)
                        Layout.preferredHeight: rootObj.s(24)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰅖"
                        iconFontSize: XUi.fRow
                        accentColor: "transparent"
                        textColor: ThemeBackend.subtext0
                        onClicked: XHotkeys.importedNames = []
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                visible: !hotkeysTabRoot.adding && (!XHotkeys.requirePresent || XHotkeys.applyState === "error")
                implicitHeight: warnCol.implicitHeight + rootObj.s(20)
                radius: ThemeBackend.borderRadius
                color: Qt.alpha(ThemeBackend.red, 0.08)
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.red, 0.5)
                ColumnLayout {
                    id: warnCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: rootObj.s(10)
                    spacing: rootObj.s(8)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: rootObj.s(10)
                        Text { text: "󰀪"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.red; Layout.alignment: Qt.AlignTop }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: rootObj.s(2)
                            Text {
                                Layout.fillWidth: true
                                text: !XHotkeys.requirePresent
                                      ? XHotkeys.t("hotkeys.warn.not_linked", undefined, "Your hotkeys are not connected to Hyprland")
                                      : XHotkeys.t("hotkeys.warn.apply_failed", undefined, "Could not apply the hotkeys")
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: XUi.fRow
                                font.bold: true
                                color: ThemeBackend.text
                                wrapMode: Text.WordWrap
                            }
                            Text {
                                Layout.fillWidth: true
                                text: !XHotkeys.requirePresent
                                      ? XHotkeys.t("hotkeys.warn.not_linked_desc", undefined, "hyprland.lua does not load user_keybinds.lua, so changes have no effect. Fix adds one line to hyprland.lua (a backup is made first).")
                                      : XHotkeys.applyError
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: XUi.fCaption
                                color: ThemeBackend.subtext0
                                wrapMode: Text.WordWrap
                                maximumLineCount: 4
                                elide: Text.ElideRight
                            }
                        }
                    }
                    ClickButton {
                        visible: !XHotkeys.requirePresent
                        Layout.preferredHeight: rootObj.s(32)
                        horizontalPadding: rootObj.s(14)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonText: XHotkeys.t("hotkeys.warn.fix", undefined, "Fix")
                        buttonIcon: "󰁨"
                        textFontSize: XUi.fBody
                        iconFontSize: XUi.fSub
                        accentColor: ThemeBackend.mauve
                        textColor: ThemeBackend.crust
                        onTriggered: XHotkeys.fixRequire()
                    }
                }
            }

            // ---- search + stats --------------------------------------------------------
            RowLayout {
                Layout.fillWidth: true
                visible: !hotkeysTabRoot.adding
                spacing: rootObj.s(10)

                Input {
                    Layout.fillWidth: true
                    implicitHeight: rootObj.s(38)
                    leadingIcon: "󰍉"
                    placeholderText: XHotkeys.t("hotkeys.search.placeholder", undefined, "Search: action, app or key…")
                    baseColor: ThemeBackend.surface0
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.text
                    subTextColor: ThemeBackend.subtext0
                    borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                    cornerRadius: ThemeBackend.borderRadius
                    fontPixelSize: XUi.fBody
                    onTextEdited: function(t) { hotkeysTabRoot.query = t; }
                }
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: XHotkeys.t("hotkeys.stats", { total: XHotkeys.totalCount, changed: XHotkeys.changedCount, own: XHotkeys.ownCount }, "")
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }

            // ---- list --------------------------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                visible: !hotkeysTabRoot.adding
                spacing: rootObj.s(6)

                Repeater {
                    model: XHotkeys.groups
                    delegate: HotkeyGroup {
                        required property var modelData
                        Layout.fillWidth: true
                        rootObj: hotkeysTabRoot.rootObj
                        groupData: modelData
                        query: hotkeysTabRoot.query
                        editingRef: hotkeysTabRoot.editingRef
                        onEditRequested: function(ref) { hotkeysTabRoot.editingRef = ref; }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: XHotkeys.bindsLoaded && XHotkeys.groups.length === 0
                    horizontalAlignment: Text.AlignHCenter
                    text: XHotkeys.t("hotkeys.empty", undefined, "No hotkeys found")
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fBody
                    color: ThemeBackend.subtext0
                }
            }

            // ---- new hotkey flow -------------------------------------------------------
            Loader {
                Layout.fillWidth: true
                active: hotkeysTabRoot.adding
                visible: active
                sourceComponent: AddPanel { onClosed: hotkeysTabRoot.adding = false }
            }

            Item { Layout.preferredHeight: rootObj.s(8) }
        }
    }
}
