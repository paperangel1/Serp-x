import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../../"
import "../../reusables"
import ".."

// «Предыдущие версии»: pick a version on the left, read its (translated) changelog on the right.
ColumnLayout {
    id: vp
    required property var rootObj
    signal back()

    property bool showOriginal: false
    readonly property int panelHeight: rootObj.s(540)

    spacing: rootObj.s(10)
    Component.onCompleted: XUpdate.loadVersions()

    SettingsRow {
        rootObj: vp.rootObj
        icon: "󰋚"
        title: XI18n.t("update.older_title", undefined, "Previous versions")
        description: XI18n.t("update.older_desc", undefined, "Pick a version to read the list of its changes")
        titlePixelSize: XUi.fSub
        ClickButton {
            buttonText: XI18n.t("update.back", undefined, "Back")
            buttonIcon: "󰁍"
            Layout.preferredHeight: vp.rootObj.s(34)
            cornerRadius: ThemeBackend.borderRadius
            textFontSize: XUi.fRow
            onClicked: vp.back()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: vp.rootObj.s(10)

        // ---- versions list ----
        XCard {
            rootObj: vp.rootObj
            Layout.preferredWidth: vp.rootObj.s(236)
            Layout.maximumWidth: vp.rootObj.s(236)
            Layout.fillWidth: false
            Layout.alignment: Qt.AlignTop
            implicitHeight: vp.panelHeight
            pad: vp.rootObj.s(10)
            contentSpacing: vp.rootObj.s(8)

            Text {
                text: XI18n.t("update.versions_header", undefined, "VERSIONS")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.bold: true
                color: ThemeBackend.overlay1
                leftPadding: vp.rootObj.s(4)
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: vp.rootObj.s(4)
                boundsBehavior: Flickable.StopAtBounds
                model: XUpdate.versions
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: XUpdate.selectedVersion === modelData.version
                    width: list.width
                    height: vp.rootObj.s(40)
                    radius: ThemeBackend.borderRadius
                    color: sel ? ThemeBackend.mauve : (ma.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.5) : "transparent")
                    Behavior on color { ColorAnimation { duration: 150 } }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: vp.rootObj.s(12)
                        anchors.rightMargin: vp.rootObj.s(12)
                        Text {
                            text: modelData.version
                            Layout.fillWidth: true
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow
                            font.bold: sel
                            color: sel ? ThemeBackend.crust : ThemeBackend.text
                        }
                        Text {
                            text: modelData.count
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
                            color: sel ? Qt.alpha(ThemeBackend.crust, 0.7) : ThemeBackend.overlay1
                        }
                    }
                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: XUpdate.selectVersion(modelData.version)
                    }
                }
            }
            Text {
                visible: list.contentHeight > list.height + 1 && !list.atYEnd
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: XI18n.t("update.more_versions", { n: Math.max(0, XUpdate.versions.length - Math.floor(list.height / (vp.rootObj.s(44)))) }, "scroll for more ↓")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                color: ThemeBackend.overlay1
            }
        }

        // ---- changelog of the selected version ----
        XCard {
            rootObj: vp.rootObj
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            implicitHeight: vp.panelHeight
            pad: vp.rootObj.s(14)

            RowLayout {
                Layout.fillWidth: true
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: vp.rootObj.s(2)
                    Text {
                        text: XI18n.t("update.version_title", { v: XUpdate.selectedVersion }, "Version " + XUpdate.selectedVersion)
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fTitle; font.bold: true
                        color: ThemeBackend.text
                    }
                    Text {
                        readonly property var d: XUpdate.selectedChangelog
                        text: XUpdate.selectedLoading || !d ? XI18n.t("update.loading", undefined, "Loading…")
                            : XI18n.t("update.n_changes", { n: d.count }, d.count + " changes") + "  ·  " + (d.source === "cache"
                                ? XI18n.t("update.src_cache", undefined, "translation from cache")
                                : d.source === "gemini" ? XI18n.t("update.src_gemini", undefined, "translated by Gemini")
                                : (d.lang === "en" ? XI18n.t("update.src_original", undefined, "original") : XI18n.t("update.src_unavailable", undefined, "translation unavailable — original shown")))
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
                        color: ThemeBackend.subtext0
                    }
                }
                Text {
                    text: XI18n.t("update.original", undefined, "Original")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
                    color: ThemeBackend.subtext0
                    Layout.alignment: Qt.AlignVCenter
                }
                Toggle {
                    Layout.alignment: Qt.AlignVCenter
                    checked: vp.showOriginal
                    accentColor: ThemeBackend.mauve
                    baseColor: ThemeBackend.surface1
                    handleColor: ThemeBackend.crust
                    handleOffColor: ThemeBackend.text
                    onToggled: function(c) { vp.showOriginal = c; }
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(ThemeBackend.surface1, 0.4) }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: cv.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ChangelogView {
                    id: cv
                    width: parent.width
                    rootObj: vp.rootObj
                    changelog: XUpdate.selectedChangelog
                    showOriginal: vp.showOriginal
                }
            }

            RowLayout {
                spacing: vp.rootObj.s(8)
                Text { text: "󰗊"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fRow; color: ThemeBackend.mauve }
                Text {
                    text: XI18n.t("update.translated_note", undefined, "Translated by Gemini. The original is shown if the translation is unavailable.")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay1
                    Layout.fillWidth: true; elide: Text.ElideRight
                }
            }
        }
    }
}
