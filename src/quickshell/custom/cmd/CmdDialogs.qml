import QtQuick
import Quickshell
import "../../"
import ".."

// Modal dialogs of the Commands window (XCmd.dialog): new | rename | delete | import | export | permission | unsaved | imported,
// and for functions: fn_collapse | fn_rename | fn_delete | fn_import | fn_export | fn_unsaved.
// Everything is confirmed with Enter / cancelled with Esc; engine errors (name taken, bad file, ...) stay in the dialog.
FocusScope {
    id: dlg
    readonly property var d: XCmd.dialog
    readonly property string kind: d ? d.kind : ""
    visible: d !== null
    anchors.fill: parent
    z: 100
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    property var candidates: []
    property string tpl: ""                 // chosen template for «new»: "" = empty, otherwise the example file

    function cancel() { XCmd.dialog = null; }
    function confirm() {
        if (kind === "new") XCmd.createCommand(nameIn.text, tpl);
        else if (kind === "rename") XCmd.renameCommand(d.ref, nameIn.text);
        else if (kind === "delete") XCmd.deleteCommand(d.ref);
        else if (kind === "import") XCmd.importFile(pathIn.text.trim());
        else if (kind === "export") XCmd.exportCommand(d.ref, pathIn.text.trim());
        else if (kind === "permission") XCmd.approveAndEnable(d.ref);
        else if (kind === "unsaved") XEdit.save(function () { XCmd.dialog = null; XCmd.stopEdit(); XCmd.screen = "list"; });
        else if (kind === "imported") cancel();
        else if (kind === "fn_collapse") XCmd.collapseConfirm(nameIn.text, descIn.text);
        else if (kind === "fn_rename") XCmd.fnRename(d.ref, nameIn.text);
        else if (kind === "fn_delete") XCmd.fnDelete(d.ref);
        else if (kind === "fn_import") XCmd.fnImport(pathIn.text.trim());
        else if (kind === "fn_export") XCmd.fnExport(d.ref, pathIn.text.trim());
        else if (kind === "fn_unsaved") XEdit.save(function () { XCmd.dialog = null; XCmd.popFunction(); });
    }
    function discard() {
        if (kind === "fn_unsaved") { XCmd.dialog = null; XCmd.popFunction(); return; }
        XCmd.dialog = null; XCmd.stopEdit(); XCmd.screen = "list";
    }
    readonly property bool isNameKind: kind === "new" || kind === "rename" || kind === "fn_collapse" || kind === "fn_rename"
    readonly property bool isPathKind: kind === "import" || kind === "export" || kind === "fn_import" || kind === "fn_export"

    onDChanged: {
        if (d === null) return;
        if (d.error !== undefined) return;                // an error update of the same dialog keeps the fields
        tpl = "";
        nameIn.text = d.name !== undefined && (d.kind === "rename" || d.kind === "fn_rename") ? d.name : "";
        descIn.text = "";
        let p = "";
        if (d.kind === "export") {
            const home = Quickshell.env("HOME") || "";
            p = home + "/Documents/" + (d.name || "command").toLowerCase().replace(/[^\wа-яё-]+/gi, "-").replace(/^-+|-+$/g, "") + ".scmd";
        }
        if (d.kind === "fn_export") {
            const home2 = Quickshell.env("HOME") || "";
            p = home2 + "/Documents/" + (d.name || "function").toLowerCase().replace(/[^\wа-яё-]+/gi, "-").replace(/^-+|-+$/g, "") + ".sfn";
        }
        pathIn.text = p;
        if (d.kind === "import") XCmd.cli(["import-candidates"], r => dlg.candidates = r.files || [], m => dlg.candidates = []);
        Qt.callLater(function () {
            if (dlg.isNameKind) { nameIn.forceActiveFocus(); nameIn.selectAll(); }
            else if (dlg.isPathKind) { pathIn.forceActiveFocus(); pathIn.cursorPosition = pathIn.text.length; }
            else dlg.forceActiveFocus();
        });
    }
    Keys.onEscapePressed: dlg.cancel()
    Keys.onReturnPressed: dlg.confirm()
    Keys.onEnterPressed: dlg.confirm()

    Rectangle { anchors.fill: parent; color: Qt.alpha("#000000", 0.55)
        MouseArea { anchors.fill: parent; onClicked: { if (dlg.kind !== "unsaved" && dlg.kind !== "fn_unsaved") dlg.cancel(); } } }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: 520
        height: head.height + body.height + foot.height + 8
        radius: 16
        color: ThemeBackend.mantle
        border.width: 1; border.color: Qt.alpha(dlg.kind === "delete" || dlg.kind === "fn_delete" ? "#f38ba8" : ThemeBackend.mauve, 0.5)
        MouseArea { anchors.fill: parent }

        Item {
            id: head
            x: 0; y: 0; width: parent.width; height: 64
            Rectangle { x: 20; y: 16; width: 34; height: 34; radius: 10; color: Qt.alpha(dlg.kind === "delete" || dlg.kind === "permission" ? "#f38ba8" : ThemeBackend.mauve, 0.16)
                CT { anchors.centerIn: parent; icon: true; size: 18; c: dlg.kind === "delete" || dlg.kind === "permission" ? "#f38ba8" : ThemeBackend.mauve
                     text: ({ "new": "\u{f0415}", "rename": "\u{f03eb}", "delete": "\u{f01b4}", "import": "\u{f0207}", "export": "\u{f0206}", "permission": "\u{f0498}",
                              "unsaved": "\u{f0193}", "imported": "\u{f0026}", "fn_collapse": "\u{f03d7}", "fn_rename": "\u{f03eb}", "fn_delete": "\u{f01b4}",
                              "fn_import": "\u{f0207}", "fn_export": "\u{f0206}", "fn_unsaved": "\u{f0193}" })[dlg.kind] || "\u{f0493}" } }
            CT { x: 66; y: 20; width: parent.width - 90; size: 14; font.bold: true
                 text: ({ "new": dlg.t("cmd.dlg.new", "Новая команда"), "rename": dlg.t("cmd.dlg.rename", "Переименовать команду"),
                          "delete": dlg.t("cmd.dlg.delete", "Удалить команду?"), "import": dlg.t("cmd.dlg.import", "Импорт команды"),
                          "export": dlg.t("cmd.dlg.export", "Экспорт команды"), "permission": dlg.t("cmd.dlg.permission", "Что сможет эта команда"),
                          "unsaved": dlg.t("cmd.dlg.unsaved", "Сохранить изменения?"), "imported": dlg.t("cmd.dlg.imported", "Команда импортирована"),
                          "fn_collapse": dlg.t("cmd.dlg.fn_collapse", "Свернуть в узел"), "fn_rename": dlg.t("cmd.dlg.fn_rename", "Переименовать функцию"),
                          "fn_delete": dlg.t("cmd.dlg.fn_delete", "Удалить функцию?"), "fn_import": dlg.t("cmd.dlg.fn_import", "Импорт функции"),
                          "fn_export": dlg.t("cmd.dlg.fn_export", "Экспорт функции"), "fn_unsaved": dlg.t("cmd.dlg.fn_unsaved", "Сохранить функцию?") })[dlg.kind] || "" }
        }

        Item {
            id: body
            x: 0; y: head.height; width: parent.width
            height: dlg.kind === "new" ? 120 + tplList.height : dlg.kind === "rename" ? 86 : dlg.kind === "delete" ? 70
                  : dlg.kind === "import" ? 100 + impList.height : dlg.kind === "export" ? 86 : dlg.kind === "permission" ? 36 + capCol.implicitHeight
                  : dlg.kind === "unsaved" || dlg.kind === "fn_unsaved" ? 60 : dlg.kind === "imported" ? 50 + impCol.implicitHeight
                  : dlg.kind === "fn_collapse" ? 112 + fnPins.implicitHeight : dlg.kind === "fn_rename" ? 86 : dlg.kind === "fn_delete" ? 40 + fnUse.implicitHeight
                  : dlg.kind === "fn_import" || dlg.kind === "fn_export" ? 86 : 0

            // name field (new / rename)
            Rectangle {
                visible: dlg.isNameKind
                x: 20; y: 4; width: parent.width - 40; height: 40; radius: 10; color: ThemeBackend.surface0
                border.width: nameIn.activeFocus ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.7)
                TextInput {
                    id: nameIn
                    x: 14; y: 0; width: parent.width - 28; height: parent.height
                    verticalAlignment: TextInput.AlignVCenter
                    color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(13)
                    clip: true
                    maximumLength: 80
                    Keys.onReturnPressed: dlg.confirm()
                    Keys.onEnterPressed: dlg.confirm()
                    Keys.onEscapePressed: dlg.cancel()
                    CT { visible: nameIn.text === ""; anchors.verticalCenter: parent.verticalCenter; size: 13; c: ThemeBackend.subtext0; text: dlg.kind.indexOf("fn_") === 0 ? dlg.t("cmd.dlg.fn_name_hint", "Название функции") : dlg.t("cmd.dlg.name_hint", "Название команды") }
                }
            }
            // function: description + the pins inferred from the wires crossing the selection (C5)
            Rectangle {
                visible: dlg.kind === "fn_collapse"
                x: 20; y: 52; width: parent.width - 40; height: 36; radius: 10; color: ThemeBackend.surface0
                border.width: descIn.activeFocus ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.7)
                TextInput {
                    id: descIn
                    x: 14; y: 0; width: parent.width - 28; height: parent.height
                    verticalAlignment: TextInput.AlignVCenter
                    color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(12)
                    clip: true
                    maximumLength: 200
                    Keys.onReturnPressed: dlg.confirm()
                    Keys.onEnterPressed: dlg.confirm()
                    Keys.onEscapePressed: dlg.cancel()
                    CT { visible: descIn.text === ""; anchors.verticalCenter: parent.verticalCenter; size: 12; c: ThemeBackend.subtext0; text: dlg.t("cmd.dlg.fn_desc_hint", "Описание: что делает функция") }
                }
            }
            Column {
                id: fnPins
                visible: dlg.kind === "fn_collapse"
                x: 20; y: 100; width: parent.width - 40; spacing: 5
                CT { size: 11; c: ThemeBackend.subtext0
                     text: dlg.d && dlg.d.pins ? dlg.t("cmd.dlg.fn_pins", "Узлов в группе: " + dlg.d.count + ". Входы и выходы — по проводам, пересекающим выделение:", { n: dlg.d.count }) : "" }
                Flow {
                    width: parent.width; spacing: 6
                    Repeater {
                        model: dlg.d && dlg.d.pins ? dlg.d.pins.inputs.map(p => ({ dir: "in", p: p })).concat(dlg.d.pins.outputs.map(p => ({ dir: "out", p: p }))) : []
                        delegate: CmdChip { text: (modelData.dir === "in" ? "\u2192 " : "\u2190 ") + modelData.p.label + " · " + modelData.p.tn; tone: modelData.dir === "in" ? "#89b4fa" : "#a6e3a1" }
                    }
                    CmdChip { visible: dlg.d && dlg.d.pins && dlg.d.pins.exec; text: dlg.t("cmd.dlg.fn_exec", "порядок выполнения: вход и выход"); tone: "#cdd6f4" }
                    CT { visible: dlg.d && dlg.d.pins && dlg.d.pins.inputs.length + dlg.d.pins.outputs.length === 0 && !dlg.d.pins.exec; size: 10; c: ThemeBackend.subtext0
                         text: dlg.t("cmd.dlg.fn_nopins", "Проводов наружу нет: у узла не будет входов и выходов") }
                }
                CT { visible: dlg.d && dlg.d.warnings && dlg.d.warnings.indexOf("vars") >= 0; width: parent.width; size: 10; c: "#f9e2af"; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: dlg.t("cmd.dlg.fn_vars", "Переменные внутри функции станут отдельными: значение не делится с командой.") }
            }
            CT { visible: dlg.kind === "fn_unsaved"; x: 20; y: 4; width: parent.width - 40; size: 12; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                 text: dlg.t("cmd.dlg.fn_unsaved_text", "В функции есть несохранённые изменения.") }
            Column {
                id: fnUse
                visible: dlg.kind === "fn_delete"
                x: 20; y: 4; width: parent.width - 40; spacing: 6
                CT { width: parent.width; size: 12; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: dlg.d && dlg.d.usages && dlg.d.usages.length > 0 ? dlg.t("cmd.dlg.fn_in_use", "«" + dlg.d.name + "» используют: " + dlg.d.usages.map(u => "«" + u.name + "»").join(", ") + ". Удалять её нельзя, пока она используется.", { name: dlg.d.name, list: dlg.d.usages.map(u => "«" + u.name + "»").join(", ") })
                                                                           : (dlg.d ? dlg.t("cmd.dlg.fn_delete_text", "«" + dlg.d.name + "» уйдёт в корзину и будет храниться 30 дней.", { name: dlg.d.name }) : "") }
            }
            // template chooser (new)
            Column {
                id: tplList
                visible: dlg.kind === "new"
                x: 20; y: 58; width: parent.width - 40; spacing: 4
                CT { size: 11; c: ThemeBackend.subtext0; text: dlg.t("cmd.dlg.start_from", "С чего начать") }
                Repeater {
                    model: [ { n: dlg.t("cmd.dlg.empty", "Пустая команда"), file: "", d: dlg.t("cmd.dlg.empty_hint", "Один узел «Вручную», остальное добавите сами") } ].concat(XCmd.examples.slice(0, 4).map(e => ({ n: e.name, file: e.file, d: e.description })))
                    delegate: Rectangle {
                        id: opt
                        width: tplList.width; height: 36; radius: 8
                        readonly property bool on: dlg.tpl === modelData.file
                        color: on ? Qt.alpha(ThemeBackend.mauve, 0.14) : (tma.containsMouse ? ThemeBackend.surface0 : "transparent")
                        border.width: on ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.6)
                        Rectangle { x: 10; y: 11; width: 14; height: 14; radius: 7; color: "transparent"; border.width: 2; border.color: opt.on ? ThemeBackend.mauve : ThemeBackend.subtext0
                            Rectangle { visible: opt.on; anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: ThemeBackend.mauve } }
                        CT { x: 34; y: 4; width: parent.width - 44; size: 12; font.bold: true; text: modelData.n }
                        CT { x: 34; y: 20; width: parent.width - 44; size: 10; c: ThemeBackend.subtext0; text: modelData.d || "" }
                        MouseArea { id: tma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: dlg.tpl = modelData.file }
                    }
                }
            }
            // delete
            CT { visible: dlg.kind === "delete"; x: 20; y: 4; width: parent.width - 40; size: 12; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                 text: dlg.d ? dlg.t("cmd.dlg.delete_text", "«" + dlg.d.name + "» уйдёт в корзину и будет храниться 30 дней: её можно будет вернуть.", { name: dlg.d.name }) : "" }
            // path field (import / export)
            Rectangle {
                visible: dlg.isPathKind
                x: 20; y: 4; width: parent.width - 40; height: 40; radius: 10; color: ThemeBackend.surface0
                border.width: pathIn.activeFocus ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.7)
                TextInput {
                    id: pathIn
                    x: 14; y: 0; width: parent.width - 28; height: parent.height
                    verticalAlignment: TextInput.AlignVCenter
                    color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(12)
                    clip: true
                    Keys.onReturnPressed: dlg.confirm()
                    Keys.onEnterPressed: dlg.confirm()
                    Keys.onEscapePressed: dlg.cancel()
                    CT { visible: pathIn.text === ""; anchors.verticalCenter: parent.verticalCenter; size: 12; c: ThemeBackend.subtext0; text: dlg.kind.indexOf("fn_") === 0 ? dlg.t("cmd.dlg.fn_path_hint", "Путь к файлу функции .sfn") : dlg.t("cmd.dlg.path_hint", "Путь к файлу .scmd или .cmd.json") }
                }
            }
            Column {
                id: impList
                visible: dlg.kind === "import"
                x: 20; y: 56; width: parent.width - 40; spacing: 4
                CT { size: 11; c: ThemeBackend.subtext0; text: dlg.candidates.length > 0 ? dlg.t("cmd.dlg.found", "Найдено в Загрузках и Документах") : dlg.t("cmd.dlg.found_none", "Файлов команд рядом не найдено — введите путь выше") }
                Repeater {
                    model: dlg.candidates.slice(0, 5)
                    delegate: Rectangle {
                        width: impList.width; height: 30; radius: 8; color: ima.containsMouse ? ThemeBackend.surface0 : "transparent"
                        CT { x: 10; y: 7; width: parent.width - 20; size: 11; text: modelData.name + "  ·  " + modelData.dir }
                        MouseArea { id: ima; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pathIn.text = modelData.path }
                    }
                }
            }
            // permission prompt
            Column {
                id: capCol
                visible: dlg.kind === "permission"
                x: 20; y: 4; width: parent.width - 40; spacing: 8
                CT { width: parent.width; size: 11; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: dlg.d ? dlg.t("cmd.dlg.perm_text", "Команда «" + dlg.d.name + "» будет сама запускаться и сможет:", { name: dlg.d.name }) : "" }
                Flow {
                    width: parent.width; spacing: 6
                    Repeater {
                        model: dlg.d && dlg.d.caps ? dlg.d.caps : []
                        delegate: CmdChip { text: (modelData.risky ? "\u{f0026}  " : "") + modelData.n; tone: modelData.risky ? "#f38ba8" : "#89b4fa" }
                    }
                }
                Repeater {
                    model: dlg.d && dlg.d.caps ? dlg.d.caps.filter(x => x.warn) : []
                    delegate: CT { width: capCol.width; size: 11; c: "#f9e2af"; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: "\u{f0026}  " + modelData.n + ": " + modelData.warn }
                }
                CT { visible: dlg.d && dlg.d.caps && dlg.d.caps.length === 0; width: parent.width; size: 11; c: ThemeBackend.subtext0; text: dlg.t("cmd.dlg.perm_none", "Ничего особенного: только внутренние действия") }
                CT { width: parent.width; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: dlg.t("cmd.dlg.perm_note", "Разрешение действует только на эти права. Если вы добавите узел с новыми правами, команду придётся подтвердить снова.") }
            }
            CT { visible: dlg.kind === "unsaved"; x: 20; y: 4; width: parent.width - 40; size: 12; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                 text: dlg.t("cmd.dlg.unsaved_text", "В команде есть несохранённые изменения.") }
            // after an import with warnings
            Column {
                id: impCol
                visible: dlg.kind === "imported"
                x: 20; y: 4; width: parent.width - 40; spacing: 6
                CT { width: parent.width; size: 11; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: dlg.d && dlg.d.result ? dlg.t("cmd.dlg.imp_text", "«" + dlg.d.result.command + "» добавлена выключенной, права не подтверждены. Просмотрите команду, прежде чем включать.", { name: dlg.d.result.command }) : "" }
                Repeater {
                    model: dlg.d && dlg.d.result ? dlg.d.result.suspicious : []
                    delegate: CT { width: impCol.width; size: 11; c: "#f38ba8"; text: "\u{f0026}  " + dlg.t("cmd.dlg.suspicious", "узел «" + modelData.name + "» может менять файлы, сеть или запускать программы", { name: modelData.name }) }
                }
                Repeater {
                    model: dlg.d && dlg.d.result ? dlg.d.result.warnings : []
                    delegate: CT { width: impCol.width; size: 10; c: "#f9e2af"; wrapMode: Text.WordWrap; elide: Text.ElideNone; text: modelData }
                }
            }
        }

        Item {
            id: foot
            x: 0; y: head.height + body.height; width: parent.width; height: 70 + (dlg.d && dlg.d.error ? 22 : 0)
            CT { visible: dlg.d !== null && !!dlg.d.error; x: 20; y: 0; width: parent.width - 40; size: 11; c: "#f38ba8"; text: dlg.d && dlg.d.error ? dlg.d.error : ""; wrapMode: Text.WordWrap; elide: Text.ElideNone }
            Row {
                anchors.right: parent.right; anchors.rightMargin: 20; y: (dlg.d && dlg.d.error ? 22 : 0) + 8; spacing: 10
                CmdBtn { visible: dlg.kind === "unsaved" || dlg.kind === "fn_unsaved"; kind: "ghost"; text: dlg.t("cmd.dlg.discard", "Не сохранять"); onClicked: dlg.discard() }
                CmdBtn { visible: dlg.kind !== "imported"; kind: "ghost"; text: dlg.t("cmd.dlg.cancel", "Отмена"); onClicked: dlg.cancel() }
                CmdBtn {
                    visible: !(dlg.kind === "fn_delete" && dlg.d && dlg.d.usages && dlg.d.usages.length > 0)
                    kind: dlg.kind === "delete" || dlg.kind === "fn_delete" ? "danger" : "primary"
                    icon: ({ "new": "\u{f0415}", "delete": "\u{f01b4}", "import": "\u{f0207}", "export": "\u{f0206}", "permission": "\u{f012c}", "unsaved": "\u{f0193}",
                            "fn_collapse": "\u{f03d7}", "fn_delete": "\u{f01b4}", "fn_import": "\u{f0207}", "fn_export": "\u{f0206}", "fn_unsaved": "\u{f0193}" })[dlg.kind] || ""
                    text: ({ "new": dlg.t("cmd.dlg.create", "Создать"), "rename": dlg.t("cmd.dlg.save", "Сохранить"), "delete": dlg.t("cmd.dlg.do_delete", "Удалить"),
                             "import": dlg.t("cmd.dlg.do_import", "Импортировать"), "export": dlg.t("cmd.dlg.do_export", "Экспортировать"),
                             "permission": dlg.t("cmd.dlg.allow", "Разрешить и включить"), "unsaved": dlg.t("cmd.dlg.save", "Сохранить"), "imported": dlg.t("cmd.dlg.ok", "Понятно"),
                             "fn_collapse": dlg.t("cmd.dlg.fn_create", "Создать функцию"), "fn_rename": dlg.t("cmd.dlg.save", "Сохранить"), "fn_delete": dlg.t("cmd.dlg.do_delete", "Удалить"),
                             "fn_import": dlg.t("cmd.dlg.do_import", "Импортировать"), "fn_export": dlg.t("cmd.dlg.do_export", "Экспортировать"), "fn_unsaved": dlg.t("cmd.dlg.save", "Сохранить") })[dlg.kind] || ""
                    enabled: !(dlg.kind === "new" || dlg.kind === "rename" || dlg.kind === "fn_collapse" || dlg.kind === "fn_rename") || nameIn.text.trim() !== ""
                    onClicked: dlg.confirm()
                }
            }
        }
    }
}
