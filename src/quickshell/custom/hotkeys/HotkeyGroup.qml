import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// A collapsible group of hotkeys ("Windows & workspaces", "Media" ...).
SettingsGroup {
    id: root
    objectName: "xGroup_" + groupData.id

    required property var groupData            // { id, icon, rows }
    property string query: ""
    property string editingRef: ""
    property bool userOpen: groupData.id === "mine"
    signal editRequested(string ref)

    function matches(r) {
        let q = query.trim().toLowerCase();
        if (q === "") return true;
        return (r.label + " " + r.detail + " " + XHotkeys.comboText(r.mods, r.key)).toLowerCase().indexOf(q) !== -1;
    }
    readonly property int matchCount: groupData.rows.filter(r => matches(r)).length

    searchable: false
    visible: query.trim() === "" || matchCount > 0
    expanded: userOpen
    forceOpen: query.trim() !== ""
    icon: groupData.icon
    title: XHotkeys.t("hotkeys.group." + groupData.id + ".title", undefined, groupData.id)
    description: XHotkeys.t("hotkeys.group." + groupData.id + ".desc", undefined, "")

    Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Math.max(Scaler.s(28), cnt.implicitWidth + Scaler.s(14))
        implicitHeight: Scaler.s(22)
        radius: Scaler.s(11)
        color: Qt.alpha(ThemeBackend.surface1, 0.7)
        Text {
            id: cnt
            anchors.centerIn: parent
            text: root.matchCount
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fCaption
            font.bold: true
            color: ThemeBackend.subtext1
        }
    }
    IconButton {
        Layout.alignment: Qt.AlignVCenter
        size: Scaler.s(24)
        Layout.preferredWidth: Scaler.s(24)
        Layout.preferredHeight: Scaler.s(24)
        cornerRadius: ThemeBackend.borderRadius
        buttonIcon: "\uf078"
        iconFontSize: XUi.fRow
        accentColor: "transparent"
        textColor: ThemeBackend.subtext0
        rotation: root.isOpen ? 180 : 0
        Behavior on rotation { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        onClicked: root.userOpen = !root.userOpen
    }

    subSettings: [
        Repeater {
            model: root.groupData.rows
            delegate: HotkeyRow {
                required property var modelData
                Layout.fillWidth: true
                rowData: modelData
                searchable: false
                visible: root.matches(modelData)
                editing: root.editingRef === modelData.ref
                onToggleEdit: root.editRequested(editing ? "" : modelData.ref)
            }
        }
    ]
}
