import QtQuick
import "../../"
import ".."

// Side panel generated from the node schema (help[type] of ui-get): description, typed pins, rights, example.
Rectangle {
    id: panel
    property var help: null          // help[type] or null
    property var node: null          // the selected node of the graph (for the title of unknown nodes)
    signal closeRequested()
    color: ThemeBackend.mantle
    function t(k, fb) { return XI18n.t(k, undefined, fb); }
    readonly property var catNames: ({ "event": t("cmd.cat.event", "Событие"), "action": t("cmd.cat.action", "Действие"),
        "logic": t("cmd.cat.logic", "Логика"), "data": t("cmd.cat.data", "Данные"), "ui": t("cmd.cat.ui", "Окна"),
        "function": t("cmd.cat.function", "Функция"), "unknown": t("cmd.cat.unknown", "Неизвестный") })
    Rectangle { x: 0; y: 0; width: 1; height: parent.height; color: Qt.alpha(ThemeBackend.text, 0.10) }

    CT { x: 20; y: 16; icon: true; text: "\u{f0335}"; size: 16; c: "#f9e2af" }
    CT { x: 46; y: 18; text: panel.t("cmd.help.title", "Справка по узлу"); size: 13; font.bold: true }
    Rectangle {
        x: parent.width - 48; y: 10; width: 30; height: 30; radius: 8; color: closeMa.containsMouse ? ThemeBackend.surface0 : "transparent"
        CT { anchors.centerIn: parent; icon: true; text: "\u{f0156}"; size: 16; c: ThemeBackend.subtext1 }
        MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.closeRequested() }
    }

    Flickable {
        id: fl
        x: 0; y: 52; width: parent.width; height: parent.height - 52 - 34
        contentWidth: width; contentHeight: col.implicitHeight + 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 20; y: 8; width: fl.width - 40
            spacing: 14

            Rectangle {   // title card
                width: parent.width; height: 56; radius: 10
                color: Qt.alpha(CK.cc(panel.help ? panel.help.category : (panel.node ? panel.node.cat : "unknown")), 0.10)
                border.width: 1
                border.color: Qt.alpha(CK.cc(panel.help ? panel.help.category : "unknown"), 0.35)
                CT { x: 14; y: 11; icon: true; size: 17; text: CK.glyph(panel.help ? panel.help.icon : "unknown"); c: CK.cc(panel.help ? panel.help.category : "unknown") }
                CT { x: 44; y: 10; width: parent.width - 58; text: panel.help ? panel.help.title : (panel.node ? panel.node.title : ""); size: 13; font.bold: true }
                CT { x: 44; y: 32; width: parent.width - 58; size: 10; c: ThemeBackend.subtext0
                     text: panel.catNames[panel.help ? panel.help.category : "unknown"] + (panel.help && panel.help.deferred ? " · " + panel.t("cmd.node.deferred_long", "ещё недоступен") : "") }
            }
            CT {
                visible: text !== ""
                width: parent.width; wrapMode: Text.WordWrap; elide: Text.ElideNone
                size: 11; c: ThemeBackend.subtext1
                text: panel.help ? panel.help.description : panel.t("cmd.help.unknown", "Такого узла нет в схеме: команда не запустится. Замените его или удалите.")
            }

            Rectangle {   // function: how many nodes inside + open
                visible: panel.help !== null && !!panel.help["function"]
                width: parent.width; height: 34; radius: 8; color: Qt.alpha("#94e2d5", 0.08)
                border.width: 1; border.color: Qt.alpha("#94e2d5", 0.35)
                CT { x: 12; y: 9; width: parent.width - 120; size: 10; c: "#94e2d5"
                     text: panel.help && panel.help["function"] ? panel.t("cmd.fn.inside", "функция · " + panel.help["function"].nodes + " узл. внутри") .replace("{n}", panel.help["function"].nodes) : "" }
                CT { anchors.right: parent.right; anchors.rightMargin: 12; y: 9; size: 10; c: "#94e2d5"; text: panel.t("cmd.fn.open", "открыть ↗")
                     MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.openFunction(panel.help["function"].id) } }
            }
            Column {   // inputs
                visible: panel.help !== null && panel.help.inputs.length > 0
                width: parent.width; spacing: 10
                CT { text: panel.t("cmd.help.inputs", "Входы"); size: 11; font.bold: true }
                Repeater {
                    model: panel.help ? panel.help.inputs : []
                    delegate: Item {
                        width: col.width; height: pinCol.implicitHeight
                        PinDot { x: 0; y: 2; kind: modelData.t }
                        Column {
                            id: pinCol
                            x: 22; width: parent.width - 22; spacing: 2
                            Item {
                                width: parent.width; height: 18
                                CT { text: modelData.n !== "" ? modelData.n : panel.t("cmd.help.run", "Выполнить"); size: 11; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                                CmdChip { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                          text: modelData.type_name; tone: CK.tc(modelData.t) }
                            }
                            CT { visible: text !== ""; width: parent.width; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideNone
                                 text: modelData.note !== "" ? modelData.note : (modelData.required ? panel.t("cmd.help.required", "обязательный вход") : "") }
                        }
                    }
                }
            }
            Column {   // outputs
                visible: panel.help !== null && panel.help.outputs.length > 0
                width: parent.width; spacing: 10
                CT { text: panel.t("cmd.help.outputs", "Выходы"); size: 11; font.bold: true }
                Repeater {
                    model: panel.help ? panel.help.outputs : []
                    delegate: Item {
                        width: col.width; height: 20
                        PinDot { x: 0; y: 2; kind: modelData.t }
                        CT { x: 22; text: modelData.n; size: 11; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                        CmdChip { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: modelData.type_name; tone: CK.tc(modelData.t) }
                    }
                }
            }
            Column {   // rights
                visible: panel.help !== null && (panel.help.capabilities.length > 0 || panel.help.reverts)
                width: parent.width; spacing: 8
                CT { text: panel.t("cmd.help.rights", "Права"); size: 11; font.bold: true }
                Flow {
                    width: parent.width; spacing: 6
                    Repeater {
                        model: panel.help ? panel.help.capabilities : []
                        delegate: CmdChip { text: modelData; tone: "#89b4fa" }
                    }
                    CmdChip { visible: panel.help !== null && panel.help.reverts; text: panel.t("cmd.help.reverts", "откатывается"); tone: "#a6e3a1" }
                }
            }
            Column {   // example
                visible: panel.help !== null && panel.help.example !== ""
                width: parent.width; spacing: 8
                CT { text: panel.t("cmd.help.example", "Пример"); size: 11; font.bold: true }
                Rectangle {
                    width: parent.width; height: ex.implicitHeight + 24; radius: 10
                    color: ThemeBackend.base; border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.10)
                    CT { id: ex; x: 12; y: 12; width: parent.width - 24; wrapMode: Text.WordWrap; elide: Text.ElideNone; size: 10; c: ThemeBackend.subtext1; text: panel.help ? panel.help.example : "" }
                }
            }
        }
    }
    CT { x: 20; y: parent.height - 24; width: parent.width - 40; size: 10; c: ThemeBackend.subtext0; text: panel.t("cmd.help.generated", "Справка собрана из схемы узлов") }
}
