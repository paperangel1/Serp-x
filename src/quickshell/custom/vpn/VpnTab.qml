import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../../"
import "../../reusables"
import ".."

// «VPN» settings tab: core and system service, subscription, routing and protection.
// The subscription URL is a secret: it is typed into a masked field and handed to x_vpn.sh through
// stdin (never argv/logs); the tab only ever sees a masked display form of it.
Item {
    id: tabRoot
    objectName: "vpnTab"
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

    property bool editingUrl: false
    property string urlDraft: ""
    property string urlMessage: ""
    property bool urlOk: true
    property string checkMessage: ""
    property bool checkOk: true

    onVisibleChanged: if (visible) XVpn.watch(1); else XVpn.watch(-1)

    readonly property var modeKeys: ["ru-direct", "all", "direct"]
    readonly property var modeLabels: [t("vpn.mode.ru", undefined, "Россия напрямую"), t("vpn.mode.all", undefined, "Всё через VPN"), t("vpn.mode.direct", undefined, "Всё напрямую")]
    readonly property var hourKeys: [1, 3, 6, 12, 24]
    readonly property var hourLabels: [t("vpn.tab.every_h", { n: 1 }, "каждый час"), t("vpn.tab.every_hs", { n: 3 }, "каждые 3 ч"), t("vpn.tab.every_hs", { n: 6 }, "каждые 6 ч"), t("vpn.tab.every_hs", { n: 12 }, "каждые 12 ч"), t("vpn.tab.every_hs", { n: 24 }, "каждые 24 ч")]
    readonly property var formatKeys: ["auto", "json", "links"]
    readonly property var formatLabels: [t("vpn.tab.fmt_auto", undefined, "Авто"), "Xray JSON", t("vpn.tab.fmt_links", undefined, "Ссылки")]

    readonly property var pingMethodKeys: ["httpGet", "httpHead", "tcp", "icmp"]
    readonly property var pingMethodLabels: ["HTTP GET", "HTTP HEAD", "TCP", "ICMP"]
    readonly property var pingDisplayKeys: ["digits", "bars", "barsDigits", "dots"]
    readonly property var pingDisplayLabels: [t("vpn.tab.ping_disp_digits", undefined, "Цифры"), t("vpn.tab.ping_disp_bars", undefined, "Шкала"), t("vpn.tab.ping_disp_bars_digits", undefined, "Шкала и цифры"), t("vpn.tab.ping_disp_dots", undefined, "Точки")]
    readonly property var pingPresets: [{ name: "Google", url: "https://www.gstatic.com/generate_204" }, { name: "Cloudflare", url: "https://cp.cloudflare.com/generate_204" }, { name: "Apple", url: "https://captive.apple.com/hotspot-detect.html" }]
    readonly property string pingUrlNow: XVpn.pingCfg.url || pingPresets[0].url
    function validPingUrl(u) { return /^https?:\/\/[^\s\/@]+(\/\S*)?$/.test(u) && u.length <= 512; }

    readonly property var cfg: XVpn.cfg
    function cfgv(k, d) { return cfg[k] !== undefined ? cfg[k] : d; }
    function listToText(a) { return (a && a.length) ? a.join(", ") : ""; }
    function textToList(s) {
        let out = [];
        let parts = String(s).split(/[\s,;]+/);
        for (let i = 0; i < parts.length; i++) { let p = parts[i].trim(); if (p !== "" && out.indexOf(p) < 0) out.push(p); }
        return out;
    }

    Process {
        id: setUrlProc
        stdinEnabled: true
        property string pending: ""
        onRunningChanged: if (running && pending !== "") { write(pending); pending = ""; }
        stdout: StdioCollector {
            onStreamFinished: {
                let j = null;
                try { j = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("vpn", "VpnTab.qml: could not parse JSON output (j)"); j = null; }
                tabRoot.urlOk = !!(j && j.ok !== false);
                tabRoot.urlMessage = tabRoot.urlOk ? tabRoot.t("vpn.tab.url_saved", undefined, "Подписка сохранена и загружена")
                                                   : tabRoot.t("vpn.error." + (j && j.error ? j.error : "unknown"), undefined, (j && j.error) ? j.error : "Не удалось загрузить подписку");
                if (tabRoot.urlOk) { tabRoot.editingUrl = false; tabRoot.urlDraft = ""; }
                XVpn.poll();
            }
        }
    }
    Process {
        id: checkProc
        command: ["bash", XVpn.script, "validate"]
        stdout: StdioCollector {
            onStreamFinished: {
                let j = null;
                try { j = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("vpn", "VpnTab.qml: could not parse JSON output (j)"); j = null; }
                tabRoot.checkOk = !!(j && j.ok);
                tabRoot.checkMessage = tabRoot.checkOk ? tabRoot.t("vpn.tab.check_ok", undefined, "Конфиг проходит проверку Xray")
                                                       : tabRoot.t("vpn.tab.check_fail", undefined, "Конфиг не прошёл проверку") + (j && j.message ? ": " + String(j.message).substring(0, 90) : "");
            }
        }
    }
    function saveUrl() {
        if (tabRoot.urlDraft.trim() === "") return;
        if (XVpn.fake) { tabRoot.urlOk = true; tabRoot.urlMessage = "(fake) saved"; tabRoot.editingUrl = false; tabRoot.urlDraft = ""; return; }
        tabRoot.urlMessage = tabRoot.t("vpn.tab.url_loading", undefined, "Загружаю подписку…");
        tabRoot.urlOk = true;
        setUrlProc.command = ["bash", XVpn.script, "set-subscription"];
        setUrlProc.pending = tabRoot.urlDraft.trim() + "\n";
        setUrlProc.running = true;
    }

    component SectionLabel: Text {
        Layout.fillWidth: true
        Layout.topMargin: rootObj.s(4)
        Layout.leftMargin: rootObj.s(4)
        font.family: ThemeBackend.fontFamily
        font.pixelSize: XUi.font(10)
        font.weight: Font.Bold
        font.letterSpacing: 1.5
        color: ThemeBackend.mauve
    }
    component DD: Dropdown {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: rootObj.s(170)
        implicitHeight: rootObj.s(34)
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface0
        hoverColor: ThemeBackend.surface1
        dropdownColor: ThemeBackend.surface0
        borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
        textColor: ThemeBackend.text
        activeTextColor: ThemeBackend.crust
    }
    component TG: Toggle {
        Layout.alignment: Qt.AlignVCenter
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface1
        handleColor: ThemeBackend.crust
        handleOffColor: ThemeBackend.text
    }
    component SmallBtn: ClickButton {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredHeight: rootObj.s(32)
        cornerRadius: ThemeBackend.borderRadius
        horizontalPadding: rootObj.s(14)
        textFontSize: rootObj.s(11)
        iconFontSize: rootObj.s(13)
        accentColor: ThemeBackend.surface0
        textColor: ThemeBackend.text
    }
    component Badge: Rectangle {
        property string text: ""
        property color tone: ThemeBackend.green
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: bt.implicitWidth + rootObj.s(14); implicitHeight: rootObj.s(18); radius: rootObj.s(4)
        color: Qt.alpha(tone, 0.16)
        Text { id: bt; anchors.centerIn: parent; text: parent.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: parent.tone }
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

            // ---------------- Happ conflict ----------------
            Rectangle {
                Layout.fillWidth: true
                visible: XVpn.happActive
                implicitHeight: happText.implicitHeight + rootObj.s(20) + rootObj.s(38)
                radius: ThemeBackend.borderRadius
                color: Qt.alpha(ThemeBackend.peach, 0.12)
                border.width: 1; border.color: Qt.alpha(ThemeBackend.peach, 0.5)
                Text {
                    id: happText
                    x: rootObj.s(14); y: rootObj.s(10); width: parent.width - rootObj.s(28)
                    wrapMode: Text.Wrap
                    text: tabRoot.t("vpn.warn.happ_long", undefined, "Включён VPN в приложении Happ. Отключите VPN в приложении Happ, затем нажмите «Проверить снова».")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(11); color: ThemeBackend.peach
                }
                SmallBtn {
                    x: rootObj.s(14); y: happText.y + happText.implicitHeight + rootObj.s(8)
                    buttonText: tabRoot.t("vpn.popup.recheck", undefined, "Проверить снова")
                    onClicked: XVpn.recheck()
                }
            }

            // ---------------- core and service ----------------
            SectionLabel { text: tabRoot.t("vpn.tab.sec_core", undefined, "ЯДРО И СЛУЖБА") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰒓"
                title: tabRoot.t("vpn.tab.core", undefined, "Ядро Xray")
                description: XVpn.core.exists
                    ? tabRoot.t("vpn.tab.core_d", { v: XVpn.core.version || "?", p: XVpn.core.path || "", g: XVpn.geoDate },
                                "Версия " + (XVpn.core.version || "?") + " · " + (XVpn.core.path || "") + " · гео-базы " + (XVpn.geoDate))
                    : tabRoot.t("vpn.tab.core_missing", undefined, "Ядро не найдено: установите пакет xray")
                SmallBtn {
                    buttonText: tabRoot.t("vpn.tab.check", undefined, "Проверить")
                    onClicked: { if (XVpn.fake) { tabRoot.checkOk = true; tabRoot.checkMessage = "(fake) ok"; } else checkProc.running = true; }
                }
            }
            Text {
                visible: tabRoot.checkMessage !== ""
                Layout.leftMargin: rootObj.s(8)
                text: tabRoot.checkMessage
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10)
                color: tabRoot.checkOk ? ThemeBackend.green : ThemeBackend.red
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰒋"
                title: tabRoot.t("vpn.tab.service", undefined, "Системная служба")
                description: !XVpn.service.installed ? tabRoot.t("vpn.tab.service_none", undefined, "Не установлена: нужна один раз, с правами администратора")
                             : tabRoot.t("vpn.tab.service_d", { u: XVpn.service.unit || "serp-xray.service", p: XVpn.service.polkit === null ? tabRoot.t("vpn.tab.polkit_unknown", undefined, "не удалось проверить правило polkit (каталог недоступен пользователю)")
                                                  : XVpn.service.polkit ? tabRoot.t("vpn.tab.polkit_ok", undefined, "правило polkit установлено") : tabRoot.t("vpn.tab.polkit_no", undefined, "правила polkit нет") },
                                         (XVpn.service.unit || "serp-xray.service") + " · " + (XVpn.service.polkit === null ? "не удалось проверить правило polkit" : XVpn.service.polkit ? "правило polkit установлено" : "правила polkit нет"))
                Badge {
                    visible: !!XVpn.service.installed
                    text: XVpn.service.active ? tabRoot.t("vpn.tab.active", undefined, "активна") : tabRoot.t("vpn.tab.stopped", undefined, "остановлена")
                    tone: XVpn.service.active ? ThemeBackend.green : ThemeBackend.subtext0
                }
                SmallBtn {
                    buttonText: tabRoot.t("vpn.tab.howto", undefined, "Как установить")
                    onClicked: {
                        if (!XVpn.fake) Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy; notify-send -a Serpantinum \"VPN\" \"Команда скопирована: вставьте её в терминал\"", "_",
                                                                  "XVPN_ALLOW_ROOT_INSTALL=1 bash " + XVpn.script + " install --apply"]);
                    }
                }
            }

            // ---------------- subscription ----------------
            SectionLabel { text: tabRoot.t("vpn.tab.sec_sub", undefined, "ПОДПИСКА") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰌷"
                title: tabRoot.t("vpn.tab.url", undefined, "Ссылка подписки")
                description: XVpn.subscription.configured ? ((XVpn.subscription.display || "") + (XVpn.subInfo.length > 0 ? "  ·  " + XVpn.subInfo.join("  ·  ") : "")) : tabRoot.t("vpn.tab.url_none", undefined, "Не задана")
                SmallBtn {
                    buttonText: tabRoot.editingUrl ? tabRoot.t("vpn.tab.cancel", undefined, "Отмена") : tabRoot.t("vpn.tab.change", undefined, "Изменить")
                    onClicked: { tabRoot.editingUrl = !tabRoot.editingUrl; tabRoot.urlDraft = ""; tabRoot.urlMessage = ""; }
                }
            }
            RowLayout {
                visible: tabRoot.editingUrl
                Layout.fillWidth: true
                spacing: rootObj.s(8)
                Input {
                    Layout.fillWidth: true
                    implicitHeight: rootObj.s(36)
                    masked: true
                    text: tabRoot.urlDraft
                    leadingIcon: "󰌋"
                    placeholderText: tabRoot.t("vpn.tab.url_placeholder", undefined, "Вставьте ссылку подписки (хранится только в файле с правами 600)")
                    baseColor: ThemeBackend.surface0
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.text
                    subTextColor: ThemeBackend.subtext0
                    borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                    cornerRadius: ThemeBackend.borderRadius
                    onTextEdited: function(tt) { tabRoot.urlDraft = tt; }
                    onAccepted: function(tt) { tabRoot.urlDraft = tt; tabRoot.saveUrl(); }
                }
                SmallBtn {
                    buttonText: tabRoot.t("vpn.tab.save", undefined, "Сохранить")
                    accentColor: ThemeBackend.mauve; textColor: ThemeBackend.crust
                    enabled: tabRoot.urlDraft.trim() !== ""
                    onClicked: tabRoot.saveUrl()
                }
            }
            Text {
                visible: tabRoot.urlMessage !== ""
                Layout.leftMargin: rootObj.s(8)
                text: tabRoot.urlMessage
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10)
                color: tabRoot.urlOk ? ThemeBackend.subtext0 : ThemeBackend.red
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰑐"
                title: tabRoot.t("vpn.tab.auto", undefined, "Автообновление")
                description: tabRoot.t("vpn.tab.auto_d", { ago: XVpn.ago(XVpn.subscription.updated) || "—", n: XVpn.subscription.count || 0 },
                                       "Последнее обновление: " + (XVpn.ago(XVpn.subscription.updated) || "—") + " · узлов: " + (XVpn.subscription.count || 0))
                SmallBtn { buttonText: tabRoot.t("vpn.tab.refresh", undefined, "Обновить"); onClicked: XVpn.refreshSubscription() }
                DD {
                    implicitWidth: rootObj.s(150)
                    options: tabRoot.hourLabels
                    currentIndex: Math.max(0, tabRoot.hourKeys.indexOf(tabRoot.cfgv("updateHours", 6)))
                    onSelected: (i, v) => XVpn.setSetting("updateHours", tabRoot.hourKeys[i])
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰋊"
                title: tabRoot.t("vpn.tab.traffic", undefined, "Трафик")
                visible: XVpn.trafficTotal > 0
                description: tabRoot.t("vpn.tab.traffic_d", { used: XVpn.fmtGb(XVpn.trafficUsed), total: XVpn.fmtGb(XVpn.trafficTotal) },
                                       XVpn.fmtGb(XVpn.trafficUsed) + " из " + XVpn.fmtGb(XVpn.trafficTotal) + " ГБ")
                             + (XVpn.trafficExpire > 0 ? " · " + tabRoot.t("vpn.tab.expires", { d: XVpn.fmtDateFull(XVpn.trafficExpire) }, "действует до " + XVpn.fmtDateFull(XVpn.trafficExpire)) : "")
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(150); implicitHeight: rootObj.s(6); radius: height / 2
                    color: ThemeBackend.surface1
                    Rectangle {
                        height: parent.height; radius: height / 2; color: ThemeBackend.mauve
                        width: XVpn.trafficTotal > 0 ? parent.width * Math.min(1, XVpn.trafficUsed / XVpn.trafficTotal) : 0
                    }
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰈙"
                title: tabRoot.t("vpn.tab.format", undefined, "Формат конфигурации")
                description: tabRoot.t("vpn.tab.format_d", undefined, "Xray JSON, если панель отдаёт; иначе — разбор ссылок")
                DD {
                    implicitWidth: rootObj.s(130)
                    options: tabRoot.formatLabels
                    currentIndex: Math.max(0, tabRoot.formatKeys.indexOf(tabRoot.cfgv("format", "auto")))
                    onSelected: (i, v) => XVpn.setSetting("format", tabRoot.formatKeys[i])
                }
            }

            // ---------------- routing and protection ----------------
            SectionLabel { text: tabRoot.t("vpn.tab.sec_route", undefined, "МАРШРУТИЗАЦИЯ И ЗАЩИТА") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰀄"
                title: tabRoot.t("vpn.tab.mode", undefined, "Режим")
                description: tabRoot.t("vpn.tab.mode_d", undefined, "Какой трафик идёт через VPN")
                DD {
                    implicitWidth: rootObj.s(190)
                    options: tabRoot.modeLabels
                    currentIndex: Math.max(0, tabRoot.modeKeys.indexOf(XVpn.mode))
                    onSelected: (i, v) => XVpn.setSetting("mode", tabRoot.modeKeys[i])
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰒃"
                title: tabRoot.t("vpn.tab.kill", undefined, "Kill-switch")
                description: tabRoot.t("vpn.tab.kill_d", undefined, "Без VPN интернет блокируется, а не утекает")
                TG { checked: XVpn.killSwitch; onToggled: (c) => XVpn.setSetting("killSwitch", c) }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰇘"
                title: tabRoot.t("vpn.tab.ipv6", undefined, "Блокировать IPv6")
                description: tabRoot.t("vpn.tab.ipv6_d", undefined, "Защита от утечек по IPv6")
                TG { checked: XVpn.blockIPv6; onToggled: (c) => XVpn.setSetting("blockIPv6", c) }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰓛"
                title: tabRoot.t("vpn.tab.autodisable", undefined, "Автоотключение при сбое")
                description: tabRoot.t("vpn.tab.autodisable_d", { n: tabRoot.cfgv("autoDisableSeconds", 20) }, "Нет связи " + tabRoot.cfgv("autoDisableSeconds", 20) + " с — маршруты снимаются, интернет возвращается")
                NumberSelector {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(112); implicitHeight: rootObj.s(32)
                    from: 10; to: 120; stepSize: 5
                    value: tabRoot.cfgv("autoDisableSeconds", 20)
                    suffix: " " + tabRoot.t("vpn.units.s", undefined, "с")
                    baseColor: ThemeBackend.surface0; accentColor: ThemeBackend.mauve
                    buttonColor: ThemeBackend.surface1; buttonTextColor: ThemeBackend.text
                    enabled: XVpn.autoDisable
                    onTriggered: XVpn.setSetting("autoDisableSeconds", Math.round(value))
                }
                TG { checked: XVpn.autoDisable; onToggled: (c) => XVpn.setSetting("autoDisable", c) }
            }

            // ---------------- ping ----------------
            SectionLabel { text: tabRoot.t("vpn.tab.sec_ping", undefined, "ПИНГ") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰓅"
                title: tabRoot.t("vpn.tab.ping_method", undefined, "Метод пинга")
                description: tabRoot.t("vpn.tab.ping_method_d", undefined, "HTTP GET и HEAD идут через сам узел и работают для любых протоколов, включая UDP")
                DD {
                    implicitWidth: rootObj.s(150)
                    options: tabRoot.pingMethodLabels
                    currentIndex: Math.max(0, tabRoot.pingMethodKeys.indexOf(XVpn.pingMethod))
                    onSelected: (i, v) => XVpn.setSetting("pingMethod", tabRoot.pingMethodKeys[i])
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰖟"
                title: tabRoot.t("vpn.tab.ping_url", undefined, "Адрес проверки")
                description: tabRoot.t("vpn.tab.ping_url_d", undefined, "Любой http(s)-адрес, отвечающий кодом 2xx")
                visible: XVpn.pingMethod === "httpGet" || XVpn.pingMethod === "httpHead"
                Repeater {
                    model: tabRoot.pingPresets
                    SmallBtn {
                        required property var modelData
                        buttonText: modelData.name
                        accentColor: tabRoot.pingUrlNow === modelData.url ? ThemeBackend.mauve : ThemeBackend.surface0
                        textColor: tabRoot.pingUrlNow === modelData.url ? ThemeBackend.crust : ThemeBackend.text
                        onClicked: XVpn.setSetting("pingUrl", modelData.url)
                    }
                }
                Input {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(240); implicitHeight: rootObj.s(34)
                    text: tabRoot.pingUrlNow
                    placeholderText: "https://www.gstatic.com/generate_204"
                    baseColor: ThemeBackend.surface0; accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.text; subTextColor: ThemeBackend.subtext0
                    borderColor: Qt.alpha(ThemeBackend.surface2, 0.6); cornerRadius: ThemeBackend.borderRadius
                    onAccepted: function(tt) { if (tabRoot.validPingUrl(tt.trim())) XVpn.setSetting("pingUrl", tt.trim()); }
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󱎫"
                title: tabRoot.t("vpn.tab.ping_timeout", undefined, "Таймаут пинга")
                description: tabRoot.t("vpn.tab.ping_timeout_d", undefined, "Сколько секунд ждать ответ узла")
                NumberSelector {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(112); implicitHeight: rootObj.s(32)
                    from: 1; to: 10; stepSize: 1
                    value: XVpn.pingCfg.timeout || 3
                    suffix: " " + tabRoot.t("vpn.units.s", undefined, "с")
                    baseColor: ThemeBackend.surface0; accentColor: ThemeBackend.mauve
                    buttonColor: ThemeBackend.surface1; buttonTextColor: ThemeBackend.text
                    onTriggered: XVpn.setSetting("pingTimeout", Math.round(value))
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰢾"
                title: tabRoot.t("vpn.tab.ping_display", undefined, "Вид пинга")
                description: tabRoot.t("vpn.tab.ping_display_d", undefined, "Как показывать задержку в списке узлов")
                DD {
                    implicitWidth: rootObj.s(170)
                    options: tabRoot.pingDisplayLabels
                    currentIndex: Math.max(0, tabRoot.pingDisplayKeys.indexOf(XVpn.pingDisplay))
                    onSelected: (i, v) => XVpn.setSetting("pingDisplay", tabRoot.pingDisplayKeys[i])
                }
            }

            // ---------------- domain lists ----------------
            SectionLabel { text: tabRoot.t("vpn.tab.sec_lists", undefined, "СПИСКИ ДОМЕНОВ") }

            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰊠"
                title: tabRoot.t("vpn.tab.geo", undefined, "Гео-базы России")
                description: (XVpn.geo && XVpn.geo.present)
                    ? tabRoot.t("vpn.tab.geo_ok", { d: XVpn.geoDate }, "Списки на месте, обновлены " + XVpn.geoDate)
                    : tabRoot.t("vpn.tab.geo_none", undefined, "Нет: режим «Россия напрямую» работает только по доменам .ru/.рф/.su")
                SmallBtn {
                    buttonText: tabRoot.t("vpn.tab.refresh", undefined, "Обновить")
                    onClicked: { if (!XVpn.fake) Quickshell.execDetached(["bash", XVpn.script, "geo-update"]); }
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰁔"
                title: tabRoot.t("vpn.tab.bypass", undefined, "Всегда напрямую")
                description: tabRoot.t("vpn.tab.bypass_d", undefined, "Домены через запятую: bank.example, domain:corp.local")
                Input {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(280); implicitHeight: rootObj.s(34)
                    text: tabRoot.listToText(tabRoot.cfgv("bypassDomains", []))
                    placeholderText: "example.com, domain:corp.local"
                    baseColor: ThemeBackend.surface0; accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.text; subTextColor: ThemeBackend.subtext0
                    borderColor: Qt.alpha(ThemeBackend.surface2, 0.6); cornerRadius: ThemeBackend.borderRadius
                    onAccepted: function(tt) { XVpn.setSetting("bypassDomains", tabRoot.textToList(tt)); }
                }
            }
            SettingsRow {
                rootObj: tabRoot.rootObj
                icon: "󰖂"
                title: tabRoot.t("vpn.tab.proxy", undefined, "Всегда через VPN")
                description: tabRoot.t("vpn.tab.proxy_d", undefined, "Домены через запятую, имеют приоритет над «Россия напрямую»")
                Input {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: rootObj.s(280); implicitHeight: rootObj.s(34)
                    text: tabRoot.listToText(tabRoot.cfgv("proxyDomains", []))
                    placeholderText: "example.com, full:api.example.com"
                    baseColor: ThemeBackend.surface0; accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.text; subTextColor: ThemeBackend.subtext0
                    borderColor: Qt.alpha(ThemeBackend.surface2, 0.6); cornerRadius: ThemeBackend.borderRadius
                    onAccepted: function(tt) { XVpn.setSetting("proxyDomains", tabRoot.textToList(tt)); }
                }
            }

            Item { Layout.preferredHeight: rootObj.s(6) }
        }
    }
}
