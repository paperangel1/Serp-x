import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../../"
import "../../reusables"
import ".."

// VPN popup (see VpnPopup.qml for the layer-shell window around it): status, live speed, routing mode,
// kill-switch, node list with ping/speed (one click switches the node), subscription refresh.
Item {
    id: root

    property bool open: false
    property bool inline: false          // true: no click-catcher, panel pinned at (0,0) (offscreen renders)
    property var dlHist: []
    property var ulHist: []
    readonly property real panelOpacity: panel.opacity

    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }
    function hide() { XVpn.popupOpen = false; }

    readonly property var modeKeys: ["ru-direct", "all", "direct"]
    readonly property var modeLabels: [t("vpn.mode.ru", undefined, "Россия напрямую"), t("vpn.mode.all", undefined, "Всё через VPN"), t("vpn.mode.direct", undefined, "Всё напрямую")]

    readonly property string stateText: {
        switch (XVpn.vstate) {
        case "on": return t("vpn.state.on", undefined, "подключено");
        case "starting":
            if (XVpn.phase === "resolving") return t("vpn.state.resolving", undefined, "разрешаю адрес сервера…");
            if (XVpn.phase === "checking") return t("vpn.state.checking", undefined, "проверяю связь…");
            return t("vpn.state.starting", undefined, "подключение…");
        case "switching": return t("vpn.state.switching", undefined, "смена узла…");
        case "failed": return t("vpn.state.failed", undefined, "нет связи");
        default: return t("vpn.state.off", undefined, "выключено");
        }
    }
    readonly property color stateColor: XVpn.vstate === "on" ? ThemeBackend.green : XVpn.vstate === "failed" ? ThemeBackend.red : (XVpn.transitional ? ThemeBackend.yellow : ThemeBackend.subtext0)
    readonly property string subtitle: {
        let parts = [];
        if (XVpn.node) parts.push(XVpn.displayName(XVpn.node));
        if (XVpn.connected && XVpn.since > 0) parts.push(XVpn.fmtUptime(XVpn.nowMs / 1000 - XVpn.since));
        parts.push(t("vpn.popup.mode_short", { mode: XVpn.modeLabel }, "режим «" + XVpn.modeLabel + "»"));
        return parts.join("  ·  ");
    }
    readonly property string degradedText: {
        let d = XVpn.degraded;
        if (d.indexOf("happ_active") >= 0) return t("vpn.warn.happ", undefined, "Активен Happ: выключите его, Serpantinum VPN не включится одновременно");
        if (d.indexOf("service_missing") >= 0) return t("vpn.warn.service", undefined, "Системная служба не установлена: см. вкладку «VPN»");
        if (d.indexOf("polkit_missing") >= 0) return t("vpn.warn.polkit", undefined, "Нет polkit-правила службы: см. вкладку «VPN»");
        if (d.indexOf("xray_missing") >= 0) return t("vpn.warn.xray", undefined, "Ядро Xray не найдено");
        if (d.indexOf("tun_unsupported") >= 0) return t("vpn.warn.tun", undefined, "Эта сборка Xray без TUN");
        if (XVpn.vstate === "failed" && XVpn.reason !== "") return t("vpn.reason." + XVpn.reason, { name: XVpn.reasonNode }, XVpn.reason);
        if (XVpn.lastError !== "") return t("vpn.error." + XVpn.lastError, undefined, XVpn.lastError);
        return "";
    }

    // pingState: ok | timeout | error | na (this method cannot measure the node) | measuring | none (not measured yet)
    function pingOk(n) { return n.pingState === "ok" && n.pingMs !== null && n.pingMs !== undefined; }
    function pingColor(n) {
        let st = n.pingState || "none";
        if (st === "timeout" || st === "error") return ThemeBackend.red;
        if (!pingOk(n)) return ThemeBackend.subtext0;
        let ms = n.pingMs;
        return ms < 80 ? ThemeBackend.green : ms < 160 ? ThemeBackend.yellow : ms <= 400 ? ThemeBackend.peach : ThemeBackend.red;
    }
    // signal-strength glyph: <80 ms 4 bars ... >400 ms 1 bar (red)
    function pingBars(n) {
        let ms = n.pingMs, lv = ms < 80 ? 4 : ms < 160 ? 3 : ms < 300 ? 2 : 1;
        let g = ["▂", "▄", "▆", "█"];
        return "<font color=\"" + pingColor(n) + "\">" + g.slice(0, lv).join("") + "</font><font color=\"" + ThemeBackend.surface2 + "\">" + g.slice(lv).join("") + "</font>";
    }
    function pingText(n) {
        let st = n.pingState || "none", d = XVpn.pingDisplay;
        if (d === "dots") return "●";
        if (st === "na") return t("vpn.popup.na", undefined, "н/д");
        if (st === "timeout") return t("vpn.popup.timeout", undefined, "таймаут");
        if (st === "error") return t("vpn.popup.error", undefined, "ошибка");
        if (st === "measuring") return t("vpn.popup.pinging", undefined, "измеряю…");
        if (!pingOk(n)) return XVpn.measuring ? t("vpn.popup.pinging", undefined, "измеряю…") : t("vpn.popup.unmeasured", undefined, "не измерено");
        let digits = Math.round(n.pingMs) + " " + t("vpn.units.ms", undefined, "мс");
        return d === "bars" ? pingBars(n) : d === "barsDigits" ? pingBars(n) + " " + digits : digits;
    }
    function pingDotColor(n) { return pingOk(n) ? ThemeBackend.green : ThemeBackend.overlay0; }
    function nodeHint(n) {
        let h = [], tg = n.tags || [];
        if (tg.indexOf("lte") >= 0) h.push(t("vpn.popup.tag_lte", undefined, "только LTE"));
        if (tg.indexOf("auto") >= 0) h.push(t("vpn.popup.tag_auto", undefined, "авто-выбор"));
        if (n.pingState === "na") h.push(t("vpn.popup.na_hint", undefined, "н/д: выберите HTTP-метод"));
        return h.join(" · ");
    }
    readonly property string selectionText: (XVpn.selection === "" || XVpn.selection === "user" || !XVpn.node) ? ""
        : t("vpn.popup.sel_" + XVpn.selection, undefined, t("vpn.popup.sel_auto", undefined, "Выбран автоматически"))
    function speedText(n) {
        return (n.speedMbps === null || n.speedMbps === undefined) ? "—" : Math.round(n.speedMbps) + " " + t("vpn.units.mbit", undefined, "Мбит/с");
    }
    readonly property int pingAgeMin: {
        let best = -1;
        for (let i = 0; i < XVpn.nodes.length; i++) { let a = XVpn.nodes[i].pingAge; if (a !== null && a !== undefined && (best < 0 || a < best)) best = a; }
        return best;
    }

    function pushHist(arr, v) { let a = arr.slice(); a.push(v); if (a.length > 18) a.shift(); return a; }
    Timer {
        interval: 1000; repeat: true
        running: root.open && XVpn.connected
        onTriggered: { root.dlHist = root.pushHist(root.dlHist, XVpn.speedDown); root.ulHist = root.pushHist(root.ulHist, XVpn.speedUp); }
    }
    onOpenChanged: if (open) { XVpn.watch(1); XVpn.poll(); XVpn.measure(); } else XVpn.watch(-1)

    component TG: Toggle {
        Layout.alignment: Qt.AlignVCenter
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface1
        handleColor: ThemeBackend.crust
        handleOffColor: ThemeBackend.text
    }

    component StatCard: Rectangle {
        id: card
        property string label: ""
        property string value: ""
        property string unit: ""
        property var hist: []
        property color barColor: ThemeBackend.mauve
        readonly property real mx: { let m = 1; for (let i = 0; i < hist.length; i++) m = Math.max(m, hist[i]); return m; }
        radius: ThemeBackend.borderRadius
        color: Qt.alpha(ThemeBackend.surface0, 0.5)
        implicitHeight: s(60)
        Column {
            x: s(12); y: s(9); spacing: s(3)
            Text { text: card.label; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0 }
            Row {
                spacing: s(4)
                Text { text: card.value; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(20); font.weight: Font.Bold; color: ThemeBackend.text }
                Text { anchors.baseline: parent.children[0].baseline; text: card.unit; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0 }
            }
        }
        Row {
            anchors.right: parent.right; anchors.rightMargin: s(12)
            anchors.bottom: parent.bottom; anchors.bottomMargin: s(12)
            spacing: s(2)
            height: s(34)
            Repeater {
                model: 18
                Rectangle {
                    readonly property int hi: card.hist.length - 18 + index
                    readonly property real v: hi >= 0 ? card.hist[hi] : 0
                    anchors.bottom: parent.bottom
                    width: s(3); radius: 1
                    height: Math.max(s(2), (v / card.mx) * s(34))
                    color: Qt.alpha(card.barColor, hi >= 0 ? 0.35 + 0.65 * (index / 18) : 0.12)
                }
            }
        }
    }

    component InfoRow: Rectangle {
        id: ir
        property string icon: ""
        property string title: ""
        property string desc: ""
        default property alias trailing: trail.data
        radius: ThemeBackend.borderRadius
        color: "transparent"
        implicitHeight: s(44)
        Layout.fillWidth: true
        Rectangle {
            id: ib
            x: 0; anchors.verticalCenter: parent.verticalCenter
            width: s(32); height: s(32); radius: ThemeBackend.borderRadius
            color: Qt.alpha(ThemeBackend.surface0, 0.7)
            Text { anchors.centerIn: parent; text: ir.icon; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.font(15); color: ThemeBackend.subtext1 }
        }
        Column {
            anchors.left: ib.right; anchors.leftMargin: s(10)
            anchors.right: trail.left; anchors.rightMargin: s(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: s(2)
            Text { width: parent.width; text: ir.title; elide: Text.ElideRight; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(11); font.weight: Font.DemiBold; color: ThemeBackend.text }
            Text { width: parent.width; text: ir.desc; elide: Text.ElideRight; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0 }
        }
        RowLayout { id: trail; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: s(8) }
    }

    Item {
        anchors.fill: parent
        focus: root.open
        Keys.onPressed: (e) => { if (e.key === Qt.Key_Escape) { root.hide(); e.accepted = true; } }

        MouseArea { anchors.fill: parent; enabled: !root.inline; onClicked: root.hide() }

        Rectangle {
            id: panel
            readonly property real w: s(440)
            width: w
            height: content.implicitHeight + s(32)
            x: root.inline ? 0 : Math.max(s(10), Math.min(parent.width - width - s(10), (XVpn.anchorX >= 0 ? XVpn.anchorX - width / 2 : parent.width - width - s(14))))
            y: root.inline ? 0 : ((XVpn.anchorY >= 0 ? XVpn.anchorY : s(46)) + s(8))
            radius: ThemeBackend.borderRadius + s(4)
            color: ThemeBackend.crust
            border.width: 1
            border.color: Qt.alpha(ThemeBackend.surface1, 0.8)
            opacity: (root.open || root.inline) ? 1 : 0
            scale: (root.open || root.inline) ? 1 : 0.97
            transformOrigin: Item.Top
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: content
                x: s(16); y: s(16)
                width: parent.width - s(32)
                spacing: s(10)

                // header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: s(12)
                    Rectangle {
                        Layout.preferredWidth: s(40); Layout.preferredHeight: s(40)
                        radius: ThemeBackend.borderRadius
                        color: XVpn.connected ? Qt.alpha(ThemeBackend.mauve, 0.22) : ThemeBackend.surface0
                        Text { anchors.centerIn: parent; text: "󰖂"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.font(20); color: XVpn.connected ? ThemeBackend.mauve : ThemeBackend.subtext1 }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: s(3)
                        RowLayout {
                            spacing: s(8)
                            Text { text: "VPN"; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(15); font.weight: Font.Bold; color: ThemeBackend.text }
                            Rectangle {
                                implicitWidth: badge.implicitWidth + s(12); implicitHeight: s(16); radius: s(4)
                                color: Qt.alpha(root.stateColor, 0.18)
                                Text { id: badge; anchors.centerIn: parent; text: root.stateText; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: root.stateColor }
                            }
                        }
                        Text { Layout.fillWidth: true; text: root.subtitle; elide: Text.ElideRight; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0 }
                    }
                    TG { checked: XVpn.connected || XVpn.transitional; enabled: !XVpn.busy; onToggled: (c) => XVpn.toggle() }
                }

                // warning / error line
                Rectangle {
                    Layout.fillWidth: true
                    visible: root.degradedText !== ""
                    implicitHeight: warnText.implicitHeight + s(14) + (XVpn.happActive ? s(40) : 0)
                    radius: ThemeBackend.borderRadius
                    color: Qt.alpha(ThemeBackend.peach, 0.12)
                    border.width: 1; border.color: Qt.alpha(ThemeBackend.peach, 0.5)
                    Text { id: warnText; x: s(10); y: s(7); width: parent.width - s(20); text: root.degradedText; wrapMode: Text.Wrap; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10); color: ThemeBackend.peach }
                    ClickButton {
                        visible: XVpn.happActive
                        x: s(10); y: warnText.y + warnText.implicitHeight + s(6)
                        height: s(28)
                        buttonIcon: "󰑐"
                        buttonText: root.t("vpn.popup.recheck", undefined, "Проверить снова")
                        iconFontSize: s(12); textFontSize: s(10)
                        cornerRadius: ThemeBackend.borderRadius
                        horizontalPadding: s(10)
                        accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                        onClicked: XVpn.recheck()
                    }
                }

                // speed
                RowLayout {
                    Layout.fillWidth: true
                    spacing: s(8)
                    StatCard {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        label: root.t("vpn.popup.download", undefined, "Скачивание")
                        value: XVpn.fmtRate(XVpn.speedDown).split(" ")[0]; unit: XVpn.fmtRate(XVpn.speedDown).split(" ").slice(1).join(" ")
                        hist: root.dlHist; barColor: ThemeBackend.mauve
                    }
                    StatCard {
                        Layout.fillWidth: true; Layout.preferredWidth: 1
                        label: root.t("vpn.popup.upload", undefined, "Отдача")
                        value: XVpn.fmtRate(XVpn.speedUp).split(" ")[0]; unit: XVpn.fmtRate(XVpn.speedUp).split(" ").slice(1).join(" ")
                        hist: root.ulHist; barColor: ThemeBackend.pink
                    }
                }

                InfoRow {
                    icon: "󰀄"
                    title: root.t("vpn.popup.mode", undefined, "Режим маршрутизации")
                    desc: XVpn.mode === "ru-direct" ? root.t("vpn.popup.mode_ru_d", undefined, "Россия напрямую, остальное через VPN")
                          : XVpn.mode === "all" ? root.t("vpn.popup.mode_all_d", undefined, "Весь трафик через VPN")
                          : root.t("vpn.popup.mode_direct_d", undefined, "VPN не используется для сайтов")
                    Dropdown {
                        implicitWidth: s(158); implicitHeight: s(30)
                        fontPixelSize: s(10)
                        accentColor: ThemeBackend.mauve; baseColor: ThemeBackend.surface0; hoverColor: ThemeBackend.surface1
                        dropdownColor: ThemeBackend.surface0; borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                        textColor: ThemeBackend.text; activeTextColor: ThemeBackend.crust
                        options: root.modeLabels
                        currentIndex: Math.max(0, root.modeKeys.indexOf(XVpn.mode))
                        onSelected: (i, v) => XVpn.setSetting("mode", root.modeKeys[i])
                    }
                }
                InfoRow {
                    icon: "󰒃"
                    title: root.t("vpn.popup.kill", undefined, "Блокировать трафик без VPN")
                    desc: root.t("vpn.popup.kill_d", undefined, "Kill-switch: при обрыве интернет не утекает")
                    TG { checked: XVpn.killSwitch; onToggled: (c) => XVpn.setSetting("killSwitch", c) }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(ThemeBackend.surface1, 0.5) }

                // nodes
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: root.t("vpn.popup.nodes", undefined, "УЗЛЫ"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); font.weight: Font.Bold; font.letterSpacing: 1.5; color: ThemeBackend.mauve }
                    Text { text: String(XVpn.nodes.length); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0 }
                    Item { Layout.fillWidth: true }
                    Text {
                        visible: root.pingAgeMin >= 0
                        text: root.t("vpn.popup.ping_age", { n: root.pingAgeMin }, "пинг: " + root.pingAgeMin + " с назад")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0
                    }
                    Rectangle {
                        id: pingBtn
                        implicitWidth: pingBtnRow.implicitWidth + s(14); implicitHeight: s(20); radius: s(6)
                        color: pingBtnArea.containsMouse ? Qt.alpha(ThemeBackend.mauve, 0.25) : Qt.alpha(ThemeBackend.surface1, 0.6)
                        opacity: XVpn.measuring ? 0.65 : 1
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Row {
                            id: pingBtnRow
                            anchors.centerIn: parent; spacing: s(4)
                            Text { text: "\u21BB"; font.pixelSize: XUi.font(11); color: ThemeBackend.mauve; anchors.verticalCenter: parent.verticalCenter
                                   RotationAnimation on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: XVpn.measuring } }
                            Text { text: XVpn.measuring ? root.t("vpn.popup.pinging", undefined, "измеряю…") : root.t("vpn.popup.ping_refresh", undefined, "Обновить пинг")
                                   font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.text; anchors.verticalCenter: parent.verticalCenter }
                        }
                        MouseArea { id: pingBtnArea; anchors.fill: parent; hoverEnabled: true; enabled: !XVpn.measuring; cursorShape: Qt.PointingHandCursor; onClicked: XVpn.remeasure() }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    visible: root.selectionText !== ""
                    text: root.selectionText; wrapMode: Text.Wrap
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0
                }
                Text {
                    Layout.fillWidth: true
                    visible: XVpn.nodes.length === 0
                    text: root.t("vpn.popup.no_nodes", undefined, "Нет узлов: обновите подписку"); wrapMode: Text.Wrap
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10); color: ThemeBackend.subtext0
                }
                Flickable {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(nodeCol.implicitHeight, s(264))
                    contentHeight: nodeCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Column {
                        id: nodeCol
                        width: parent.width
                        spacing: s(4)
                        Repeater {
                            model: XVpn.nodes
                            Rectangle {
                                id: nrow
                                required property var modelData
                                readonly property bool current: XVpn.node && XVpn.node.id === modelData.id
                                width: nodeCol.width; height: s(40)
                                radius: ThemeBackend.borderRadius
                                color: current ? Qt.alpha(ThemeBackend.mauve, 0.12) : (nma.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.5) : "transparent")
                                border.width: current ? 1 : 0
                                border.color: Qt.alpha(ThemeBackend.mauve, 0.6)
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Rectangle {
                                    x: s(12); anchors.verticalCenter: parent.verticalCenter
                                    width: s(14); height: s(14); radius: width / 2
                                    color: "transparent"; border.width: 2
                                    border.color: nrow.current ? ThemeBackend.mauve : ThemeBackend.overlay0
                                    Rectangle { anchors.centerIn: parent; width: s(6); height: s(6); radius: width / 2; color: ThemeBackend.mauve; visible: nrow.current }
                                }
                                Text {
                                    x: s(36); y: root.nodeHint(nrow.modelData) !== "" ? s(6) : (parent.height - height) / 2
                                    width: s(150)
                                    text: XVpn.displayName(nrow.modelData); elide: Text.ElideRight
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(11); font.weight: nrow.current ? Font.Bold : Font.Normal
                                    color: ThemeBackend.text
                                }
                                Text {
                                    visible: text !== ""
                                    x: s(36); y: s(23); width: s(190)
                                    text: root.nodeHint(nrow.modelData); elide: Text.ElideRight
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(8); color: ThemeBackend.peach
                                }
                                Rectangle {
                                    x: s(196); anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: proto.implicitWidth + s(12); implicitHeight: s(16); radius: s(4)
                                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                                    Text { id: proto; anchors.centerIn: parent; text: (nrow.modelData.protocol || "").toUpperCase().replace("HYSTERIA2", "HY2").replace("SHADOWSOCKS", "SS"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(8); color: ThemeBackend.subtext1 }
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: s(100); anchors.verticalCenter: parent.verticalCenter
                                    text: root.pingText(nrow.modelData)
                                    textFormat: Text.StyledText
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10)
                                    color: XVpn.pingDisplay === "dots" ? root.pingDotColor(nrow.modelData) : root.pingColor(nrow.modelData)
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: s(12); anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: root.speedText(nrow.modelData)
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(10); color: ThemeBackend.subtext1
                                }
                                MouseArea {
                                    id: nma
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (nrow.current) return;
                                        if (XVpn.connected) XVpn.switchNode(nrow.modelData.id); else XVpn.selectNode(nrow.modelData.id);
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(ThemeBackend.surface1, 0.5) }

                // footer
                RowLayout {
                    Layout.fillWidth: true
                    spacing: s(10)
                    ClickButton {
                        Layout.preferredHeight: s(34)
                        buttonIcon: "󰑐"
                        buttonText: root.t("vpn.popup.refresh", undefined, "Обновить подписку")
                        iconFontSize: s(13); textFontSize: s(11)
                        cornerRadius: ThemeBackend.borderRadius
                        horizontalPadding: s(12)
                        accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                        onClicked: XVpn.refreshSubscription()
                    }
                    Column {
                        Layout.fillWidth: true
                        spacing: s(2)
                        Text {
                            text: root.t("vpn.popup.updated", { ago: XVpn.ago(XVpn.subscription.updated) }, "обновлено " + XVpn.ago(XVpn.subscription.updated))
                            visible: !!XVpn.subscription.updated
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0
                        }
                        Text {
                            visible: XVpn.subInfo.length > 0
                            text: XVpn.subInfo.join("  ·  "); elide: Text.ElideRight; width: parent.width
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0
                        }
                        Text {
                            visible: XVpn.trafficTotal > 0
                            text: root.t("vpn.popup.traffic", { used: XVpn.fmtGb(XVpn.trafficUsed), total: XVpn.fmtGb(XVpn.trafficTotal) },
                                         "трафик " + XVpn.fmtGb(XVpn.trafficUsed) + " из " + XVpn.fmtGb(XVpn.trafficTotal) + " ГБ")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.font(9); color: ThemeBackend.subtext0
                        }
                    }
                    ClickButton {
                        Layout.preferredHeight: s(34)
                        buttonIcon: "󰐥"
                        buttonText: XVpn.connected || XVpn.transitional ? root.t("vpn.popup.disconnect", undefined, "Отключить") : root.t("vpn.popup.connect", undefined, "Подключить")
                        iconFontSize: s(13); textFontSize: s(11)
                        cornerRadius: ThemeBackend.borderRadius
                        horizontalPadding: s(14)
                        accentColor: XVpn.connected || XVpn.transitional ? Qt.alpha(ThemeBackend.red, 0.16) : ThemeBackend.mauve
                        textColor: XVpn.connected || XVpn.transitional ? ThemeBackend.red : ThemeBackend.crust
                        enabled: !XVpn.busy
                        onClicked: XVpn.toggle()
                    }
                }
            }
        }
    }
}
