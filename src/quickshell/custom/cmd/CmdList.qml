import QtQuick
import "../../"
import ".."

// Centre column: search + sections of commands.
Item {
    id: lst
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    readonly property var autos: XCmd.filter === "examples" ? [] : XCmd.listFor("auto")
    readonly property var manuals: XCmd.filter === "examples" ? [] : XCmd.listFor("manual")
    readonly property var gallery: XCmd.filter === "examples" ? XCmd.listFor("") : []
    readonly property bool trashMode: XCmd.filter === "trash"
    readonly property bool empty: !trashMode && autos.length + manuals.length + gallery.length === 0

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
            text: XCmd.query
            onTextChanged: XCmd.query = text
            CT { visible: search.text === ""; anchors.verticalCenter: parent.verticalCenter; text: lst.t("cmd.search", "Поиск по командам, событиям и действиям"); size: 12; c: ThemeBackend.subtext0 }
        }
    }
    Row {
        id: btnRow
        anchors.right: parent.right; anchors.rightMargin: 16; y: 20; spacing: 10
        CmdBtn { kind: "ghost"; icon: "\u{f0207}"; text: lst.t("cmd.import", "Импорт"); onClicked: XCmd.dialog = { kind: "import" } }
        CmdBtn { kind: "primary"; icon: "\u{f0415}"; text: lst.t("cmd.create", "Создать команду"); onClicked: XCmd.dialog = { kind: "new" }
                 Component.onCompleted: XCmdTutorial.reg("new_button", this) }
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

            // trash: deleted commands can be brought back
            Column {
                visible: lst.trashMode
                width: col.width; spacing: 8
                CT { x: 2; y: 8; text: lst.t("cmd.section.trash", "Корзина"); size: 12; font.bold: true }
                CT { x: 2; width: parent.width; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     text: lst.t("cmd.trash.note", "Удалённые команды хранятся 30 дней, потом исчезают насовсем.") }
                Repeater {
                    model: lst.trashMode ? XCmd.trash : []
                    delegate: Rectangle {
                        width: col.width; height: 56; radius: 12; color: ThemeBackend.base
                        border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.10)
                        CT { x: 16; y: 10; width: parent.width - 220; text: modelData.name; size: 12; font.bold: true }
                        CT { x: 16; y: 30; size: 10; c: ThemeBackend.subtext0; text: XCmd.when(modelData.deleted_at) + " · " + lst.t("cmd.row.nodes", modelData.nodes + " узлов", { n: modelData.nodes }) }
                        CmdBtn { anchors.right: parent.right; anchors.rightMargin: 14; y: 12; icon: "\u{f0709}"; text: lst.t("cmd.trash.restore", "Вернуть"); onClicked: XCmd.restoreCommand(modelData.id) }
                    }
                }
            }
            // sections
            Repeater {
                model: lst.trashMode ? [] : [
                    { id: "auto", list: lst.autos, title: lst.t("cmd.section.auto", "Автоматизации") },
                    { id: "manual", list: lst.manuals, title: lst.t("cmd.section.manual", "Вручную") },
                    { id: "gallery", list: lst.gallery, title: lst.t("cmd.section.gallery", "Галерея примеров") }
                ]
                delegate: Column {
                    visible: modelData.list.length > 0
                    width: col.width; spacing: 8
                    Item {
                        width: parent.width; height: 30
                        CT { x: 2; y: 8; text: modelData.title; size: 12; font.bold: true }
                        CT { x: 2 + hd.implicitWidth + 12; y: 10; size: 10; c: ThemeBackend.subtext0
                             text: modelData.id === "auto" ? (modelData.list.length + " · " + lst.t("cmd.section.enabled", XCmd.nAutoOn + " включено", { n: XCmd.nAutoOn })) : String(modelData.list.length) }
                        CT { id: hd; visible: false; text: modelData.title; size: 12; font.bold: true }
                    }
                    Repeater {
                        model: modelData.list
                        delegate: CmdRow {
                            width: col.width
                            cmd: modelData
                            selected: XCmd.selectedRef === XCmd.refOf(modelData)
                            onChosen: XCmd.select(XCmd.refOf(modelData))
                            onOpened: XCmd.openGraph(XCmd.refOf(modelData))
                            onRunRequested: XCmd.run(XCmd.refOf(modelData))
                        }
                    }
                }
            }
            Item {   // empty state
                visible: lst.empty && XCmd.loaded
                width: col.width; height: 220
                CT { anchors.horizontalCenter: parent.horizontalCenter; y: 60; icon: true; text: "\u{f0493}"; size: 40; c: ThemeBackend.surface1 }
                CT { anchors.horizontalCenter: parent.horizontalCenter; y: 116; size: 13; font.bold: true
                     text: XCmd.error !== "" ? XCmd.error : (XCmd.query !== "" ? lst.t("cmd.empty.search", "Ничего не найдено") : lst.t("cmd.empty.title", "Команд пока нет")) }
                CT { anchors.horizontalCenter: parent.horizontalCenter; y: 142; width: parent.width - 80; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; elide: Text.ElideNone
                     size: 11; c: ThemeBackend.subtext0; visible: XCmd.error === "" && XCmd.query === ""
                     text: lst.t("cmd.empty.hint", "Откройте галерею примеров слева: готовые команды можно посмотреть в виде графа.") }
            }
            CT { visible: XCmd.filter === "examples" && lst.gallery.length > 0; width: col.width; wrapMode: Text.WordWrap; elide: Text.ElideNone; size: 10; c: ThemeBackend.subtext0
                 text: lst.t("cmd.gallery.note", "Примеры только для просмотра: нажмите «Добавить в мои команды», чтобы получить свою копию и менять её.") }
        }
    }
}
