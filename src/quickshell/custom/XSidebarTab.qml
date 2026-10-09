import QtQuick
import QtQuick.Layouts
import "../"
import "../reusables"

// Visual copy of the stock sidebar tab Rectangle in guide/GuidePopup.qml
// (same sizes, tokens, animations) so appended tabs are indistinguishable.
Rectangle {
    id: tab

    required property var guide
    required property int tabIndex
    property string labelKey: ""
    property string labelFallback: ""
    property string icon: ""
    property int iconOffsetX: 0
    property bool showDot: false

    readonly property bool isDirectActive: guide.currentTab === tabIndex

    Layout.fillWidth: true
    Layout.preferredHeight: guide.s(44)
    implicitHeight: guide.s(44)
    radius: ThemeBackend.borderRadius
    z: 1

    opacity: guide.getTabOpacity(tabIndex)
    transform: Translate { x: guide.s(-24) * (1.0 - guide.getTabProgress(tabIndex)) }

    color: tabMa.containsMouse && !isDirectActive ? Qt.alpha(ThemeBackend.surface1, 0.5) : "transparent"
    Behavior on color { ColorAnimation { duration: 150 } }

    scale: tabMa.pressed ? 0.98 : 1.0
    Behavior on scale { NumberAnimation { duration: 250; easing.type: Easing.OutQuint } }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: guide.s(10) + (tab.isDirectActive ? guide.s(4) : 0)
        anchors.rightMargin: guide.s(14)
        spacing: guide.s(10)

        Behavior on anchors.leftMargin { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }

        IconButton {
            enabled: false
            size: guide.s(32)
            Layout.preferredWidth: guide.s(32)
            Layout.preferredHeight: guide.s(32)
            Layout.alignment: Qt.AlignVCenter
            cornerRadius: ThemeBackend.borderRadius
            buttonIcon: tab.icon
            iconOffsetX: tab.iconOffsetX
            iconFontSize: XUi.fTitle
            accentColor: ThemeBackend.surface0
            textColor: "#ffffff"
        }

        Text {
            text: XI18n.t(tab.labelKey, undefined, tab.labelFallback)
            font.family: ThemeBackend.fontFamily
            font.weight: tab.isDirectActive ? Font.Bold : Font.Medium
            font.pixelSize: XUi.fRow
            color: tab.isDirectActive
                ? ThemeBackend.crust
                : (tabMa.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0)
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            elide: Text.ElideRight
            Behavior on color { ColorAnimation { duration: 150 } }
        }

        Rectangle {
            visible: tab.showDot
            Layout.preferredWidth: guide.s(8)
            Layout.preferredHeight: guide.s(8)
            Layout.alignment: Qt.AlignVCenter
            radius: width / 2
            color: tab.isDirectActive ? ThemeBackend.crust : ThemeBackend.mauve
            Behavior on color { ColorAnimation { duration: 150 } }
            SequentialAnimation on opacity {
                running: tab.showDot
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
            }
        }
    }

    MouseArea {
        id: tabMa
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            tab.guide.expandedTab = -1;
            tab.guide.currentTab = tab.tabIndex;
            tab.guide.currentSubTab = 0;
        }
    }
}
