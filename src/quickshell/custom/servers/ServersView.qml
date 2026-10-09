import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../"
import "../../reusables"
import ".."

// The Servers widget content: compact list ("list") and the detailed view of one server ("detail").
// Data comes from the XServers singleton; the widget faces only choose the starting mode.
Item {
    id: root

    property string mode: "list"        // list | detail

    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    Component.onCompleted: XServers.subscribe()
    Component.onDestruction: XServers.unsubscribe()

    readonly property var sel: XServers.selected
    readonly property var status: (sel && sel.ssh && sel.ssh.status) ? sel.ssh.status : null

    function apiErrorText(code) {
        if (code === "not_configured") return t("servers.err.not_configured", undefined, "Панель Remnawave не настроена");
        if (code === "http_401" || code === "http_403") return t("servers.err.auth", undefined, "Панель отклонила токен");
        if (code === "insecure_url") return t("servers.err.insecure", undefined, "Адрес панели должен начинаться с https://");
        if (code.indexOf("network") === 0) return t("servers.err.network", undefined, "Панель недоступна");
        return t("servers.err.generic", undefined, "Не удалось получить список серверов");
    }

    Rectangle {
        id: card
        anchors.fill: parent
        radius: s(16)
        color: Qt.alpha(ThemeBackend.mantle, 0.97)
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface1, 0.6)
        clip: true

        // ========================= header (shared) =========================
        RowLayout {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: root.s(14) }
            height: root.mode === "list" ? root.s(34) : root.s(44)
            spacing: root.s(10)

            Rectangle {
                visible: root.mode === "list"
                Layout.preferredWidth: root.s(32); Layout.preferredHeight: root.s(32)
                radius: root.s(9)
                color: Qt.alpha(ThemeBackend.mauve, 0.14)
                Text { anchors.centerIn: parent; text: Glyphs.server; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.mauve }
            }
            ServerDot { visible: root.mode === "detail"; server: root.sel; Layout.alignment: Qt.AlignTop; Layout.topMargin: root.s(6) }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: root.s(2)
                // list header
                Text {
                    visible: root.mode === "list"
                    Layout.fillWidth: true; elide: Text.ElideRight
                    text: root.t("servers.title", undefined, "Серверы")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.weight: Font.DemiBold
                    color: ThemeBackend.text
                }
                Text {
                    visible: root.mode === "list"
                    Layout.fillWidth: true; elide: Text.ElideRight
                    text: XServers.configured || XServers.servers.length > 0
                          ? root.t("servers.subtitle", { n: XServers.onlineCount, total: XServers.visibleServers.length }, XServers.onlineCount + " из " + XServers.visibleServers.length + " в сети")
                          : root.t("servers.not_configured_short", undefined, "панель не подключена")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
                // detail header
                RowLayout {
                    visible: root.mode === "detail"
                    spacing: root.s(8)
                    Text {
                        text: root.sel ? ((root.sel.flag ? root.sel.flag + " " : "") + root.sel.name) : ""
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fTitle; font.weight: Font.Bold
                        color: ThemeBackend.text
                        elide: Text.ElideRight
                        Layout.maximumWidth: root.width * 0.5
                    }
                    Rectangle {
                        implicitWidth: chipA.implicitWidth + root.s(12); implicitHeight: root.s(16); radius: root.s(5)
                        color: Qt.alpha(root.sel && root.sel.online === true ? ThemeBackend.green : ThemeBackend.red, 0.16)
                        Text {
                            id: chipA; anchors.centerIn: parent
                            text: root.sel && root.sel.online === true ? root.t("servers.online", undefined, "в сети") : root.t("servers.offline", undefined, "офлайн")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                            color: root.sel && root.sel.online === true ? ThemeBackend.green : ThemeBackend.red
                        }
                    }
                    Rectangle {
                        visible: root.sel && root.sel.xrayVersion
                        implicitWidth: chipB.implicitWidth + root.s(12); implicitHeight: root.s(16); radius: root.s(5)
                        color: Qt.alpha(ThemeBackend.surface2, 0.5)
                        Text {
                            id: chipB; anchors.centerIn: parent
                            text: "Xray " + (root.sel ? root.sel.xrayVersion : "")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                        }
                    }
                }
                Text {
                    visible: root.mode === "detail"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        if (!root.sel) return "";
                        let parts = [];
                        parts.push(root.status && root.status.host ? root.status.host : root.sel.address);
                        if (root.sel.usersOnline !== null && root.sel.usersOnline !== undefined)
                            parts.push(root.t("servers.users_online", { n: root.sel.usersOnline }, root.sel.usersOnline + " пользователей онлайн"));
                        parts.push(root.t("servers.data_from", undefined, "данные Remnawave") + (XServers.sshOk(root.sel) ? " + SSH" : ""));
                        return parts.join("  ·  ");
                    }
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }
            }

            Rectangle {   // refresh (list) / back (detail)
                Layout.preferredWidth: root.s(30); Layout.preferredHeight: root.s(30)
                radius: root.s(9)
                color: hdrMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.9) : Qt.alpha(ThemeBackend.surface0, 0.8)
                Behavior on color { ColorAnimation { duration: 140 } }
                Text {
                    anchors.centerIn: parent
                    text: root.mode === "list" ? Glyphs.refresh : Glyphs.back
                    font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fTitle; color: ThemeBackend.text
                    rotation: (root.mode === "list" && XServers.polling) ? 360 : 0
                    Behavior on rotation { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } }
                }
                MouseArea {
                    id: hdrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.mode === "list" ? XServers.refresh() : (root.mode = "list")
                }
            }
        }

        Rectangle {
            id: divider
            anchors { top: header.bottom; left: parent.left; right: parent.right; leftMargin: root.s(14); rightMargin: root.s(14); topMargin: root.s(4) }
            height: 1
            color: Qt.alpha(ThemeBackend.surface1, 0.5)
        }

        // ========================= list mode =========================
        Item {
            id: listPane
            visible: root.mode === "list"
            anchors { top: divider.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }

            // empty / error states
            ColumnLayout {
                visible: XServers.visibleServers.length === 0
                anchors.centerIn: parent
                width: parent.width - root.s(40)
                spacing: root.s(8)
                Text {
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: XServers.apiError !== "" ? root.apiErrorText(XServers.apiError) : root.t("servers.empty", undefined, "Нет серверов")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.text
                }
                Text {
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: root.t("servers.empty_hint", undefined, "Настройки → Серверы: адрес панели и API-токен")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }
            }

            ListView {
                id: rows
                visible: XServers.visibleServers.length > 0
                anchors { top: parent.top; left: parent.left; right: parent.right; bottom: listFooter.top; margins: root.s(8) }
                model: XServers.visibleServers
                spacing: root.s(4)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property var sv: modelData
                    readonly property bool isSel: sv.id === XServers.selectedId
                    readonly property real cpu: XServers.cpuOf(sv)
                    width: rows.width
                    height: root.s(42)
                    radius: root.s(9)
                    color: rowMa.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.7) : "transparent"
                    border.width: isSel ? 1 : 0
                    border.color: Qt.alpha(ThemeBackend.mauve, 0.55)
                    Behavior on color { ColorAnimation { duration: 140 } }

                    ServerDot { id: rowDot; server: row.sv; anchors.left: parent.left; anchors.leftMargin: root.s(10); anchors.verticalCenter: parent.verticalCenter }

                    Column {
                        anchors.left: rowDot.right; anchors.leftMargin: root.s(10)
                        anchors.right: right.left; anchors.rightMargin: root.s(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: root.s(1)
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: (row.sv.flag ? row.sv.flag + " " : "") + row.sv.name
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; font.weight: row.isSel ? Font.DemiBold : Font.Normal
                            color: ThemeBackend.text
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: {
                                if (row.sv.online !== true) {
                                    let lc = row.sv.lastChange;
                                    let ms = (typeof lc === "number") ? (lc < 1e12 ? lc * 1000 : lc) : (lc ? Date.parse(lc) : 0);
                                    return root.t("servers.no_answer", undefined, "нет ответа") + (ms > 0 && !isNaN(ms) ? " " + XServers.ago(ms) : "");
                                }
                                if (XServers.sshOk(row.sv)) return "CPU " + row.cpu + "%  ·  " + root.t("servers.uptime_short", undefined, "аптайм") + " " + XServers.fmtUptime(row.sv.ssh.status.uptime);
                                if (row.sv.usersOnline !== null && row.sv.usersOnline !== undefined)
                                    return root.t("servers.users_short", { n: row.sv.usersOnline }, row.sv.usersOnline + " онлайн") + "  ·  " + root.t("servers.ssh_off", undefined, "SSH не подключён");
                                return root.t("servers.ssh_off", undefined, "SSH не подключён");
                            }
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                        }
                    }

                    Item {
                        id: right
                        anchors.right: parent.right; anchors.rightMargin: root.s(12); anchors.verticalCenter: parent.verticalCenter
                        width: root.s(54); height: root.s(14)
                        Text {
                            visible: row.sv.online !== true
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: root.t("servers.offline", undefined, "офлайн")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.red
                        }
                        Rectangle {
                            visible: row.sv.online === true && row.cpu >= 0
                            anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right
                            width: parent.width; height: root.s(4); radius: height / 2
                            color: Qt.alpha(ThemeBackend.surface2, 0.5)
                            Rectangle {
                                width: parent.width * Math.max(0.04, Math.min(1, row.cpu / 100)); height: parent.height; radius: height / 2
                                color: row.cpu >= 55 ? ThemeBackend.yellow : ThemeBackend.mauve
                                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                            }
                        }
                    }

                    MouseArea {
                        id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: XServers.select(row.sv.id)
                        onDoubleClicked: { XServers.select(row.sv.id); root.mode = "detail"; }
                    }
                }
            }

            Item {
                id: listFooter
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: root.s(34)
                Rectangle { anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right; anchors.leftMargin: root.s(14); anchors.rightMargin: root.s(14); height: 1; color: Qt.alpha(ThemeBackend.surface1, 0.5) }
                Text {
                    anchors.left: parent.left; anchors.leftMargin: root.s(14); anchors.verticalCenter: parent.verticalCenter
                    text: XServers.lastPollMs > 0 ? root.t("servers.updated_ago", { t: XServers.ago(XServers.lastPollMs) }, "обновлено " + XServers.ago(XServers.lastPollMs) + " назад") : ""
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }
                Text {
                    visible: XServers.visibleServers.length > 0
                    anchors.right: parent.right; anchors.rightMargin: root.s(14); anchors.verticalCenter: parent.verticalCenter
                    text: root.t("servers.more", undefined, "подробнее") + " →"
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: moreMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.subtext0
                    MouseArea { id: moreMa; anchors.fill: parent; anchors.margins: -root.s(6); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.mode = "detail" }
                }
            }
        }

        // ========================= detail mode =========================
        Flickable {
            id: detailPane
            visible: root.mode === "detail"
            anchors { top: divider.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; margins: root.s(14); topMargin: root.s(12) }
            contentWidth: width
            contentHeight: detailCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: detailCol
                width: detailPane.width
                spacing: root.s(10)

                Text {
                    visible: !root.sel
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                    text: root.t("servers.pick_one", undefined, "Выберите сервер в списке")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }

                GridLayout {
                    visible: !!root.sel
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: root.s(8); rowSpacing: root.s(8)
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.cpu", undefined, "Процессор")
                        value: root.status ? root.status.cpu + "%" : "—"
                        fraction: root.status ? root.status.cpu / 100 : -1
                    }
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.mem", undefined, "Память")
                        value: root.status && root.status.memTotalKb ? ((root.status.memTotalKb - root.status.memAvailKb) / 1048576).toFixed(1) + " / " + (root.status.memTotalKb / 1048576).toFixed(1) : "—"
                        unit: root.status && root.status.memTotalKb ? root.t("servers.u.gb", undefined, "ГБ") : ""
                        fraction: root.status && root.status.memTotalKb ? (root.status.memTotalKb - root.status.memAvailKb) / root.status.memTotalKb : -1
                    }
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.disk", undefined, "Диск")
                        value: root.status ? root.status.diskPct + "%" : "—"
                        fraction: root.status ? root.status.diskPct / 100 : -1
                    }
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.load", undefined, "Нагрузка")
                        value: root.status && root.status.load ? Number(root.status.load[0]).toFixed(2) : "—"
                        note: root.status && root.status.load ? Number(root.status.load[1]).toFixed(2) + "  ·  " + Number(root.status.load[2]).toFixed(2) : ""
                    }
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.uptime", undefined, "Аптайм")
                        value: root.status ? XServers.fmtUptime(root.status.uptime) : "—"
                    }
                    MetricTile {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        caption: root.t("servers.m.traffic", undefined, "Трафик ноды")
                        value: root.sel && root.sel.trafficUsed !== null && root.sel.trafficUsed !== undefined ? XServers.fmtBytes(root.sel.trafficUsed) : "—"
                        note: root.sel && root.sel.trafficUsed !== null && root.sel.trafficUsed !== undefined ? root.t("servers.m.traffic_note", undefined, "по данным панели") : ""
                    }
                }

                // SSH not connected: explain and point to the settings
                Rectangle {
                    visible: !!root.sel && !XServers.sshOk(root.sel)
                    Layout.fillWidth: true
                    implicitHeight: sshHint.implicitHeight + root.s(18)
                    radius: root.s(9)
                    color: Qt.alpha(ThemeBackend.yellow, 0.1)
                    border.width: 1; border.color: Qt.alpha(ThemeBackend.yellow, 0.35)
                    Text {
                        id: sshHint
                        anchors.fill: parent; anchors.margins: root.s(9)
                        wrapMode: Text.WordWrap
                        text: root.t("servers.ssh_hint", undefined, "SSH-доступ не настроен: метрики и команды недоступны. Настройки → Серверы → «Подключить».")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.yellow
                    }
                }

                Text {
                    visible: !!root.sel && XServers.diagCommands.length > 0
                    text: root.t("servers.sec_diag", undefined, "ДИАГНОСТИКА")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.Bold; font.letterSpacing: 1.4
                    color: ThemeBackend.mauve
                }
                GridLayout {
                    visible: !!root.sel
                    Layout.fillWidth: true
                    columns: 3; columnSpacing: root.s(8); rowSpacing: root.s(8)
                    Repeater {
                        model: XServers.diagCommands
                        CmdButton {
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredWidth: 1
                            icon: Glyphs.forCommand(modelData.id); label: XServers.cmdLabel(modelData)
                            opacity: XServers.sshOk(root.sel) ? 1 : 0.45
                            onClicked: if (XServers.sshOk(root.sel)) XServers.requestRun(root.sel.id, modelData.id)
                        }
                    }
                }

                Text {
                    visible: !!root.sel && XServers.actionCommands.length > 0
                    text: root.t("servers.sec_actions", undefined, "ДЕЙСТВИЯ")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.Bold; font.letterSpacing: 1.4
                    color: ThemeBackend.mauve
                }
                GridLayout {
                    visible: !!root.sel
                    Layout.fillWidth: true
                    columns: 2; columnSpacing: root.s(8); rowSpacing: root.s(8)
                    Repeater {
                        model: XServers.actionCommands
                        CmdButton {
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredWidth: 1
                            icon: Glyphs.forCommand(modelData.id); label: XServers.cmdLabel(modelData)
                            danger: modelData.danger === "typed"
                            opacity: XServers.sshOk(root.sel) ? 1 : 0.45
                            onClicked: if (XServers.sshOk(root.sel)) XServers.requestRun(root.sel.id, modelData.id)
                        }
                    }
                }
                Text {
                    visible: !!root.sel && XServers.actionCommands.length > 0
                    text: root.t("servers.danger_note", undefined, "Опасные действия просят подтверждение")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                }

                Text {
                    visible: !!root.sel
                    text: root.t("servers.sec_custom", undefined, "СВОИ КОМАНДЫ")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.Bold; font.letterSpacing: 1.4
                    color: ThemeBackend.mauve
                }
                GridLayout {
                    visible: !!root.sel
                    Layout.fillWidth: true
                    columns: 3; columnSpacing: root.s(8); rowSpacing: root.s(8)
                    Repeater {
                        model: XServers.customCommandList
                        CmdButton {
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredWidth: 1
                            icon: Glyphs.file; label: XServers.cmdLabel(modelData)
                            danger: modelData.danger === "typed"
                            opacity: XServers.sshOk(root.sel) ? 1 : 0.45
                            onClicked: if (XServers.sshOk(root.sel)) XServers.requestRun(root.sel.id, modelData.id)
                        }
                    }
                    CmdButton {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        icon: Glyphs.plus; label: root.t("servers.add_command", undefined, "Добавить…")
                        onClicked: XServers.openCommandsFile()
                    }
                }

                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Qt.alpha(ThemeBackend.surface1, 0.5) }

                RowLayout {
                    visible: !!root.sel
                    Layout.fillWidth: true
                    spacing: root.s(10)
                    readonly property var lr: root.sel ? XServers.lastRuns[root.sel.id] : null
                    Rectangle {
                        Layout.preferredWidth: root.s(8); Layout.preferredHeight: root.s(8); radius: width / 2
                        visible: parent.lr !== undefined && parent.lr !== null
                        color: parent.lr && parent.lr.code === 0 ? ThemeBackend.green : ThemeBackend.red
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: root.s(1)
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: parent.parent.lr
                                  ? ((XServers.commandById(parent.parent.lr.command) ? XServers.cmdLabel(XServers.commandById(parent.parent.lr.command)) : parent.parent.lr.command)
                                     + "  ·  " + XServers.ago(parent.parent.lr.ts) + " " + root.t("servers.ago", undefined, "назад")
                                     + "  ·  " + root.t("servers.code", undefined, "код") + " " + parent.parent.lr.code)
                                  : root.t("servers.no_runs", undefined, "Команды ещё не запускались")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.text
                        }
                    }
                    CmdButton {
                        Layout.preferredWidth: root.s(96)
                        icon: Glyphs.terminal; label: root.t("servers.terminal", undefined, "Терминал")
                        opacity: XServers.termLines.length > 0 || XServers.termRunning ? 1 : 0.45
                        onClicked: if (XServers.termLines.length > 0 || XServers.termRunning) XServers.termVisible = true
                    }
                }
            }
        }
    }
}
