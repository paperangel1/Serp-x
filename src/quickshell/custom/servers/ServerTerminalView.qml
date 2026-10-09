import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../../"
import ".."

// Mini terminal: streamed output of a server command with copy / repeat / close.
// Reads everything from XServers (termTitle, termLines, termRunning, termExit).
Rectangle {
    id: root
    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    signal closeRequested()

    implicitWidth: s(600)
    implicitHeight: s(540)
    radius: s(16)
    color: Qt.alpha(ThemeBackend.mantle, 0.98)
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.surface1, 0.7)

    readonly property var srv: XServers.serverById(XServers.termServerId)
    readonly property var ex: XServers.termExit
    readonly property bool failed: ex !== null && ex.code !== 0

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.s(16)
        spacing: root.s(10)

        RowLayout {
            Layout.fillWidth: true
            spacing: root.s(12)
            Rectangle {
                Layout.preferredWidth: root.s(34); Layout.preferredHeight: root.s(34); radius: root.s(10)
                color: Qt.alpha(ThemeBackend.mauve, 0.14)
                Text { anchors.centerIn: parent; text: Glyphs.terminal; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.mauve }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: root.s(2)
                Text {
                    Layout.fillWidth: true; elide: Text.ElideRight
                    text: XServers.termTitle
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.weight: Font.DemiBold; color: ThemeBackend.text
                }
                Text {
                    Layout.fillWidth: true; elide: Text.ElideRight
                    text: "ssh " + (root.srv ? (root.srv.user || "serp") + "@" + ((root.srv.ssh && root.srv.ssh.status && root.srv.ssh.status.host) ? root.srv.ssh.status.host : root.srv.address) : "") + "  ·  " + root.t("servers.term.restricted", undefined, "ключ с ограничением") + "  ·  forced command"
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }
            }
            Rectangle {
                Layout.preferredWidth: root.s(30); Layout.preferredHeight: root.s(30); radius: root.s(9)
                color: xMa.containsMouse ? Qt.alpha(ThemeBackend.red, 0.35) : Qt.alpha(ThemeBackend.surface0, 0.8)
                Behavior on color { ColorAnimation { duration: 140 } }
                Text { anchors.centerIn: parent; text: Glyphs.close; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fSub; color: ThemeBackend.text }
                MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeRequested() }
            }
        }

        Rectangle {
            Layout.fillWidth: true; Layout.fillHeight: true
            radius: root.s(10)
            color: Qt.alpha(ThemeBackend.crust, 0.85)
            border.width: 1; border.color: Qt.alpha(ThemeBackend.surface1, 0.4)
            clip: true

            ListView {
                id: out
                anchors.fill: parent; anchors.margins: root.s(12)
                model: XServers.termLines
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                property bool follow: true
                onMovementEnded: follow = atYEnd
                onCountChanged: if (follow) Qt.callLater(positionViewAtEnd)
                header: Text {
                    width: out.width
                    text: "$ serp-run " + XServers.termCommandId
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                    bottomPadding: root.s(2)
                }
                delegate: Text {
                    required property string modelData
                    width: out.width
                    text: modelData === "" ? " " : modelData
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: modelData.indexOf("==") === 0 ? ThemeBackend.mauve : ThemeBackend.text
                }
                ScrollBar.vertical: null
            }
            Text {
                visible: XServers.termRunning && XServers.termLines.length === 0
                anchors.centerIn: parent
                text: root.t("servers.term.waiting", undefined, "Подключаюсь…")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: root.s(10)
            Rectangle {
                implicitWidth: statusText.implicitWidth + root.s(18); implicitHeight: root.s(20); radius: root.s(6)
                color: Qt.alpha(XServers.termRunning ? ThemeBackend.mauve : (root.failed ? ThemeBackend.red : ThemeBackend.green), 0.16)
                Text {
                    id: statusText; anchors.centerIn: parent
                    text: XServers.termRunning ? root.t("servers.term.running", undefined, "выполняется…")
                          : (root.ex === null ? "" : (root.ex.timedOut ? root.t("servers.term.timeout", undefined, "таймаут")
                          : (root.failed ? root.t("servers.term.failed", { code: root.ex.code }, "ошибка · код " + root.ex.code)
                          : root.t("servers.term.done", { sec: (root.ex.ms / 1000).toFixed(1) }, "завершено · " + (root.ex.ms / 1000).toFixed(1) + " с"))))
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: XServers.termRunning ? ThemeBackend.mauve : (root.failed ? ThemeBackend.red : ThemeBackend.green)
                }
            }
            Text {
                visible: root.ex !== null && root.ex.dropped > 0
                text: root.t("servers.term.truncated", { n: 400 }, "вывод урезан до 400 строк")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
            }
            Item { Layout.fillWidth: true }
            CmdButton {
                Layout.preferredWidth: root.s(120)
                icon: Glyphs.repeat; label: root.t("servers.term.repeat", undefined, "Повторить")
                opacity: XServers.termRunning ? 0.45 : 1
                onClicked: if (!XServers.termRunning) XServers.rerun()
            }
            Rectangle {
                id: copyBtn
                Layout.preferredWidth: root.s(120); Layout.preferredHeight: root.s(34); radius: root.s(9)
                color: copyMa.pressed ? Qt.darker(ThemeBackend.mauve, 1.15) : (copyMa.containsMouse ? Qt.lighter(ThemeBackend.mauve, 1.08) : ThemeBackend.mauve)
                scale: copyMa.pressed ? 0.98 : 1
                Behavior on color { ColorAnimation { duration: 140 } }
                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutQuint } }
                Row {
                    anchors.centerIn: parent; spacing: root.s(7)
                    Text { text: copyBtn.copied ? Glyphs.check : Glyphs.copy; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fSub; color: ThemeBackend.crust; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: copyBtn.copied ? root.t("servers.term.copied", undefined, "Скопировано") : root.t("servers.term.copy", undefined, "Копировать"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.DemiBold; color: ThemeBackend.crust; anchors.verticalCenter: parent.verticalCenter }
                }
                property bool copied: false
                Timer { id: copiedTimer; interval: 1500; onTriggered: parent.copied = false }
                MouseArea { id: copyMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { XServers.copyOutput(); parent.copied = true; copiedTimer.restart(); } }
            }
        }
    }
}
