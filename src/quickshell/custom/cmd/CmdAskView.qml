import QtQuick
import Quickshell
import "../../"
import ".."

// «Спросить меня»: one question of a running command, shown by the shell (daemon ui.request kind ask|confirm).
// Modes: choice (pick from a list), text, number, confirm (yes/no). Esc or «Отмена» answers {cancel: true}.
FocusScope {
    id: win
    required property var bridge
    readonly property var req: bridge.current
    readonly property var p: req ? req.payload : ({})
    readonly property string mode: req ? (req.kind === "confirm" ? "confirm" : (p.mode || "choice")) : "choice"
    readonly property var options: p.options || []
    readonly property string title: req ? (req.kind === "confirm" ? t("cmd.ask.confirm_title", "Подтвердите действие") : (p.title || t("cmd.ask.title", "Вопрос"))) : ""
    readonly property string subtitle: req ? (req.kind === "confirm" ? ((p.node || "") + (p.text ? ": " + p.text : "")) : (p.command || "")) : ""
    property int secs: 0
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    visible: req !== null
    implicitWidth: 520
    implicitHeight: card.height + 8

    onReqChanged: {
        if (req === null) return;
        input.text = p.default && mode !== "choice" ? p.default : "";
        secs = Math.round(p.timeout || 0);
        Qt.callLater(function () { if (mode === "text" || mode === "number") input.forceActiveFocus(); else focusItem.forceActiveFocus(); });
    }
    function cancel() { bridge.answer({ cancel: true }); }
    function submit() {
        if (mode === "text") bridge.answer({ value: input.text });
        else if (mode === "number") { if (input.acceptableInput && input.text.trim() !== "") bridge.answer({ value: input.text.trim().replace(",", ".") }); }
        else if (mode === "confirm") bridge.answer({ answer: true });
    }
    Timer { interval: 1000; repeat: true; running: win.visible && win.secs > 0; onTriggered: win.secs = Math.max(0, win.secs - 1) }

    FocusScope {
        id: focusItem
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.cancel()
        Keys.onReturnPressed: win.submit()
        Keys.onEnterPressed: win.submit()
        Keys.onPressed: (e) => {
            const d = e.key - Qt.Key_1;
            if (win.mode === "choice" && d >= 0 && d < Math.min(9, win.options.length)) { win.bridge.answer({ index: d }); e.accepted = true; }
            else if (win.mode === "confirm" && (e.key === Qt.Key_N)) { win.bridge.answer({ answer: false }); e.accepted = true; }
        }

        Rectangle {
            id: card
            width: parent.width - 8; x: 4; y: 4
            height: head.height + body.height + foot.height + 6
            radius: 16
            color: ThemeBackend.mantle
            border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.5)

            Item {
                id: head
                width: parent.width; height: 64
                Rectangle { x: 20; y: 16; width: 34; height: 34; radius: 10; color: Qt.alpha(ThemeBackend.mauve, 0.16)
                    CT { anchors.centerIn: parent; icon: true; size: 18; c: ThemeBackend.mauve; text: "\u{f02d7}" } }
                CT { x: 66; y: 12; width: parent.width - 90; size: 14; font.bold: true; text: win.title }
                CT { x: 66; y: 34; width: parent.width - 90; size: 10; c: ThemeBackend.subtext0; text: win.subtitle }
            }

            Item {
                id: body
                y: head.height; width: parent.width
                height: win.mode === "choice" ? 8 + opts.height : win.mode === "confirm" ? 4 : 52
                Column {
                    id: opts
                    visible: win.mode === "choice"
                    x: 20; y: 4; width: parent.width - 40; spacing: 4
                    Repeater {
                        model: win.mode === "choice" ? win.options : []
                        delegate: Rectangle {
                            width: opts.width; height: 36; radius: 8
                            color: oma.containsMouse ? Qt.alpha(ThemeBackend.mauve, 0.18) : ThemeBackend.surface0
                            CT { x: 12; y: 10; width: 24; size: 11; c: ThemeBackend.subtext0; text: index < 9 ? String(index + 1) : "" }
                            CT { x: 36; y: 9; width: parent.width - 48; size: 13; text: String(modelData) }
                            MouseArea { id: oma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.bridge.answer({ index: index }) }
                        }
                    }
                }
                Rectangle {
                    visible: win.mode === "text" || win.mode === "number"
                    x: 20; y: 4; width: parent.width - 40; height: 40; radius: 10; color: ThemeBackend.surface0
                    border.width: input.activeFocus ? 1 : 0; border.color: Qt.alpha(ThemeBackend.mauve, 0.7)
                    TextInput {
                        id: input
                        x: 14; width: parent.width - 28; height: parent.height
                        verticalAlignment: TextInput.AlignVCenter
                        color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(13)
                        clip: true
                        maximumLength: 4096
                        validator: win.mode === "number" ? numberRule : null
                        RegularExpressionValidator { id: numberRule; regularExpression: /^-?\d*[.,]?\d*$/ }
                        Keys.onReturnPressed: win.submit()
                        Keys.onEnterPressed: win.submit()
                        Keys.onEscapePressed: win.cancel()
                    }
                }
            }

            Item {
                id: foot
                y: head.height + body.height; width: parent.width; height: 58
                CT { x: 20; y: 20; width: 150; size: 10; c: ThemeBackend.subtext0
                     text: win.secs > 0 ? win.t("cmd.ask.left", "Осталось {n} с", { n: win.secs }) : "" }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: 20; y: 8; spacing: 10
                    CmdBtn { kind: "ghost"; text: win.t("cmd.ask.cancel", "Отмена"); onClicked: win.cancel() }
                    CmdBtn { visible: win.mode === "confirm"; text: win.t("cmd.ask.no", "Нет"); onClicked: win.bridge.answer({ answer: false }) }
                    CmdBtn { visible: win.mode === "confirm"; kind: "primary"; text: win.t("cmd.ask.yes", "Да"); onClicked: win.submit() }
                    CmdBtn { visible: win.mode === "text" || win.mode === "number"; kind: "primary"; text: win.t("cmd.ask.ok", "Готово"); onClicked: win.submit() }
                }
            }
        }
    }
}
