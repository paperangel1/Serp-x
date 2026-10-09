import QtQuick
import "../../"
import ".."

// Highlight ring around the target of the current tutorial step plus the step card (C7), or the first-launch question.
Item {
    id: ov
    anchors.fill: parent
    z: 60
    readonly property var cur: XCmdTutorial.current
    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    property rect ring: Qt.rect(0, 0, 0, 0)
    property bool ringOn: false
    function place() {
        const it = ov.cur ? XCmdTutorial.targets[ov.cur.target] : null;
        if (!it || !it.visible || it.width <= 0 || ov.cur.target === "window") { ov.ringOn = false; return; }
        const p = it.mapToItem(ov, 0, 0);
        ov.ring = Qt.rect(p.x - 5, p.y - 5, it.width + 10, it.height + 10);
        ov.ringOn = true;
    }
    Timer { interval: 150; repeat: true; running: ov.cur !== null; triggeredOnStart: true; onTriggered: ov.place() }

    Rectangle {
        visible: ov.cur !== null && ov.ringOn
        x: ov.ring.x; y: ov.ring.y; width: ov.ring.width; height: ov.ring.height
        radius: 12; color: Qt.alpha(ThemeBackend.mauve, 0.06); border.width: 2; border.color: ThemeBackend.mauve
        SequentialAnimation on opacity {
            running: ov.cur !== null && ov.ringOn; loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 700 }
            NumberAnimation { to: 1; duration: 700 }
        }
    }

    Rectangle {   // the step card
        id: card
        visible: ov.cur !== null
        x: Math.round((parent.width - width) / 2); y: parent.height - height - 28
        width: 460; height: 140 + body.implicitHeight
        radius: 14; color: ThemeBackend.mantle; border.width: 1; border.color: ThemeBackend.mauve
        Rectangle { x: 20; y: 18; width: 28; height: 28; radius: 14; color: Qt.alpha(ThemeBackend.mauve, 0.25)
            CT { anchors.centerIn: parent; text: XCmdTutorial.st.step + 1; size: 13; font.bold: true; c: ThemeBackend.mauve } }
        CT { x: 60; y: 16; width: parent.width - 80; text: ov.cur ? ov.cur.title : ""; size: 14; font.bold: true }
        CT { x: 60; y: 36; text: ov.t("cmd.tutorial.step_of", "Шаг " + (XCmdTutorial.st.step + 1) + " из " + XCmdTutorial.steps.length, { n: XCmdTutorial.st.step + 1, total: XCmdTutorial.steps.length }); size: 10; c: ThemeBackend.subtext0 }
        CT { id: body; x: 20; y: 64; width: parent.width - 40; wrapMode: Text.WordWrap; elide: Text.ElideNone; size: 11; c: ThemeBackend.subtext1; text: ov.cur ? ov.cur.text : ""; lineHeight: 1.15 }
        Row {
            x: 20; y: body.y + body.implicitHeight + 16; spacing: 6
            Repeater {
                model: XCmdTutorial.steps.length
                delegate: Rectangle { width: index === XCmdTutorial.st.step ? 18 : 6; height: 6; radius: 3; y: 0
                                      color: index <= XCmdTutorial.st.step ? ThemeBackend.mauve : ThemeBackend.surface1 }
            }
        }
        CT { x: 20; y: card.height - 36; text: ov.t("cmd.tutorial.skip", "Пропустить обучение"); size: 10; c: ThemeBackend.subtext0
             MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XCmdTutorial.skip() } }
        CmdBtn { x: parent.width - width - 126; y: card.height - 50; h: 30; padX: 12; text: ov.t("cmd.tutorial.back", "Назад"); enabled: XCmdTutorial.st.step > 0; onClicked: XCmdTutorial.back() }
        CmdBtn { x: parent.width - width - 20; y: card.height - 50; h: 30; padX: 14; kind: "primary"
                 text: XCmdTutorial.st.step + 1 >= XCmdTutorial.steps.length ? ov.t("cmd.tutorial.finish", "Готово") : ov.t("cmd.tutorial.next", "Далее")
                 onClicked: XCmdTutorial.next() }
    }

    Rectangle {   // first launch: offer the tutorial
        visible: XCmdTutorial.offer && ov.cur === null && XCmd.screen === "list"
        x: Math.round((parent.width - width) / 2); y: parent.height - height - 28
        width: 460; height: 120; radius: 14; color: ThemeBackend.mantle; border.width: 1; border.color: Qt.alpha("#f9e2af", 0.6)
        CT { x: 20; y: 16; icon: true; text: "\u{f0335}"; size: 18; c: "#f9e2af" }
        CT { x: 50; y: 16; width: parent.width - 70; text: ov.t("cmd.tutorial.offer_title", "Первый раз в «Командах»?"); size: 14; font.bold: true }
        CT { x: 20; y: 44; width: parent.width - 40; wrapMode: Text.WordWrap; elide: Text.ElideNone; size: 11; c: ThemeBackend.subtext1
             text: ov.t("cmd.tutorial.offer_text", "Соберём простую команду за семь шагов. Вернуться к обучению можно в любой момент: кнопка «Обучение» слева.") }
        CmdBtn { x: parent.width - width - 20; y: parent.height - 44; h: 30; padX: 14; kind: "primary"; text: ov.t("cmd.tutorial.begin", "Начать"); onClicked: XCmdTutorial.start() }
        CmdBtn { x: parent.width - width - 110; y: parent.height - 44; h: 30; padX: 12; text: ov.t("cmd.tutorial.later", "Позже"); onClicked: XCmdTutorial.skip() }
    }
}
