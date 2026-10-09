import QtQuick
import "../../"
import ".."

// In-shell documentation viewer: the pages come from `serpantinum-x cmd docs --page` (hand-written concepts + node reference and
// recipes generated from the schema) and are shown as rendered Markdown (Qt MarkdownText); relative links switch pages.
Rectangle {
    id: dv
    color: ThemeBackend.base
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    function groupName(g) { return ({ "docs": "", "concepts": dv.t("cmd.docs.concepts", "Понятия"), "reference": dv.t("cmd.docs.reference", "Справочник узлов"), "recipes": "" })[g] || ""; }
    // a link like "reference/index.md" or "events.md" relative to the current page -> page id
    function resolve(link) {
        if (link.indexOf("http") === 0) return "";
        let base = XCmd.docId.indexOf("/") >= 0 ? XCmd.docId.slice(0, XCmd.docId.lastIndexOf("/") + 1) : "";
        let id = link.replace(/\.md$/, "");
        if (id.indexOf("reference/") !== 0 && base !== "" && id.indexOf("/") < 0) id = base + id;
        if (id === "reference/index") id = XCmd.docsPages.filter(p => p.group === "reference").length > 0 ? XCmd.docsPages.filter(p => p.group === "reference")[0].id : id;
        return id;
    }

    Rectangle { x: 0; y: 0; width: 264; height: parent.height; color: ThemeBackend.mantle
        Rectangle { x: parent.width - 1; width: 1; height: parent.height; color: Qt.alpha(ThemeBackend.text, 0.10) } }
    CmdBtn { x: 16; y: 16; kind: "ghost"; icon: "\u{f0141}"; text: dv.t("cmd.back", "Назад"); onClicked: XCmd.closeSub() }
    CT { x: 18; y: 66; text: dv.t("cmd.docs.title", "Документация"); size: 14; font.bold: true }
    Flickable {
        x: 0; y: 96; width: 264; height: parent.height - 96
        contentWidth: width; contentHeight: list.implicitHeight + 24
        clip: true; boundsBehavior: Flickable.StopAtBounds
        Column {
            id: list
            x: 10; width: parent.width - 20; spacing: 2
            Repeater {
                model: XCmd.docsPages
                delegate: Column {
                    width: list.width
                    CT { visible: modelData.group !== "docs" && (index === 0 || XCmd.docsPages[index - 1].group !== modelData.group) && dv.groupName(modelData.group) !== ""
                         height: visible ? 28 : 0; verticalAlignment: Text.AlignBottom; leftPadding: 8; text: dv.groupName(modelData.group); size: 10; c: ThemeBackend.subtext0 }
                    Rectangle {
                        width: parent.width; height: 32; radius: 8
                        readonly property bool on: XCmd.docId === modelData.id
                        color: on ? ThemeBackend.mauve : (m.containsMouse ? ThemeBackend.surface0 : "transparent")
                        CT { x: 12; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 24; size: 12; text: modelData.title; font.bold: parent.on; c: parent.on ? ThemeBackend.crust : ThemeBackend.text }
                        MouseArea { id: m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.loadDoc(modelData.id) }
                    }
                }
            }
        }
    }
    Flickable {
        id: page
        x: 264; y: 0; width: parent.width - 264; height: parent.height
        contentWidth: width; contentHeight: txt.implicitHeight + 64
        clip: true; boundsBehavior: Flickable.StopAtBounds
        Text {
            id: txt
            x: 40; y: 32; width: Math.min(page.width - 80, 860)
            textFormat: Text.MarkdownText; wrapMode: Text.WordWrap
            color: ThemeBackend.text; linkColor: ThemeBackend.mauve
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(13)
            text: XCmd.docLoading ? dv.t("cmd.loading", "Загрузка…") : XCmd.docText
            onLinkActivated: (link) => { const id = dv.resolve(link); if (id !== "") XCmd.loadDoc(id); }
            onTextChanged: page.contentY = 0
        }
    }
}
