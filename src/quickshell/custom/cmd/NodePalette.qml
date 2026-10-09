import QtQuick
import "../../"
import ".."
import "EditorLogic.js" as EL

// Node search palette of the editor (C2): type to filter the node catalogue (names, descriptions, ids; Russian and English),
// Up/Down choose, Enter adds the node at the pointer. Opened from a dragged wire it only lists nodes that can take the wire
// (and wires the new node up automatically). The first row «Комментарий» adds a comment box.
Rectangle {
    id: pal
    property bool shown: false
    property var fromPin: null          // {node, pin, out, t, full} when opened by dropping a wire
    property real wx: 0
    property real wy: 0
    signal chosen(var entry, string pinId, real wx, real wy)
    signal commentChosen(real wx, real wy)
    signal closed()

    visible: shown
    width: 440
    height: Math.min(440, 112 + Math.max(1, results.length) * 48)
    radius: 14
    color: ThemeBackend.mantle
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.mauve, 0.55)
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    property int cur: 0
    property string query: ""
    readonly property var results: {
        var list = [], cat = XCmd.catalog, q = query.trim().toLowerCase(), i;
        if (fromPin) {
            var ents = EL.entriesFor(cat, fromPin.full, fromPin.out, XEdit.paletteOpts), toks = q === "" ? [] : q.split(/\s+/);
            for (i = 0; i < ents.length; i++) {
                var ok = true;
                for (var k = 0; k < toks.length; k++) if (ents[i].entry.search.indexOf(toks[k]) < 0) ok = false;
                if (ok) list.push({ entry: ents[i].entry, pin: ents[i].pin });
            }
            list.sort(function (a, b) { return a.entry.title < b.entry.title ? -1 : 1; });
        } else {
            var found = EL.searchCatalog(cat, q, 40, XEdit.paletteOpts);
            if (q === "" || "комментарий заметка comment note".indexOf(q) >= 0) list.push({ comment: true });
            for (i = 0; i < found.length; i++) list.push({ entry: found[i], pin: "" });
        }
        return list;
    }
    onResultsChanged: cur = 0

    function openAt(px, py, from) {
        wx = px; wy = py; fromPin = from || null;
        query = ""; input.text = ""; cur = 0; shown = true;
        Qt.callLater(function () { input.forceActiveFocus(); });
    }
    function close() { if (!shown) return; shown = false; closed(); }
    function pick(i) {
        if (i < 0 || i >= results.length) return;
        var r = results[i];
        shown = false;
        if (r.comment) commentChosen(wx, wy); else chosen(r.entry, r.pin, wx, wy);
        closed();
    }

    Rectangle {
        x: 12; y: 12; width: parent.width - 24; height: 40; radius: 10; color: ThemeBackend.surface0
        CT { x: 12; y: 10; icon: true; text: "\u{f0349}"; size: 17; c: ThemeBackend.subtext1 }
        TextInput {
            id: input
            x: 40; y: 0; width: parent.width - 150; height: parent.height
            verticalAlignment: TextInput.AlignVCenter
            color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(13)
            clip: true
            onTextChanged: pal.query = text
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Down) { pal.cur = Math.min(pal.results.length - 1, pal.cur + 1); e.accepted = true; }
                else if (e.key === Qt.Key_Up) { pal.cur = Math.max(0, pal.cur - 1); e.accepted = true; }
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { pal.pick(pal.cur); e.accepted = true; }
                else if (e.key === Qt.Key_Escape) { pal.close(); e.accepted = true; }
            }
            CT { visible: input.text === ""; anchors.verticalCenter: parent.verticalCenter; size: 13; c: ThemeBackend.subtext0
                 text: pal.fromPin ? pal.t("cmd.palette.hint_pin", "Что подключить к этому выводу?") : pal.t("cmd.palette.hint", "Найти узел…") }
        }
        CT { anchors.right: parent.right; anchors.rightMargin: 12; y: 13; size: 10; c: ThemeBackend.subtext0; text: pal.t("cmd.palette.enter", "Enter — добавить") }
    }

    ListView {
        id: list
        x: 8; y: 62; width: parent.width - 16; height: parent.height - 62 - 34
        clip: true
        model: pal.results
        currentIndex: pal.cur
        boundsBehavior: Flickable.StopAtBounds
        highlightMoveDuration: 0
        delegate: Rectangle {
            id: item
            width: list.width; height: 48; radius: 10
            readonly property bool active: index === pal.cur
            color: active ? Qt.alpha(ThemeBackend.mauve, 0.14) : (ma.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.6) : "transparent")
            border.width: active ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.6)
            readonly property bool isComment: !!modelData.comment
            readonly property color tone: isComment ? "#f9e2af" : CK.cc(modelData.entry.category)
            Rectangle { x: 10; y: 8; width: 32; height: 32; radius: 9; color: Qt.alpha(parent.tone, 0.16)
                CT { anchors.centerIn: parent; icon: true; size: 16; c: item.tone; text: item.isComment ? "\u{f06e8}" : CK.glyph(modelData.entry.icon) } }
            CT { x: 54; y: 7; width: parent.width - 66; size: 12; font.bold: true
                 text: item.isComment ? pal.t("cmd.palette.comment", "Комментарий") : modelData.entry.title }
            CT { x: 54; y: 26; width: parent.width - 66; size: 10; c: ThemeBackend.subtext0
                 text: item.isComment ? pal.t("cmd.palette.comment_hint", "Заметка на холсте: объясните, как работает команда")
                                        : modelData.entry.kind + (modelData.entry.cap_names.length > 0 ? " · " + modelData.entry.cap_names.join(", ") : "") + (modelData.entry.deferred ? " · " + pal.t("cmd.node.deferred", "позже") : "") }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onEntered: pal.cur = index; onClicked: pal.pick(index) }
        }
        CT { visible: pal.results.length === 0; anchors.centerIn: parent; size: 12; c: ThemeBackend.subtext0
             text: pal.t("cmd.palette.none", "Ничего не найдено") }
    }
    CT {
        x: 16; y: parent.height - 26; size: 10; c: ThemeBackend.subtext0
        text: pal.t("cmd.palette.count", pal.results.length + " из " + Object.keys(XCmd.catalog).length + " узлов · ↑↓ выбрать · Esc закрыть", { n: pal.results.length, total: Object.keys(XCmd.catalog).length })
    }
}
