import QtQuick
import "../../"
import ".."

// Left column: title, filters, example gallery card, engine status and the global pause indicator.
Rectangle {
    id: sb
    color: ThemeBackend.mantle
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.alpha(ThemeBackend.text, 0.10) }

    Rectangle { x: 16; y: 16; width: 36; height: 36; radius: 10; color: Qt.alpha(ThemeBackend.mauve, 0.14); border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.35)
        CT { anchors.centerIn: parent; icon: true; text: "\u{f0493}"; size: 18; c: ThemeBackend.mauve } }
    CT { x: 62; y: 16; text: sb.t("cmd.title", "Команды"); size: 15; font.bold: true }
    CT { x: 62; y: 38; width: parent.width - 74; text: sb.t("cmd.subtitle", "автоматизация рабочего стола"); size: 10; c: ThemeBackend.subtext0 }

    Column {
        x: 10; y: 78; width: parent.width - 20; spacing: 4
        Repeater {
            model: [
                { id: "all", icon: "\u{f0570}", n: XCmd.commands.length },
                { id: "manual", icon: "\u{f040a}", n: XCmd.nManual },
                { id: "auto", icon: "\u{f0450}", n: XCmd.nAuto },
                { id: "examples", icon: "\u{f0335}", n: XCmd.examples.length },
                { id: "functions", icon: "\u{f0295}", n: XCmd.functions.length }
            ].concat(XCmd.trash.length > 0 ? [{ id: "trash", icon: "\u{f01b4}", n: XCmd.trash.length }] : [])
            delegate: Rectangle {
                width: parent.width; height: 40; radius: 10
                readonly property bool active: XCmd.filter === modelData.id
                color: active ? ThemeBackend.mauve : (ma.containsMouse ? ThemeBackend.surface0 : "transparent")
                CT { x: 12; y: 10; icon: true; text: modelData.icon; size: 17; c: parent.active ? ThemeBackend.crust : ThemeBackend.subtext1 }
                CT { x: 46; y: 12; width: parent.width - 90; size: 12; font.bold: parent.active; c: parent.active ? ThemeBackend.crust : ThemeBackend.text
                     text: ({ "all": sb.t("cmd.filter.all", "Все команды"), "manual": sb.t("cmd.filter.manual", "Вручную"),
                              "auto": sb.t("cmd.filter.auto", "Автоматизации"), "examples": sb.t("cmd.filter.examples", "Примеры"), "functions": sb.t("cmd.filter.functions", "Функции"), "trash": sb.t("cmd.filter.trash", "Корзина") })[modelData.id] }
                CT { anchors.right: parent.right; anchors.rightMargin: 12; y: 13; size: 10; text: modelData.n; c: parent.active ? ThemeBackend.crust : ThemeBackend.subtext0 }
                MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.filter = modelData.id }
            }
        }
    }

    readonly property real extra: (XCmd.trash.length > 0 ? 44 : 0) + 44
    Rectangle { x: 16; y: 270 + sb.extra; width: parent.width - 32; height: 1; color: Qt.alpha(ThemeBackend.text, 0.10) }

    Rectangle {   // example gallery
        x: 10; y: 286 + sb.extra; width: parent.width - 20; height: 72; radius: 12
        color: Qt.alpha("#f9e2af", 0.06); border.width: 1; border.color: Qt.alpha("#f9e2af", 0.35)
        CT { x: 14; y: 12; icon: true; text: "\u{f0335}"; size: 16; c: "#f9e2af" }
        CT { x: 40; y: 12; width: parent.width - 52; text: sb.t("cmd.gallery.title", "Галерея примеров"); size: 12; font.bold: true }
        CT { x: 14; y: 34; width: parent.width - 28; text: sb.t("cmd.gallery.count", XCmd.gallery.length + " готовых команд, с пояснениями", { n: XCmd.gallery.length }); size: 10; c: ThemeBackend.subtext0 }
        CT { x: 14; y: 52; text: sb.t("cmd.gallery.open", "Открыть →"); size: 10; c: "#f9e2af" }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.openGallery() }
    }
    Rectangle {   // documentation and tutorial
        x: 10; y: 366 + sb.extra; width: parent.width - 20; height: 90; radius: 12
        color: "transparent"; border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.10)
        Item {
            x: 0; y: 0; width: parent.width; height: 45
            CT { x: 14; y: 14; icon: true; text: "\u{f0219}"; size: 16; c: ThemeBackend.mauve }
            CT { x: 40; y: 14; width: parent.width - 52; text: sb.t("cmd.docs.title", "Документация"); size: 12 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.openDocs("") }
        }
        Item {
            x: 0; y: 45; width: parent.width; height: 45
            CT { x: 14; y: 14; icon: true; text: "\u{f0335}"; size: 16; c: ThemeBackend.mauve }
            CT { x: 40; y: 14; width: parent.width - 52; text: sb.t("cmd.tutorial.replay", "Обучение"); size: 12 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { XCmd.screen = "list"; XCmdTutorial.replay(); } }
        }
    }

    Rectangle {   // engine status + pause indicator
        x: 10; y: parent.height - 142; width: parent.width - 20; height: 130; radius: 12
        color: Qt.alpha(ThemeBackend.base, 0.7); border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.08)
        readonly property bool daemon: XCmd.mode === "daemon"
        readonly property bool installed: !!XCmd.service.unit_installed
        Rectangle { x: 14; y: 16; width: 10; height: 10; radius: 5; color: parent.daemon ? "#a6e3a1" : (parent.installed ? "#f9e2af" : "#6c7086") }
        CT { x: 32; y: 12; width: parent.width - 44; font.bold: true; size: 11
             text: parent.daemon ? sb.t("cmd.engine.running", "Движок работает") : (parent.installed ? sb.t("cmd.engine.stopped", "Служба установлена, не запущена") : sb.t("cmd.engine.not_installed", "Служба не установлена")) }
        CT { x: 14; y: 34; width: parent.width - 28; size: 10; c: ThemeBackend.subtext0; wrapMode: Text.WordWrap; elide: Text.ElideNone
             text: parent.daemon ? sb.t("cmd.engine.listening", "serpantinum-cmdd · автоматизаций: " + XCmd.nAutoOn, { n: XCmd.nAutoOn })
                                 : sb.t("cmd.engine.hint", "Ручной запуск работает и без службы. Автоматизации по событиям включатся вместе с ней.") }
        Rectangle { x: 14; y: 90; width: parent.width - 28; height: 1; color: Qt.alpha(ThemeBackend.text, 0.08) }
        CT { x: 14; y: 100; width: parent.width - 70; text: sb.t("cmd.pause.title", "Пауза всех автоматизаций"); size: 10 }
        Rectangle {   // global pause of all automations
            x: parent.width - 54; y: 98; width: 40; height: 20; radius: 10
            color: XCmd.pausedAll ? ThemeBackend.mauve : ThemeBackend.surface0
            Rectangle { x: XCmd.pausedAll ? 22 : 2; y: 2; width: 16; height: 16; radius: 8; color: XCmd.pausedAll ? ThemeBackend.crust : ThemeBackend.subtext0
                        Behavior on x { NumberAnimation { duration: 120 } } }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmd.setPaused(!XCmd.pausedAll) }
        }
    }
}
