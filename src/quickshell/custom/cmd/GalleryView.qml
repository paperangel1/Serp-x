import QtQuick
import "../../"
import ".."

// Example gallery (C7): cards with description, trigger, required rights / packages / nodes, «Открыть» (read-only, with comment nodes)
// and «Добавить в мои команды» (a disabled copy). A command that waits for nodes of a later stage is marked «ждёт узлов».
Rectangle {
    id: gv
    color: ThemeBackend.base
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    readonly property var cats: { const s = ["all"]; for (let i = 0; i < XCmd.gallery.length; i++) if (s.indexOf(XCmd.gallery[i].category) < 0) s.push(XCmd.gallery[i].category); return s; }
    readonly property var shown: XCmd.gallery.filter(g => XCmd.galleryCat === "all" || g.category === XCmd.galleryCat)
    readonly property var catIcon: ({ "sound": "volume", "windows": "window", "files": "convert", "gemini": "function", "servers": "terminal", "screen": "moon" })
    function catName(c) { return gv.t("cmd.gallery.cat." + c, c); }
    readonly property real cw: Math.floor((width - 48 - 32) / 3)

    Rectangle { x: 0; y: 0; width: parent.width; height: 96; color: ThemeBackend.mantle
        Rectangle { x: 0; y: parent.height - 1; width: parent.width; height: 1; color: Qt.alpha(ThemeBackend.text, 0.10) } }
    CmdBtn { x: 20; y: 20; kind: "ghost"; icon: "\u{f0141}"; text: gv.t("cmd.back", "Назад"); onClicked: XCmd.closeSub() }
    CT { x: 130; y: 16; text: gv.t("cmd.gallery.title", "Галерея примеров"); size: 16; font.bold: true }
    CT { x: 130; y: 42; width: parent.width - 150; size: 11; c: ThemeBackend.subtext0
         text: gv.t("cmd.gallery.subtitle", "Откройте любой пример в редакторе: каждый шаг подписан комментариями, права показаны заранее") }
    Row {
        x: 130; y: 62; spacing: 8
        Repeater {
            model: gv.cats
            delegate: Rectangle {
                height: 26; width: lab.implicitWidth + 24; radius: 13
                readonly property bool on: XCmd.galleryCat === modelData
                color: on ? ThemeBackend.mauve : (cm.containsMouse ? ThemeBackend.surface1 : ThemeBackend.surface0)
                CT { id: lab; anchors.centerIn: parent; size: 11; c: parent.on ? ThemeBackend.crust : ThemeBackend.text; font.bold: parent.on
                     text: modelData === "all" ? gv.t("cmd.gallery.all", "Все · " + XCmd.gallery.length, { n: XCmd.gallery.length }) : gv.catName(modelData) }
                MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.galleryCat = modelData }
            }
        }
    }

    Flickable {
        x: 0; y: 96; width: parent.width; height: parent.height - 96
        contentWidth: width; contentHeight: flow.implicitHeight + 48
        clip: true; boundsBehavior: Flickable.StopAtBounds
        Flow {
            id: flow
            x: 24; y: 24; width: parent.width - 48; spacing: 16
            Repeater {
                model: gv.shown
                delegate: Rectangle {
                    id: card
                    readonly property var g: modelData
                    readonly property var missingPkgs: g.packages.filter(p => !p.installed)
                    width: gv.cw; height: 232; radius: 14
                    color: ThemeBackend.mantle
                    border.width: 1; border.color: hov.containsMouse ? Qt.alpha(ThemeBackend.mauve, 0.6) : Qt.alpha(ThemeBackend.text, 0.10)
                    MouseArea { id: hov; anchors.fill: parent; hoverEnabled: true }
                    Rectangle { x: 16; y: 16; width: 40; height: 40; radius: 10; color: ThemeBackend.surface0
                        CT { anchors.centerIn: parent; icon: true; text: CK.glyph(gv.catIcon[card.g.category] || "unknown"); size: 19; c: ThemeBackend.mauve } }
                    CT { x: 68; y: 14; width: parent.width - 84; text: card.g.name; size: 13; font.bold: true }
                    Row {
                        x: 68; y: 36; spacing: 6
                        CmdChip { text: card.g.events.length > 0 ? "⚡ " + card.g.events.length + " " + gv.t("cmd.gallery.events", "событий") : "⚡ " + gv.t("cmd.gallery.manual", "вручную"); tone: "#f38ba8" }
                        CmdChip { text: card.g.ready ? gv.t("cmd.gallery.ready", "готова") : gv.t("cmd.gallery.pending", "ждёт узлов"); tone: card.g.ready ? "#a6e3a1" : "#f9e2af" }
                    }
                    CT { x: 16; y: 68; width: parent.width - 32; height: 48; wrapMode: Text.WordWrap; maximumLineCount: 3; size: 11; c: ThemeBackend.subtext1; text: card.g.description }
                    CT { visible: !card.g.ready; x: 16; y: 120; width: parent.width - 32; wrapMode: Text.WordWrap; maximumLineCount: 2; size: 10; c: "#f9e2af"
                         text: gv.t("cmd.gallery.needs_nodes", "Ждёт узлов: " + card.g.missing.length, { n: card.g.missing.length }) + " · " + card.g.missing.map(m => m.replace(/^(action|event|data)\./, "")).join(", ") }
                    CT { visible: card.g.packages.length > 0; x: 16; y: card.g.ready ? 120 : 150; width: parent.width - 32; size: 10
                         c: card.missingPkgs.length > 0 ? "#f38ba8" : ThemeBackend.subtext0
                         text: gv.t("cmd.gallery.packages", "Пакеты: ") + card.g.packages.map(p => p.name + (p.installed ? "" : " (" + gv.t("cmd.gallery.not_installed", "не установлен") + ")")).join(", ") }
                    Flow {
                        x: 16; y: 172; width: parent.width - 32; spacing: 6
                        Repeater { model: card.g.tags; delegate: CmdChip { text: modelData; tone: ThemeBackend.subtext1 } }
                        CmdChip { visible: card.g.capabilities.length > 0; text: gv.t("cmd.gallery.rights", "прав: " + card.g.capabilities.length, { n: card.g.capabilities.length }); tone: "#89b4fa" }
                    }
                    CT { x: 16; y: card.height - 26; size: 10; c: ThemeBackend.subtext0; text: gv.t("cmd.row.nodes", card.g.nodes + " узлов", { n: card.g.nodes }) }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 12; y: card.height - 42; spacing: 6
                        CmdBtn { h: 28; padX: 10; kind: "ghost"; text: gv.t("cmd.gallery.add", "Добавить"); onClicked: XCmd.addGallery(card.g.id) }
                        CmdBtn { h: 28; padX: 10; kind: "primary"; text: gv.t("cmd.gallery.open", "Открыть →"); onClicked: XCmd.openGraph(card.g.file) }
                    }
                }
            }
        }
    }
}
