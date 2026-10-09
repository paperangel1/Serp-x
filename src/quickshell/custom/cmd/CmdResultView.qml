import QtQuick
import Quickshell
import "../../"
import ".."

// «Показать результат»: the text a command wants to show (daemon ui.request kind show). Does not hold the command: the run
// was already answered; the popup stays until it is closed (Esc, the button, or a click outside the card is not needed).
FocusScope {
    id: win
    required property var bridge
    readonly property var res: bridge.result
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    visible: res !== null
    implicitWidth: 520
    implicitHeight: card.height + 8
    function close() { bridge.result = null; }

    FocusScope {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.close()
        Keys.onReturnPressed: win.close()
        Keys.onEnterPressed: win.close()
        Rectangle {
            id: card
            width: parent.width - 8; x: 4; y: 4
            height: head.height + Math.min(textView.contentHeight, 320) + 24 + 58
            radius: 16
            color: ThemeBackend.mantle
            border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.5)
            Item {
                id: head
                width: parent.width; height: 56
                Rectangle { x: 20; y: 12; width: 34; height: 34; radius: 10; color: Qt.alpha(ThemeBackend.mauve, 0.16)
                    CT { anchors.centerIn: parent; icon: true; size: 18; c: ThemeBackend.mauve; text: "\u{f0026}" } }
                CT { x: 66; y: 18; width: parent.width - 90; size: 14; font.bold: true; text: win.res && win.res.title !== "" ? win.res.title : win.t("cmd.result.title", "Результат") }
            }
            Flickable {
                id: flick
                x: 20; y: head.height; width: parent.width - 40; height: Math.min(textView.contentHeight, 320) + 12
                contentHeight: textView.contentHeight; clip: true
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: textView
                    width: flick.width
                    text: win.res ? win.res.text : ""
                    color: ThemeBackend.text; wrapMode: Text.Wrap
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(13)
                    textFormat: Text.PlainText
                }
            }
            Row {
                anchors.right: parent.right; anchors.rightMargin: 20; y: parent.height - 50; spacing: 10
                CmdBtn { kind: "primary"; text: win.t("cmd.result.close", "Закрыть"); onClicked: win.close() }
            }
        }
    }
}
