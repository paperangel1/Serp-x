import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// List of changelog items: [type chip | text]. The chips have one fixed width so the text
// column starts on the same vertical line in every row.
ColumnLayout {
    id: cv
    required property var rootObj
    property var changelog: null         // result of x_changelog.sh get
    property bool showOriginal: false
    property int maxItems: 0             // 0 = all
    property int chipWidth: rootObj.s(52)

    readonly property var items: changelog && changelog.items ? changelog.items : []
    readonly property int shown: maxItems > 0 ? Math.min(maxItems, items.length) : items.length

    spacing: rootObj.s(8)

    // The Matugen palette maps tokens non-semantically (some are dark); fall back to the text
    // colour whenever a token would be unreadable on the dark card.
    function bright(c) { return c.hslLightness > 0.55 ? c : ThemeBackend.text; }
    function chipColor(type) {
        let t = (type || "").split("/")[0];
        return bright(rawChipColor(t));
    }
    function rawChipColor(t) {
        switch (t) {
        case "feat": return ThemeBackend.mauve;
        case "fix": return ThemeBackend.red;
        case "perf": return ThemeBackend.green;
        case "style": return ThemeBackend.peach;
        case "refactor": return ThemeBackend.blue;
        case "i18n": return ThemeBackend.sapphire;
        case "chore": case "docs": case "build": case "ci": case "test": return ThemeBackend.overlay1;
        default: return ThemeBackend.subtext0;
        }
    }
    function cap(t) { return t && t.length > 0 ? t.charAt(0).toUpperCase() + t.slice(1) : ""; }

    Repeater {
        model: cv.shown
        delegate: RowLayout {
            required property int index
            readonly property var it: cv.items[index]
            Layout.fillWidth: true
            spacing: cv.rootObj.s(12)

            Rectangle {
                Layout.preferredWidth: cv.chipWidth
                Layout.preferredHeight: cv.rootObj.s(20)
                Layout.alignment: Qt.AlignTop
                radius: cv.rootObj.s(6)
                color: Qt.alpha(cv.chipColor(it.type), 0.16)
                Text {
                    anchors.centerIn: parent
                    text: it.type ? it.type.split("/")[0] : "·"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: XUi.fCaption
                    font.bold: true
                    color: cv.chipColor(it.type)
                }
            }
            Text {
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignTop
                text: cv.cap(cv.showOriginal ? (it.original || it.text) : it.text)
                wrapMode: Text.WordWrap
                lineHeight: 1.1
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fRow
                color: ThemeBackend.text
            }
        }
    }
}
