import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../../"
import "../../reusables"
import ".."

// «Серверы» settings tab: Remnawave panel, restricted SSH key, own commands, servers shown in the widget.
Item {
    id: tabRoot
    objectName: "serversTab"
    required property var rootObj
    required property int tabIndex

    anchors.fill: parent
    visible: rootObj.currentTab === tabIndex
    opacity: visible ? 1.0 : 0.0
    property real slideY: visible ? 0 : rootObj.s(10)
    Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
    transform: Translate { y: slideY }
    Behavior on opacity { NumberAnimation { duration: 250 } }

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    property bool subscribed: false
    onVisibleChanged: {
        if (visible && !subscribed) { XServers.subscribe(); subscribed = true; }
        else if (!visible && subscribed) { XServers.unsubscribe(); subscribed = false; }
    }
    Component.onCompleted: if (visible && !subscribed) { XServers.subscribe(); subscribed = true; }
    Component.onDestruction: if (subscribed) XServers.unsubscribe()

    property string editing: ""            // "", "url", "token"
    property string enrollFor: ""          // server id whose enrollment form is open
    property bool confirmNewKey: false
    property bool addOpen: false
    property bool addAdvanced: false
    property bool addTried: false
    property string removeFor: ""          // manual server id whose delete panel is open

    // ---- «Добавить сервер»: the same rules as the backend (x_servers.py validate_server_fields) ----
    function hostOk(h) {
        if (h === "" || h.length > 253) return false;
        if (/^[0-9.]+$/.test(h)) {
            let p = h.split(".");
            return p.length === 4 && p.every(x => /^[0-9]{1,3}$/.test(x) && parseInt(x) <= 255);
        }
        if (h.indexOf(":") !== -1) return /^[0-9A-Fa-f:.]+$/.test(h) && (h.match(/:/g) || []).length >= 2;
        return h.replace(/\.$/, "").split(".").every(l => /^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(l));
    }
    function nameErr(v) {
        let n = v.trim();
        return (n === "" || n.length > 60 || /[\x00-\x1f\x7f]/.test(n)) ? t("servers.tab.err_name", undefined, "Название: от 1 до 60 символов") : "";
    }
    function hostErr(v) { return hostOk(v.trim()) ? "" : t("servers.tab.err_host", undefined, "Адрес: домен или IP"); }
    function portErr(v) {
        if (v.trim() === "") return "";
        let n = parseInt(v);
        return (/^[0-9]{1,5}$/.test(v.trim()) && n >= 1 && n <= 65535) ? "" : t("servers.tab.err_port", undefined, "Порт: число от 1 до 65535");
    }
    function userErr(v) {
        return (v === "" || /^[a-z_][a-z0-9_-]{0,31}$/.test(v)) ? "" : t("servers.tab.err_user", undefined, "Недопустимое имя");
    }
    // an error is shown for a touched field, or for every field after a click on «Добавить»
    function shown(msg, text) { return (addTried || text !== "") ? msg : ""; }
    function addValid() {
        return nameErr(addName.text) === "" && hostErr(addHost.text) === "" && portErr(addPort.text) === "" && userErr(addUser.text) === "";
    }
    function resetAdd() { addName.clear(); addHost.clear(); addPort.clear(); addUser.clear(); addTried = false; addAdvanced = false; }
    function submitAdd() {
        addTried = true;
        if (!addValid()) return;
        XServers.addServer(addName.text.trim(), addHost.text.trim().toLowerCase(), parseInt(addPort.text) || 22, addUser.text);
    }
    function addStateText(code) {
        if (code === "running") return t("servers.tab.adding", undefined, "добавляю…");
        let c = code.split(":")[1];
        if (c === "bad_name") return t("servers.tab.err_name", undefined, "Название");
        if (c === "bad_host") return t("servers.tab.err_host", undefined, "Адрес");
        if (c === "bad_port") return t("servers.tab.err_port", undefined, "Порт");
        if (c === "bad_user") return t("servers.tab.err_user", undefined, "Имя");
        if (c === "duplicate") return t("servers.tab.err_dup", undefined, "Такой сервер уже добавлен");
        if (c === "config_broken") return t("servers.tab.err_broken", undefined, "servers.toml повреждён");
        if (c === "write_failed") return t("servers.tab.err_write", undefined, "Не удалось записать servers.toml");
        if (c === "bad_id" || c === "id_taken") return t("servers.tab.err_id", undefined, "Недопустимый идентификатор");
        return t("servers.tab.err_add", undefined, "Не удалось добавить сервер");
    }
    readonly property string allowedList: ["status"].concat((XServers.allCommands || []).map(c => c.id)).join(", ")

    Connections {      // «Убрать и доступ с сервера»: once the restricted access is gone, drop the entry too
        target: XServers
        function onEnrollStateChanged() {
            if (XServers.enrollState === "removed" && tabRoot.removeFor !== "") {
                XServers.removeServer(tabRoot.removeFor, true);
                tabRoot.removeFor = "";
                XServers.enrollState = "";
            }
        }
    }

    readonly property var pollKeys: [15, 30, 60, 120]
    readonly property var pollLabels: [t("servers.tab.poll_15", undefined, "каждые 15 с"), t("servers.tab.poll_30", undefined, "каждые 30 с"),
                                       t("servers.tab.poll_60", undefined, "каждую минуту"), t("servers.tab.poll_120", undefined, "каждые 2 минуты")]

    function checkText(code) {
        if (code === "checking") return t("servers.tab.checking", undefined, "проверяю…");
        if (code.indexOf("ok:") === 0) return t("servers.tab.check_ok", { n: code.substring(3) }, "работает · узлов: " + code.substring(3));
        if (code === "not_configured") return t("servers.err.not_configured", undefined, "не настроена");
        if (code === "http_401" || code === "http_403") return t("servers.err.auth", undefined, "токен отклонён");
        if (code === "insecure_url") return t("servers.err.insecure", undefined, "нужен https://");
        return t("servers.err.generic", undefined, "ошибка");
    }
    function enrollText(code) {
        if (code === "running") return t("servers.tab.enrolling", undefined, "подключаю…");
        if (code === "removed") return t("servers.tab.unenrolled_ok", undefined, "готово: доступ с сервера удалён");
        if (code === "ok") return t("servers.tab.enrolled_ok", undefined, "готово: SSH-ключ ограничен");
        let p = code.split(":");
        if (p[1] === "login") return t("servers.tab.enroll_login", undefined, "не удалось войти: проверьте логин и пароль");
        return t("servers.tab.enroll_fail", undefined, "не удалось установить доступ") + (p.slice(2).join(":") !== "" ? " — " + p.slice(2).join(":").substring(0, 90) : "");
    }

    component SectionLabel: Text {
        Layout.fillWidth: true
        Layout.topMargin: rootObj.s(4)
        Layout.leftMargin: rootObj.s(4)
        font.family: ThemeBackend.fontFamily
        font.pixelSize: XUi.fCaption
        font.weight: Font.Bold
        font.letterSpacing: 1.5
        color: ThemeBackend.mauve
    }
    component Chip: Rectangle {
        property string label: ""
        property color tone: ThemeBackend.green
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: chipText.implicitWidth + rootObj.s(14); implicitHeight: rootObj.s(20); radius: rootObj.s(6)
        color: Qt.alpha(tone, 0.16)
        Text { id: chipText; anchors.centerIn: parent; text: parent.label; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: parent.tone }
    }
    component TG: Toggle {
        Layout.alignment: Qt.AlignVCenter
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface1
        handleColor: ThemeBackend.crust
        handleOffColor: ThemeBackend.text
    }
    component DD: Dropdown {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: rootObj.s(190)
        implicitHeight: rootObj.s(34)
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface0
        hoverColor: ThemeBackend.surface1
        dropdownColor: ThemeBackend.surface0
        borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
        textColor: ThemeBackend.text
        activeTextColor: ThemeBackend.crust
    }
    component Btn: ClickButton {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredHeight: rootObj.s(32)
        cornerRadius: ThemeBackend.borderRadius
        accentColor: ThemeBackend.surface0
        textColor: ThemeBackend.text
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: rootObj.s(8)
        contentHeight: pageCol.implicitHeight + rootObj.s(8)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: pageCol
            width: parent.width
            spacing: rootObj.s(8)

            // ---------------- panel ----------------
            SectionLabel { text: tabRoot.t("servers.tab.sec_panel", undefined, "ПАНЕЛЬ REMNAWAVE") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.link
                title: tabRoot.t("servers.tab.url", undefined, "Адрес панели")
                description: XServers.cfgInfo.urlSet ? ("https://" + XServers.cfgInfo.host) : tabRoot.t("servers.tab.not_set", undefined, "не задан")
                Btn { buttonText: tabRoot.t("servers.tab.change", undefined, "Изменить"); onClicked: { tabRoot.editing = tabRoot.editing === "url" ? "" : "url"; urlField.clear(); } }
            }
            RowLayout {
                visible: tabRoot.editing === "url"
                Layout.fillWidth: true
                Layout.leftMargin: rootObj.s(12); Layout.rightMargin: rootObj.s(12)
                spacing: rootObj.s(8)
                SecretField { id: urlField; Layout.fillWidth: true; masked: false; placeholder: "https://panel.example.com"; onAccepted: saveUrl.clicked() }
                Btn { id: saveUrl; buttonText: tabRoot.t("servers.tab.save", undefined, "Сохранить"); accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                    onClicked: { if (urlField.text !== "") { XServers.setSecret("remnawave_url", urlField.text); urlField.clear(); tabRoot.editing = ""; } } }
            }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.key
                title: tabRoot.t("servers.tab.token", undefined, "API-токен")
                description: tabRoot.t("servers.tab.token_d", undefined, "Хранится в ~/.config/serpantinum/secrets/ (права 600)")
                Chip { label: XServers.cfgInfo.tokenSet ? tabRoot.t("servers.tab.is_set", undefined, "задан") : tabRoot.t("servers.tab.not_set", undefined, "не задан"); tone: XServers.cfgInfo.tokenSet ? ThemeBackend.green : ThemeBackend.yellow }
                Chip { visible: XServers.checkResult !== ""; label: tabRoot.checkText(XServers.checkResult); tone: XServers.checkResult.indexOf("ok:") === 0 ? ThemeBackend.green : (XServers.checkResult === "checking" ? ThemeBackend.mauve : ThemeBackend.red) }
                Btn { buttonText: tabRoot.t("servers.tab.change", undefined, "Изменить"); onClicked: { tabRoot.editing = tabRoot.editing === "token" ? "" : "token"; tokenField.clear(); } }
                Btn { buttonText: tabRoot.t("servers.tab.check", undefined, "Проверить"); onClicked: XServers.checkApi() }
            }
            RowLayout {
                visible: tabRoot.editing === "token"
                Layout.fillWidth: true
                Layout.leftMargin: rootObj.s(12); Layout.rightMargin: rootObj.s(12)
                spacing: rootObj.s(8)
                SecretField { id: tokenField; Layout.fillWidth: true; placeholder: tabRoot.t("servers.tab.token_ph", undefined, "Вставьте API-токен (не отображается)"); onAccepted: saveToken.clicked() }
                Btn { id: saveToken; buttonText: tabRoot.t("servers.tab.save", undefined, "Сохранить"); accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                    onClicked: { if (tokenField.text !== "") { XServers.setSecret("remnawave_token", tokenField.text); tokenField.clear(); tabRoot.editing = ""; } } }
            }
            Text {
                visible: XServers.secretResult !== "" && XServers.secretResult !== "ok"
                Layout.leftMargin: rootObj.s(14)
                text: tabRoot.t("servers.tab.secret_bad", undefined, "Не удалось сохранить: проверьте значение") + " (" + XServers.secretResult + ")"
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.red
            }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.clock
                title: tabRoot.t("servers.tab.poll", undefined, "Опрос статуса")
                description: tabRoot.t("servers.tab.poll_d", undefined, "Как часто обновлять список серверов")
                DD {
                    options: tabRoot.pollLabels
                    currentIndex: Math.max(0, tabRoot.pollKeys.indexOf(XServers.pollSeconds))
                    onSelected: (i, v) => XServers.setSetting("pollSeconds", tabRoot.pollKeys[i])
                }
            }

            // ---------------- SSH key ----------------
            SectionLabel { text: tabRoot.t("servers.tab.sec_key", undefined, "SSH-КЛЮЧ ВИДЖЕТА") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.key
                title: tabRoot.t("servers.tab.key", undefined, "Ключ")
                description: XServers.cfgInfo.key && XServers.cfgInfo.key.exists
                             ? ("ed25519  ·  " + XServers.cfgInfo.key.fingerprint + "  ·  " + tabRoot.t("servers.tab.key_forced", undefined, "только forced command"))
                             : tabRoot.t("servers.tab.key_none", undefined, "Ключ ещё не создан")
                Btn {
                    buttonText: !(XServers.cfgInfo.key && XServers.cfgInfo.key.exists) ? tabRoot.t("servers.tab.key_create", undefined, "Создать")
                               : (tabRoot.confirmNewKey ? tabRoot.t("servers.tab.key_confirm", undefined, "Точно? Серверы надо подключить заново") : tabRoot.t("servers.tab.key_regen", undefined, "Создать заново"))
                    accentColor: tabRoot.confirmNewKey ? ThemeBackend.red : ThemeBackend.surface0
                    textColor: tabRoot.confirmNewKey ? ThemeBackend.crust : ThemeBackend.text
                    onClicked: {
                        if (!(XServers.cfgInfo.key && XServers.cfgInfo.key.exists)) XServers.newKey(false);
                        else if (tabRoot.confirmNewKey) { XServers.newKey(true); tabRoot.confirmNewKey = false; }
                        else { tabRoot.confirmNewKey = true; confirmReset.restart(); }
                    }
                    Timer { id: confirmReset; interval: 4000; onTriggered: tabRoot.confirmNewKey = false }
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: String.fromCodePoint(0xF018F)
                title: tabRoot.t("servers.tab.connect", undefined, "Подключить сервер")
                description: XServers.oneLinerResult === "copied" ? tabRoot.t("servers.tab.connect_copied", undefined, "Команда скопирована: вставьте её на сервере (под root)") : tabRoot.t("servers.tab.connect_d", undefined, "Копирует команду установки ограниченного доступа")
                Btn {
                    buttonText: tabRoot.t("servers.tab.copy_cmd", undefined, "Копировать команду")
                    accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                    onClicked: XServers.copyOneLiner()
                }
            }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.server
                title: tabRoot.t("servers.tab.add_server", undefined, "Добавить сервер")
                description: tabRoot.t("servers.tab.add_server_d", undefined, "Сервер, которого нет в панели: добавьте вручную по адресу")
                Btn {
                    buttonText: tabRoot.t("servers.tab.add_server", undefined, "Добавить сервер")
                    accentColor: tabRoot.addOpen ? ThemeBackend.mauve : ThemeBackend.surface0
                    textColor: tabRoot.addOpen ? ThemeBackend.crust : ThemeBackend.text
                    onClicked: { tabRoot.addOpen = !tabRoot.addOpen; if (!tabRoot.addOpen) tabRoot.resetAdd(); }
                }
            }
            Rectangle {
                objectName: "addForm"
                visible: tabRoot.addOpen
                Layout.fillWidth: true
                Layout.leftMargin: rootObj.s(12); Layout.rightMargin: rootObj.s(12)
                implicitHeight: addCol.implicitHeight + rootObj.s(24)
                radius: rootObj.s(10)
                color: Qt.alpha(ThemeBackend.surface0, 0.5)
                border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.35)
                ColumnLayout {
                    id: addCol
                    anchors.fill: parent; anchors.margins: rootObj.s(12)
                    spacing: rootObj.s(8)
                    component Cap: Text {
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                    }
                    component Err: Text {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        visible: text !== ""
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.red
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: rootObj.s(8)
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; spacing: rootObj.s(3)
                            Cap { text: tabRoot.t("servers.tab.add_name", undefined, "Название") }
                            SecretField { id: addName; objectName: "addName"; Layout.fillWidth: true; masked: false; placeholder: "VPS Helsinki"; onAccepted: addHost.forceFocus() }
                            Err { objectName: "errName"; text: tabRoot.shown(tabRoot.nameErr(addName.text), addName.text) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignTop; spacing: rootObj.s(3)
                            Cap { text: tabRoot.t("servers.tab.add_host", undefined, "Адрес (домен или IP)") }
                            SecretField { id: addHost; objectName: "addHost"; Layout.fillWidth: true; masked: false; placeholder: "vps.example.com"; onAccepted: addPort.forceFocus() }
                            Err { objectName: "errHost"; text: tabRoot.shown(tabRoot.hostErr(addHost.text), addHost.text) }
                        }
                        ColumnLayout {
                            Layout.preferredWidth: rootObj.s(80); Layout.alignment: Qt.AlignTop; spacing: rootObj.s(3)
                            Cap { text: tabRoot.t("servers.tab.add_port", undefined, "Порт") }
                            SecretField { id: addPort; objectName: "addPort"; Layout.fillWidth: true; masked: false; placeholder: "22"; onAccepted: doAdd.clicked() }
                        }
                    }
                    Err { objectName: "errPort"; text: tabRoot.portErr(addPort.text) }
                    Text {
                        Layout.fillWidth: true
                        text: (tabRoot.addAdvanced ? "▾ " : "▸ ") + tabRoot.t("servers.tab.add_adv", undefined, "Дополнительно")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.mauve
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tabRoot.addAdvanced = !tabRoot.addAdvanced }
                    }
                    ColumnLayout {
                        visible: tabRoot.addAdvanced
                        Layout.fillWidth: true; spacing: rootObj.s(3)
                        Cap { text: tabRoot.t("servers.tab.add_user", undefined, "Пользователь serp") }
                        SecretField { id: addUser; objectName: "addUser"; Layout.preferredWidth: rootObj.s(160); masked: false; placeholder: "serp" }
                        Err { objectName: "errUser"; text: tabRoot.userErr(addUser.text) }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: rootObj.s(8)
                        Text {
                            objectName: "addStatus"
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            text: XServers.addState === "ok" ? tabRoot.t("servers.tab.added_ok", undefined, "Сервер добавлен. Доступ ещё не установлен.")
                                  : (XServers.addState !== "" ? tabRoot.addStateText(XServers.addState) : "")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                            color: XServers.addState === "ok" ? ThemeBackend.green : (XServers.addState === "running" ? ThemeBackend.mauve : ThemeBackend.red)
                        }
                        Btn {
                            objectName: "addNow"
                            visible: XServers.addState === "ok" && XServers.lastAddedId !== ""
                            buttonText: tabRoot.t("servers.tab.added_now", undefined, "Подключить сейчас")
                            accentColor: ThemeBackend.green; textColor: ThemeBackend.crust
                            onClicked: { tabRoot.enrollFor = XServers.lastAddedId; tabRoot.addOpen = false; tabRoot.resetAdd(); XServers.addState = ""; }
                        }
                        Btn {
                            buttonText: tabRoot.t("servers.tab.add_cancel", undefined, "Отмена")
                            onClicked: { tabRoot.addOpen = false; tabRoot.resetAdd(); XServers.addState = ""; }
                        }
                        Btn {
                            id: doAdd
                            objectName: "addGo"
                            buttonText: tabRoot.t("servers.tab.add_go", undefined, "Добавить")
                            accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                            onClicked: { XServers.addState = ""; tabRoot.submitAdd(); }
                        }
                    }
                }
            }

            // ---------------- own commands ----------------
            SectionLabel { text: tabRoot.t("servers.tab.sec_cmds", undefined, "СВОИ КОМАНДЫ") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: Glyphs.file
                title: tabRoot.t("servers.tab.cmd_file", undefined, "Файл команд")
                description: (XServers.cfgInfo.dir ? XServers.cfgInfo.dir.replace(/^\/home\/[^/]+/, "~") : "~/.config/serpantinum/servers") + "/commands.toml"
                Btn { buttonText: tabRoot.t("servers.tab.open_editor", undefined, "Открыть в редакторе"); onClicked: XServers.openCommandsFile() }
            }
            Repeater {
                model: XServers.cfgInfo.problems || []
                Text {
                    required property string modelData
                    Layout.fillWidth: true; Layout.leftMargin: rootObj.s(14); wrapMode: Text.WordWrap
                    text: "commands.toml: " + modelData
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.yellow
                }
            }

            // ---------------- servers ----------------
            SectionLabel { text: tabRoot.t("servers.tab.sec_servers", undefined, "СЕРВЕРЫ В ВИДЖЕТЕ") }

            Text {
                visible: XServers.servers.length === 0
                Layout.fillWidth: true; Layout.leftMargin: rootObj.s(14); wrapMode: Text.WordWrap
                text: XServers.apiError !== "" ? tabRoot.checkText(XServers.apiError) : tabRoot.t("servers.tab.no_servers", undefined, "Серверов пока нет")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
            }

            Repeater {
                model: XServers.servers
                ColumnLayout {
                    id: srvBlock
                    required property var modelData
                    readonly property var sv: modelData
                    Layout.fillWidth: true
                    spacing: rootObj.s(6)

                    SettingsRow {
                        rootObj: tabRoot.rootObj
                        icon: Glyphs.server
                        title: (srvBlock.sv.flag ? srvBlock.sv.flag + " " : "") + srvBlock.sv.name
                        description: {
                            let parts = [];
                            parts.push(srvBlock.sv.online === true ? tabRoot.t("servers.online_cap", undefined, "В сети") : (srvBlock.sv.online === false ? tabRoot.t("servers.offline_cap", undefined, "Не отвечает") : "—"));
                            if (srvBlock.sv.xrayVersion) parts.push("Xray " + srvBlock.sv.xrayVersion);
                            parts.push(XServers.sshOk(srvBlock.sv) ? tabRoot.t("servers.tab.ssh_ok", undefined, "SSH-ключ ограничен") : tabRoot.t("servers.ssh_off", undefined, "SSH не подключён"));
                            return parts.join("  ·  ");
                        }
                        Chip { visible: srvBlock.sv.manual === true; label: tabRoot.t("servers.tab.manual_badge", undefined, "свой"); tone: ThemeBackend.mauve }
                        Btn {
                            visible: srvBlock.sv.manual === true
                            buttonText: tabRoot.t("servers.tab.remove", undefined, "Удалить")
                            onClicked: { tabRoot.removeFor = tabRoot.removeFor === srvBlock.sv.id ? "" : srvBlock.sv.id; delLogin.clear(); delPw.clear(); }
                        }
                        Btn {
                            visible: !XServers.sshOk(srvBlock.sv)
                            buttonText: tabRoot.t("servers.tab.enroll", undefined, "Подключить")
                            accentColor: tabRoot.enrollFor === srvBlock.sv.id ? ThemeBackend.mauve : ThemeBackend.surface0
                            textColor: tabRoot.enrollFor === srvBlock.sv.id ? ThemeBackend.crust : ThemeBackend.text
                            onClicked: { tabRoot.enrollFor = tabRoot.enrollFor === srvBlock.sv.id ? "" : srvBlock.sv.id; loginField.clear(); pwField.clear(); portField.clear(); }
                        }
                        Btn {
                            visible: XServers.sshOk(srvBlock.sv)
                            buttonText: tabRoot.t("servers.tab.sync", undefined, "Обновить скрипты")
                            onClicked: tabRoot.enrollFor = tabRoot.enrollFor === srvBlock.sv.id ? "" : srvBlock.sv.id
                        }
                        TG { checked: !XServers.isHidden(srvBlock.sv.id); onToggled: (c) => XServers.setHidden(srvBlock.sv.id, !c) }
                    }

                    Rectangle {
                        visible: tabRoot.enrollFor === srvBlock.sv.id
                        Layout.fillWidth: true
                        Layout.leftMargin: rootObj.s(12); Layout.rightMargin: rootObj.s(12)
                        implicitHeight: enrollCol.implicitHeight + rootObj.s(24)
                        radius: rootObj.s(10)
                        color: Qt.alpha(ThemeBackend.surface0, 0.5)
                        border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.35)
                        ColumnLayout {
                            id: enrollCol
                            anchors.fill: parent; anchors.margins: rootObj.s(12)
                            spacing: rootObj.s(8)
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: tabRoot.t("servers.tab.consent_title", undefined, "Что будет установлено на сервере")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; font.weight: Font.Bold; color: ThemeBackend.text
                            }
                            Repeater {
                                model: 5
                                Text {
                                    required property int index
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    text: "•  " + tabRoot.t("servers.tab.consent_" + (index + 1), { list: tabRoot.allowedList }, "")
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: rootObj.s(8)
                                SecretField { id: loginField; Layout.preferredWidth: rootObj.s(120); masked: false; placeholder: tabRoot.t("servers.tab.login_ph", undefined, "root") }
                                SecretField { id: pwField; Layout.fillWidth: true; placeholder: tabRoot.t("servers.tab.pw_ph", undefined, "Пароль (не сохраняется)"); onAccepted: doEnroll.clicked() }
                                SecretField { id: portField; Layout.preferredWidth: rootObj.s(70); masked: false; placeholder: "22" }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: rootObj.s(8)
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    text: XServers.enrollState !== "" ? tabRoot.enrollText(XServers.enrollState) : ""
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                                    color: XServers.enrollState === "ok" ? ThemeBackend.green : (XServers.enrollState === "running" ? ThemeBackend.mauve : ThemeBackend.red)
                                }
                                Btn {
                                    id: doEnroll
                                    buttonText: tabRoot.t("servers.tab.enroll_go", undefined, "Установить доступ")
                                    accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                                    onClicked: {
                                        if (pwField.text === "") return;
                                        XServers.enroll(srvBlock.sv.id, loginField.text !== "" ? loginField.text : "root", pwField.text, "", parseInt(portField.text) || 0);
                                        pwField.clear();
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        objectName: "removePanel"
                        visible: tabRoot.removeFor === srvBlock.sv.id
                        Layout.fillWidth: true
                        Layout.leftMargin: rootObj.s(12); Layout.rightMargin: rootObj.s(12)
                        implicitHeight: delCol.implicitHeight + rootObj.s(24)
                        radius: rootObj.s(10)
                        color: Qt.alpha(ThemeBackend.surface0, 0.5)
                        border.width: 1; border.color: Qt.alpha(ThemeBackend.red, 0.45)
                        ColumnLayout {
                            id: delCol
                            anchors.fill: parent; anchors.margins: rootObj.s(12)
                            spacing: rootObj.s(8)
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: tabRoot.t("servers.tab.remove_title", undefined, "Удалить сервер из виджета?")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; font.weight: Font.Bold; color: ThemeBackend.text
                            }
                            Text {
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: tabRoot.t("servers.tab.remove_d", undefined, "Сервер исчезнет только из виджета. На самом сервере ничего не меняется.")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: rootObj.s(8)
                                Item { Layout.fillWidth: true }
                                Btn { buttonText: tabRoot.t("servers.tab.remove_cancel", undefined, "Отмена"); onClicked: tabRoot.removeFor = "" }
                                Btn {
                                    objectName: "removeWidget"
                                    buttonText: tabRoot.t("servers.tab.remove_widget", undefined, "Убрать из виджета")
                                    accentColor: ThemeBackend.red; textColor: ThemeBackend.crust
                                    onClicked: { XServers.removeServer(srvBlock.sv.id, true); tabRoot.removeFor = ""; }
                                }
                            }
                            ColumnLayout {
                                visible: XServers.sshOk(srvBlock.sv)
                                Layout.fillWidth: true; spacing: rootObj.s(6)
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    text: tabRoot.t("servers.tab.remove_both_d", undefined, "")
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.subtext0
                                }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: rootObj.s(8)
                                    SecretField { id: delLogin; Layout.preferredWidth: rootObj.s(120); masked: false; placeholder: tabRoot.t("servers.tab.login_ph", undefined, "root") }
                                    SecretField { id: delPw; Layout.fillWidth: true; placeholder: tabRoot.t("servers.tab.pw_ph", undefined, "Пароль (не сохраняется)"); onAccepted: doUninstall.clicked() }
                                    Btn {
                                        id: doUninstall
                                        objectName: "removeBoth"
                                        buttonText: tabRoot.t("servers.tab.remove_both", undefined, "Убрать и доступ с сервера")
                                        accentColor: ThemeBackend.red; textColor: ThemeBackend.crust
                                        onClicked: {
                                            if (delPw.text === "") return;
                                            XServers.enroll(srvBlock.sv.id, delLogin.text !== "" ? delLogin.text : "root", delPw.text, "", 0, true);
                                            delPw.clear();
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                                    visible: XServers.enrollState !== "" && tabRoot.removeFor === srvBlock.sv.id
                                    text: tabRoot.enrollText(XServers.enrollState)
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                                    color: XServers.enrollState === "running" ? ThemeBackend.mauve : ThemeBackend.red
                                }
                            }
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: rootObj.s(8) }
        }
    }
}
