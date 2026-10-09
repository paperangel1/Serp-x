import QtQuick
import "../../"
import ".."

// Right column: the selected command - thumbnail, rights, recent runs, actions.
Rectangle {
    id: dt
    color: ThemeBackend.mantle
    readonly property var c: XCmd.selected
    readonly property var g: XCmd.graph
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    Rectangle { x: 0; width: 1; height: parent.height; color: Qt.alpha(ThemeBackend.text, 0.10) }

    CT { visible: dt.c === null; anchors.centerIn: parent; text: dt.t("cmd.detail.none", "Выберите команду"); size: 12; c: ThemeBackend.subtext0 }

    Item {
        visible: dt.c !== null
        anchors.fill: parent
        CT { x: 20; y: 20; width: parent.width - 40; text: dt.c ? dt.c.name : ""; size: 15; font.bold: true }
        Row {
            x: 20; y: 48; spacing: 6
            CmdChip { text: dt.c ? (dt.c.example ? dt.t("cmd.kind.example", "пример") : (dt.c.kind === "auto" ? dt.t("cmd.kind.auto", "автоматизация") : dt.t("cmd.kind.manual", "вручную"))) : ""; tone: "#a6e3a1" }
            CmdChip { visible: dt.c !== null && dt.c.kind === "auto" && !dt.c.example; text: dt.c && dt.c.enabled ? dt.t("cmd.state.on", "включена") : dt.t("cmd.state.off", "выключена"); tone: dt.c && dt.c.enabled ? "#a6e3a1" : "#9399b2" }
        }
        MiniPreview { x: 20; y: 78; width: parent.width - 40; height: 150; graph: dt.g }
        CT { visible: dt.g === null && XCmd.graphLoading; x: 20; y: 140; width: parent.width - 40; horizontalAlignment: Text.AlignHCenter; text: dt.t("cmd.loading", "Загрузка…"); size: 11; c: ThemeBackend.subtext0 }

        CT { x: 20; y: 246; text: dt.t("cmd.detail.rights", "Права"); size: 11; font.bold: true }
        Flow {
            x: 20; y: 270; width: parent.width - 40; spacing: 6
            Repeater {
                model: dt.g ? dt.g.capabilities : []
                delegate: CmdChip { text: modelData.n; tone: modelData.risky ? "#f38ba8" : "#89b4fa" }
            }
        }
        CT {
            x: 20; y: 300; width: parent.width - 40; wrapMode: Text.WordWrap; elide: Text.ElideNone; size: 10; c: ThemeBackend.subtext0
            visible: dt.g !== null
            text: dt.g && dt.g.capabilities.length === 0 ? dt.t("cmd.detail.no_rights", "Команда ничего не меняет в системе")
                : (dt.g && dt.g.capabilities.some(x => x.risky) ? dt.t("cmd.detail.risky", "Есть опасные права: перед включением они будут показаны на подтверждение")
                                                                : dt.t("cmd.detail.safe", "Команда не использует сеть, файлы и скрипты"))
        }

        CT { x: 20; y: 352; text: dt.t("cmd.detail.runs", "Последние запуски"); size: 11; font.bold: true }
        Column {
            x: 20; y: 376; width: parent.width - 40; spacing: 6
            Repeater {
                model: dt.g ? dt.g.runs.slice(0, 4) : []
                delegate: Rectangle {
                    width: parent.width; height: 44; radius: 8; color: Qt.alpha(ThemeBackend.base, 0.8)
                    Rectangle { x: 10; y: 16; width: 12; height: 12; radius: 6; color: modelData.status === "ok" ? "#a6e3a1" : (modelData.status === "skipped" ? "#f9e2af" : "#f38ba8") }
                    CT { x: 32; y: 7; text: XCmd.when(modelData.ts); size: 10; font.bold: true }
                    CT { x: 32; y: 24; width: parent.width - 44; size: 10; c: ThemeBackend.subtext0
                         text: (modelData.status === "ok" ? dt.t("cmd.run.ok", "ок") : modelData.status) + (modelData.dur ? " · " + modelData.dur.toFixed(2) + " с" : "") + (modelData.message ? " · " + modelData.message : "") }
                }
            }
            CT { visible: dt.g !== null && dt.g.runs.length === 0; text: dt.t("cmd.detail.no_runs", "запусков ещё не было"); size: 10; c: ThemeBackend.subtext0 }
        }

        Row {   // secondary actions
            visible: dt.c !== null && !dt.c.example
            x: 20; y: parent.height - 104; spacing: 6
            CmdBtn { kind: "ghost"; padX: 9; icon: "\u{f018f}"; text: dt.t("cmd.detail.duplicate", "Копия"); enabled: dt.g !== null; onClicked: XCmd.duplicateCommand(XCmd.selectedRef) }
            CmdBtn { kind: "ghost"; padX: 9; icon: "\u{f0206}"; text: dt.t("cmd.detail.export", "Экспорт"); enabled: dt.g !== null; onClicked: XCmd.dialog = { kind: "export", ref: XCmd.selectedRef, name: dt.c.name } }
            CmdBtn { kind: "ghost"; padX: 9; icon: "\u{f01b4}"; text: dt.t("cmd.detail.delete", "Удалить"); enabled: dt.g !== null; onClicked: XCmd.dialog = { kind: "delete", ref: XCmd.selectedRef, name: dt.c.name } }
        }
        Row {
            x: 20; y: parent.height - 56; spacing: 10
            CmdBtn { kind: "primary"; icon: dt.c && dt.c.example ? "\u{f0415}" : "\u{f03eb}"; enabled: dt.g !== null
                     text: dt.c && dt.c.example ? dt.t("cmd.example.copy", "В мои команды") : dt.t("cmd.edit.start", "Изменить")
                     onClicked: { if (dt.c.example) XCmd.copyExample(XCmd.selectedRef); else XCmd.openEditor(XCmd.selectedRef); } }
            CmdBtn { icon: "\u{f1049}"; text: dt.t("cmd.detail.open", "Граф"); enabled: dt.g !== null; onClicked: XCmd.openGraph(XCmd.selectedRef) }
            CmdBtn { visible: dt.c !== null && !dt.c.example; icon: "\u{f040a}"; padX: 11; enabled: dt.c !== null && dt.c.errors === 0; onClicked: XCmd.run(XCmd.selectedRef) }
        }
        Row {   // enable switch of automations
            visible: dt.c !== null && !dt.c.example && dt.c.kind === "auto"
            anchors.right: parent.right; anchors.rightMargin: 20; y: 46; spacing: 8
            CT { anchors.verticalCenter: parent.verticalCenter; size: 10; c: ThemeBackend.subtext1; text: dt.c && dt.c.enabled ? dt.t("cmd.state.on", "включена") : dt.t("cmd.state.off", "выключена") }
            Rectangle {
                width: 40; height: 22; radius: 11; anchors.verticalCenter: parent.verticalCenter
                color: dt.c && dt.c.enabled ? ThemeBackend.mauve : ThemeBackend.surface0
                Rectangle { x: dt.c && dt.c.enabled ? 20 : 2; y: 2; width: 18; height: 18; radius: 9; color: dt.c && dt.c.enabled ? ThemeBackend.crust : ThemeBackend.subtext0 }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { if (dt.c.errors > 0 && !dt.c.enabled) XCmd.showToast(dt.t("cmd.row.fix_first", "Сначала исправьте ошибки в команде")); else XCmd.setEnabled(XCmd.selectedRef, !dt.c.enabled); } }
            }
        }
    }
}
