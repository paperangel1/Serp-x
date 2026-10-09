import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// Search + grid of installed applications (DesktopEntries).
ColumnLayout {
    id: root

    property string selectedId: ""
    property int columns: 4
    property string query: ""
    signal picked(string id)

    spacing: Scaler.s(8)

    readonly property var filtered: {
        let q = root.query.trim().toLowerCase();
        let all = XHotkeys.apps;
        if (q === "") return all;
        return all.filter(a => a.name.toLowerCase().indexOf(q) !== -1 || a.comment.toLowerCase().indexOf(q) !== -1 || a.execBase.toLowerCase().indexOf(q) !== -1);
    }

    Input {
        Layout.fillWidth: true
        implicitHeight: Scaler.s(36)
        leadingIcon: "󰍉"
        placeholderText: XHotkeys.t("hotkeys.add.search_app", undefined, "Find an app…")
        baseColor: ThemeBackend.surface0
        accentColor: ThemeBackend.mauve
        textColor: ThemeBackend.text
        subTextColor: ThemeBackend.subtext0
        borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
        cornerRadius: ThemeBackend.borderRadius
        fontPixelSize: XUi.fBody
        onTextEdited: function(t) { root.query = t; }
    }

    Flickable {
        id: flick
        Layout.fillWidth: true
        Layout.preferredHeight: Scaler.s(116)
        contentWidth: width
        contentHeight: grid.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        GridLayout {
            id: grid
            width: flick.width
            columns: root.columns
            columnSpacing: Scaler.s(8)
            rowSpacing: Scaler.s(8)

            Repeater {
                model: root.filtered
                delegate: Rectangle {
                    id: cell
                    required property var modelData
                    readonly property bool sel: root.selectedId === modelData.id
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: Scaler.s(54)
                    radius: ThemeBackend.borderRadius
                    color: sel ? Qt.alpha(ThemeBackend.mauve, 0.12) : (cellHover.hovered ? Qt.alpha(ThemeBackend.surface1, 0.5) : Qt.alpha(ThemeBackend.surface0, 0.5))
                    border.width: 1
                    border.color: sel ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.5)
                    Behavior on color { ColorAnimation { duration: 140 } }
                    Behavior on border.color { ColorAnimation { duration: 140 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Scaler.s(8)
                        anchors.rightMargin: Scaler.s(8)
                        spacing: Scaler.s(8)

                        AppIcon {
                            size: 34
                            icon: cell.modelData.icon
                            glyph: "󰀻"
                            selected: false
                            Layout.alignment: Qt.AlignVCenter
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            Layout.alignment: Qt.AlignVCenter
                            spacing: Scaler.s(1)
                            Text {
                                Layout.fillWidth: true
                                text: cell.modelData.name
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: XUi.fBody
                                font.bold: true
                                color: ThemeBackend.text
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: cell.modelData.comment
                                visible: text !== ""
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: XUi.fCaption
                                color: ThemeBackend.subtext0
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            visible: cell.sel
                            text: "󰄬"
                            font.family: ThemeBackend.iconFont
                            font.pixelSize: XUi.fSub
                            color: ThemeBackend.mauve
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }

                    HoverHandler { id: cellHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.picked(cell.modelData.id) }
                }
            }
        }
    }

    Text {
        visible: root.filtered.length === 0
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        text: XHotkeys.t("hotkeys.add.no_apps", undefined, "Nothing found")
        font.family: ThemeBackend.fontFamily
        font.pixelSize: XUi.fBody
        color: ThemeBackend.subtext0
    }
}
