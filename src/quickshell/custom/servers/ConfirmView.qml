import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// Confirmation of a dangerous command. danger = "confirm": two buttons; "typed": the server name must be typed.
Rectangle {
    id: root
    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    signal accepted(string typed)
    signal cancelled()

    readonly property var pend: XServers.pending
    readonly property var cmd: pend ? XServers.commandById(pend.commandId) : null
    readonly property var srv: pend ? XServers.serverById(pend.serverId) : null
    readonly property bool typed: cmd !== null && cmd.danger === "typed"
    readonly property bool matches: !typed || (srv !== null && field.text.trim() === srv.name)

    implicitWidth: s(460)
    implicitHeight: col.implicitHeight + s(40)
    radius: s(16)
    color: Qt.alpha(ThemeBackend.mantle, 0.98)
    border.width: 1
    border.color: Qt.alpha(ThemeBackend.red, 0.45)

    function description() {
        if (!cmd) return "";
        let key = "servers.confirm." + cmd.id;
        let generic = t("servers.confirm.generic", undefined, "Команда изменит состояние сервера.");
        let d = {
            "act-reboot": t(key, { n: (srv && srv.usersOnline !== null && srv.usersOnline !== undefined) ? srv.usersOnline : "?" }, "Узел перестанет принимать подключения: пользователи онлайн потеряют связь, пока Xray не поднимется заново."),
            "act-restart-node": t(key, undefined, "Контейнер ноды будет перезапущен, активные соединения прервутся на несколько секунд."),
            "act-update-container": t(key, undefined, "Будет скачан новый образ и контейнер ноды пересоздан. Соединения прервутся."),
            "act-docker-prune": t(key, undefined, "Будут удалены неиспользуемые образы и кэш сборки Docker. Тома и работающие контейнеры не затрагиваются.")
        };
        return d[cmd.id] || generic;
    }

    ColumnLayout {
        id: col
        anchors.fill: parent
        anchors.margins: root.s(20)
        spacing: root.s(12)

        RowLayout {
            Layout.fillWidth: true
            spacing: root.s(12)
            Rectangle {
                Layout.preferredWidth: root.s(38); Layout.preferredHeight: root.s(38); radius: root.s(11)
                color: Qt.alpha(ThemeBackend.red, 0.14)
                Text { anchors.centerIn: parent; text: root.cmd ? Glyphs.forCommand(root.cmd.id) : Glyphs.warn; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.red }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: root.s(2)
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: (root.cmd ? XServers.cmdLabel(root.cmd) : "") + "?"
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.weight: Font.DemiBold; color: ThemeBackend.text
                }
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: root.srv ? root.t("servers.confirm.on", { name: root.srv.name }, root.srv.name + " будет недоступен около минуты") : ""
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: desc.implicitHeight + root.s(22)
            radius: root.s(10)
            color: Qt.alpha(ThemeBackend.surface0, 0.7)
            Text {
                id: desc
                anchors.fill: parent; anchors.margins: root.s(11)
                wrapMode: Text.WordWrap
                text: root.description()
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.text
            }
        }

        Text {
            visible: root.typed
            text: root.t("servers.confirm.type_name", undefined, "Для подтверждения введите имя сервера")
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
        }
        Rectangle {
            visible: root.typed
            Layout.fillWidth: true; Layout.preferredHeight: root.s(38); radius: root.s(10)
            color: Qt.alpha(ThemeBackend.crust, 0.7)
            border.width: 1
            border.color: field.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.7)
            Behavior on border.color { ColorAnimation { duration: 140 } }
            TextInput {
                id: field
                anchors.fill: parent; anchors.leftMargin: root.s(12); anchors.rightMargin: root.s(12)
                verticalAlignment: TextInput.AlignVCenter
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.text
                selectByMouse: true
                clip: true
                focus: root.typed
                onAccepted: if (root.matches) root.accepted(text)
                Keys.onEscapePressed: root.cancelled()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: root.s(10)
            CmdButton {
                Layout.preferredWidth: root.s(110)
                label: root.t("servers.confirm.cancel", undefined, "Отмена")
                onClicked: root.cancelled()
            }
            Item { Layout.fillWidth: true }
            CmdButton {
                Layout.preferredWidth: root.s(190)
                danger: true
                icon: root.cmd ? Glyphs.forCommand(root.cmd.id) : ""
                label: root.cmd ? XServers.cmdLabel(root.cmd) : ""
                opacity: root.matches ? 1 : 0.4
                onClicked: if (root.matches) root.accepted(field.text)
            }
        }
    }
}
