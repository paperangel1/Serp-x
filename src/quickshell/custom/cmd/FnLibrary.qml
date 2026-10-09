import QtQuick
import "../../"
import ".."
import "EditorLogic.js" as EL

// Function library (custom nodes): the list of reusable functions with rename / duplicate / export / delete (with a usage
// check) and import. A function becomes a node in the palette of every command; «Открыть» shows its graph in the canvas.
Item {
    id: lib
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    property string query: ""
    readonly property var list: XCmd.functions.filter(f => query.trim() === "" || (f.name + " " + f.description).toLowerCase().indexOf(query.trim().toLowerCase()) >= 0)

    Rectangle {
        x: 16; y: 16; width: parent.width - 32 - btnRow.width - 12; height: 40; radius: 10
        color: ThemeBackend.surface0
        border.width: search.activeFocus ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.6)
        CT { x: 12; y: 10; icon: true; text: "\u{f0349}"; size: 17; c: ThemeBackend.subtext1 }
        TextInput {
            id: search
            x: 40; y: 0; width: parent.width - 52; height: parent.height
            verticalAlignment: TextInput.AlignVCenter
            color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(12)
            clip: true
            onTextChanged: lib.query = text
            CT { visible: search.text === ""; anchors.verticalCenter: parent.verticalCenter; text: lib.t("cmd.fn.search", "Поиск по функциям"); size: 12; c: ThemeBackend.subtext0 }
        }
    }
    Row {
        id: btnRow
        anchors.right: parent.right; anchors.rightMargin: 16; y: 20; spacing: 10
        CmdBtn { kind: "ghost"; icon: "\u{f0207}"; text: lib.t("cmd.fn.import", "Импорт функции"); onClicked: XCmd.dialog = { kind: "fn_import" } }
    }

    Flickable {
        id: fl
        x: 0; y: 72; width: parent.width; height: parent.height - 72
        contentWidth: width; contentHeight: col.implicitHeight + 32
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 16; width: fl.width - 32; spacing: 8
            CT { x: 2; width: parent.width; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideNone
                 text: lib.t("cmd.fn.note", "Функция — свёрнутая группа узлов. Чтобы создать её, выделите узлы в редакторе и нажмите «Свернуть в узел» (Ctrl+G). Права функции — это права всех её узлов.") }
            Repeater {
                model: lib.list
                delegate: Rectangle {
                    id: row
                    width: col.width; height: 92; radius: 12
                    color: ma.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.55) : ThemeBackend.base
                    border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.10)
                    Rectangle { x: 16; y: 14; width: 40; height: 40; radius: 10; color: Qt.alpha("#94e2d5", 0.14)
                        CT { anchors.centerIn: parent; icon: true; text: CK.glyph(modelData.icon || "function"); size: 19; c: "#94e2d5" } }
                    CT { x: 68; y: 11; width: parent.width - 460; text: modelData.name; size: 12; font.bold: true }
                    CT { x: 68; y: 29; width: parent.width - 460; text: modelData.description !== "" ? modelData.description : lib.t("cmd.row.no_desc", "без описания"); size: 11; c: ThemeBackend.subtext1 }
                    Flow {
                        x: 68; y: 48; width: parent.width - 460; spacing: 6
                        Repeater {
                            model: modelData.inputs
                            delegate: CmdChip { text: "→ " + (modelData.label || modelData.id) + " · " + EL.typeName(modelData.type, XCmd.lang); tone: CK.tc(modelData.type) }
                        }
                        Repeater {
                            model: modelData.outputs
                            delegate: CmdChip { text: "← " + (modelData.label || modelData.id) + " · " + EL.typeName(modelData.type, XCmd.lang); tone: CK.tc(modelData.type) }
                        }
                    }
                    Row {
                        x: 68; y: 68; spacing: 6
                        CmdChip { text: lib.t("cmd.row.nodes", modelData.nodes + " узлов", { n: modelData.nodes }); tone: "#9399b2" }
                        CmdChip { visible: !modelData.exec; text: lib.t("cmd.fn.pure", "без порядка выполнения"); tone: "#9399b2" }
                        CmdChip { visible: !modelData.ok; text: lib.t("cmd.fn.broken", "есть ошибки"); tone: "#f38ba8" }
                        CmdChip { visible: modelData.imported; text: lib.t("cmd.fn.imported_badge", "импортирована"); tone: "#f9e2af" }
                        Repeater { model: modelData.capabilities; delegate: CmdChip { text: modelData; tone: "#89b4fa" } }
                    }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 16; y: 12; spacing: 6
                        CmdBtn { h: 28; padX: 10; kind: "primary"; icon: "\u{f03eb}"; text: lib.t("cmd.fn.open_btn", "Открыть"); onClicked: XCmd.openFunction(modelData.id) }
                        CmdBtn { h: 28; padX: 10; kind: "ghost"; text: lib.t("cmd.fn.rename", "Переименовать"); onClicked: XCmd.dialog = { kind: "fn_rename", ref: modelData.id, name: modelData.name } }
                    }
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 16; y: 52; spacing: 6
                        CmdBtn { h: 28; padX: 10; kind: "ghost"; text: lib.t("cmd.fn.duplicate", "Копия"); onClicked: XCmd.fnDuplicate(modelData.id) }
                        CmdBtn { h: 28; padX: 10; kind: "ghost"; icon: "\u{f0206}"; text: lib.t("cmd.fn.export", "Экспорт"); onClicked: XCmd.dialog = { kind: "fn_export", ref: modelData.id, name: modelData.name } }
                        CmdBtn { h: 28; padX: 10; kind: "ghost"; icon: "\u{f01b4}"; text: lib.t("cmd.fn.delete", "Удалить"); onClicked: XCmd.fnAskDelete(modelData.id) }
                    }
                    MouseArea { id: ma; anchors.fill: parent; z: -1; hoverEnabled: true; onDoubleClicked: XCmd.openFunction(modelData.id) }
                }
            }
            Item {   // empty state
                visible: lib.list.length === 0 && XCmd.loaded
                width: col.width; height: 200
                CT { anchors.horizontalCenter: parent.horizontalCenter; y: 50; icon: true; text: "\u{f0295}"; size: 40; c: ThemeBackend.surface1 }
                CT { anchors.horizontalCenter: parent.horizontalCenter; y: 106; size: 13; font.bold: true; text: lib.query !== "" ? lib.t("cmd.empty.search", "Ничего не найдено") : lib.t("cmd.fn.empty", "Функций пока нет") }
                CT { visible: lib.query === ""; anchors.horizontalCenter: parent.horizontalCenter; y: 132; width: parent.width - 80; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     size: 11; c: ThemeBackend.subtext0; text: lib.t("cmd.fn.empty_hint", "Выделите узлы в редакторе и нажмите «Свернуть в узел» — получится функция, которую можно использовать в других командах.") }
            }
        }
    }
}
