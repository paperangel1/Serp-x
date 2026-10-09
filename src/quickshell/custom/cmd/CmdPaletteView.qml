import QtQuick
import QtQuick.Layouts
import "../../"
import ".."
import "LaunchLogic.js" as LL

// Command palette (see CmdPalette.qml for the layer-shell window around it): search by name / description / node
// keywords, arrows + Enter run, Tab shows the automations too, the star pins. Data and actions: XCmdLaunch.
Item {
    id: root

    property string query: ""
    property int index: 0
    property bool active: true                     // false: nothing grabs the focus (offscreen renders)
    readonly property var results: LL.rank(XCmdLaunch.commands, XCmdLaunch.pinnedIds, query, XCmdLaunch.showAuto)
    readonly property var current: (index >= 0 && index < results.length) ? results[index] : null
    readonly property bool hasAutoHidden: !XCmdLaunch.showAuto && XCmdLaunch.commands.some(c => c.kind === "auto" && !c.example)
    signal closeRequested()

    implicitWidth: XUi.s(640)
    implicitHeight: card.implicitHeight

    function t(k, fb, args) { return XI18n.t(k, args, fb); }
    function focusSearch() { search.forceActiveFocus(); }
    function reset() { query = ""; index = 0; search.text = ""; }
    onResultsChanged: { if (index >= results.length) index = Math.max(0, results.length - 1); }
    onQueryChanged: index = 0

    function runCurrent() {
        const c = current;
        if (!c) return;
        const why = LL.blockReason(c);
        if (XCmdLaunch.run(c) && why === null) closeRequested();
    }
    function toggleAuto() { XCmdLaunch.showAuto = !XCmdLaunch.showAuto; }
    function move(d) {
        if (results.length === 0) return;
        index = (index + d + results.length) % results.length;
        list.positionViewAtIndex(index, ListView.Contain);
    }
    function statusText(c) {
        const l = c.last_run;
        if (!l) return t("cmd.launch.never", "не запускалась");
        const when = LL.ago(l.ts, Date.now(), { now: t("cmd.launch.ago_now", "только что"), min: t("cmd.launch.ago_min", "мин назад"), hour: t("cmd.launch.ago_hour", "ч назад"), day: t("cmd.launch.ago_day", "дн назад") });
        return t("cmd.launch.st_" + l.status, l.status) + " · " + when;
    }

    Rectangle {
        id: card
        anchors.fill: parent
        implicitHeight: header.height + list.height + footer.height + XUi.s(2)
        radius: XUi.radiusCtl
        color: Qt.alpha(ThemeBackend.mantle, 0.98)
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface1, 0.7)
        clip: true

        // ---- search field ------------------------------------------------------------------------
        Item {
            id: header
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: XUi.rowH + XUi.gap * 2
            Text {
                id: lens
                anchors { left: parent.left; leftMargin: XUi.gap + XUi.gapSm; verticalCenter: parent.verticalCenter }
                text: "󰍉"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconLg; color: ThemeBackend.mauve
            }
            TextInput {
                id: search
                objectName: "palSearch"
                anchors { left: lens.right; leftMargin: XUi.gapSm; right: closeBtn.left; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub
                selectionColor: Qt.alpha(ThemeBackend.mauve, 0.5)
                clip: true
                focus: root.active
                onTextChanged: root.query = text
                Keys.onDownPressed: root.move(1)
                Keys.onUpPressed: root.move(-1)
                Keys.onReturnPressed: root.runCurrent()
                Keys.onEnterPressed: root.runCurrent()
                Keys.onTabPressed: root.toggleAuto()
                Keys.onPressed: (e) => {
                    if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_P && root.current) { XCmdLaunch.togglePinned(root.current.id); e.accepted = true; }
                }
                Text {
                    visible: search.text === ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.t("cmd.launch.search", "Найти команду…")
                    color: ThemeBackend.subtext0; font: search.font
                }
            }
            Rectangle {
                id: closeBtn
                objectName: "palClose"
                anchors { right: parent.right; rightMargin: XUi.gapSm + XUi.gapXs; verticalCenter: parent.verticalCenter }
                width: XUi.iconBoxSm; height: width; radius: XUi.radius
                color: closeArea.containsMouse ? Qt.alpha(ThemeBackend.red, 0.35) : Qt.alpha(ThemeBackend.surface0, 0.9)
                Behavior on color { ColorAnimation { duration: 150 } }
                Text { anchors.centerIn: parent; text: "✕"; color: ThemeBackend.text; font.pixelSize: XUi.fRow }
                MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.closeRequested() }
            }
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: Qt.alpha(ThemeBackend.surface1, 0.6) }
        }

        // ---- list --------------------------------------------------------------------------------
        ListView {
            id: list
            objectName: "palList"
            anchors { top: header.bottom; left: parent.left; right: parent.right }
            readonly property real rowHeight: XUi.s(54)
            height: root.results.length === 0 ? XUi.s(96) : Math.min(root.results.length, 7) * rowHeight + XUi.gapSm
            topMargin: XUi.gapXxs
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.results
            currentIndex: root.index

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property var c: modelData
                readonly property string why: LL.blockReason(c) || ""
                readonly property string rs: XCmdLaunch.stateOf(c.id)
                objectName: "palRow"
                width: list.width - XUi.gapSm * 2
                x: XUi.gapSm
                height: list.rowHeight - XUi.gapXxs
                radius: XUi.radiusBtn
                color: row.index === root.index ? Qt.alpha(ThemeBackend.mauve, 0.16) : (rowArea.containsMouse ? Qt.alpha(ThemeBackend.surface0, 0.7) : "transparent")
                border.width: row.index === root.index ? 1 : 0
                border.color: Qt.alpha(ThemeBackend.mauve, 0.55)
                opacity: row.why !== "" ? 0.78 : 1

                MouseArea {
                    id: rowArea
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onEntered: root.index = row.index
                    onClicked: { root.index = row.index; root.runCurrent(); }
                }
                Rectangle {
                    id: ico
                    anchors { left: parent.left; leftMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                    width: XUi.iconBox; height: width; radius: XUi.radiusBtn
                    color: Qt.alpha(ThemeBackend.surface0, 0.9)
                    Text { anchors.centerIn: parent; text: CK.glyph(row.c.icon); font.family: ThemeBackend.iconFont; font.pixelSize: XUi.iconMd; color: ThemeBackend.mauve }
                }
                Column {
                    anchors { left: ico.right; leftMargin: XUi.gap; right: side.left; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                    spacing: XUi.gapXxs
                    Row {
                        spacing: XUi.gapXs
                        Text {
                            id: nm
                            text: row.c.name; color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.bold: true
                            elide: Text.ElideRight; width: Math.min(implicitWidth, row.width - XUi.s(250))
                        }
                        Rectangle {
                            objectName: "palKind"
                            visible: row.c.kind === "auto"
                            anchors.verticalCenter: parent.verticalCenter
                            width: kindTxt.implicitWidth + XUi.gapSm * 2; height: kindTxt.implicitHeight + XUi.gapXs; radius: height / 2
                            color: Qt.alpha(row.c.enabled ? ThemeBackend.green : ThemeBackend.overlay0, 0.18)
                            Text {
                                id: kindTxt; anchors.centerIn: parent
                                text: (row.c.enabled ? "● " : "○ ") + root.t("cmd.launch.auto", "автоматизация")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                                color: row.c.enabled ? ThemeBackend.green : ThemeBackend.subtext0
                            }
                        }
                    }
                    Text {
                        objectName: row.why !== "" ? "palBlock" : "palDesc"
                        width: parent.width
                        text: row.why !== "" ? ("⚠ " + XCmdLaunch.blockText(row.why)) : (row.c.description !== "" ? row.c.description : root.t("cmd.row.no_desc", "без описания"))
                        color: row.why !== "" ? ThemeBackend.yellow : ThemeBackend.subtext0
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; elide: Text.ElideRight
                    }
                }
                Row {
                    id: side
                    anchors { right: parent.right; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                    spacing: XUi.gapSm
                    Text {
                        objectName: "palStatus"
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.rs === "running" ? root.t("cmd.launch.running", "выполняется…")
                              : row.rs === "ok" ? root.t("cmd.launch.done_short", "готово")
                              : row.rs === "error" ? root.t("cmd.launch.failed_short", "ошибка")
                              : root.statusText(row.c)
                        color: row.rs === "error" || (row.rs === "" && row.c.last_run && row.c.last_run.status !== "ok") ? ThemeBackend.red
                               : (row.rs === "ok" ? ThemeBackend.green : ThemeBackend.subtext0)
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    }
                    Rectangle {
                        objectName: "palOpen"
                        visible: row.why !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        width: openTxt.implicitWidth + XUi.gap * 1.5; height: XUi.btnH - XUi.gapXs; radius: XUi.radiusBtn
                        color: openArea.containsMouse ? ThemeBackend.surface1 : ThemeBackend.surface0
                        Text { id: openTxt; anchors.centerIn: parent; text: root.t("cmd.launch.open", "Открыть"); color: ThemeBackend.text; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
                        MouseArea { id: openArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { XCmdLaunch.openInApp(row.c.name); root.closeRequested(); } }
                    }
                    Text {
                        objectName: "palStar"
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.c.pinned ? "★" : "☆"
                        color: row.c.pinned ? ThemeBackend.yellow : (starArea.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0)
                        font.pixelSize: XUi.iconLg
                        MouseArea { id: starArea; anchors.fill: parent; anchors.margins: -XUi.gapXs; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: XCmdLaunch.togglePinned(row.c.id) }
                    }
                }
            }

            // empty / loading / error states
            Text {
                objectName: "palEmpty"
                visible: root.results.length === 0
                anchors.centerIn: parent
                width: parent.width - XUi.gap * 4
                horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                color: XCmdLaunch.error !== "" ? ThemeBackend.red : ThemeBackend.subtext0
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
                text: XCmdLaunch.error !== "" ? XCmdLaunch.error
                      : !XCmdLaunch.loaded ? root.t("cmd.launch.loading", "Загружаю команды…")
                      : root.query.trim() !== "" ? (root.hasAutoHidden ? root.t("cmd.launch.nothing_tab", "Ничего не найдено. Tab: искать и среди автоматизаций") : root.t("cmd.launch.nothing", "Ничего не найдено"))
                      : root.t("cmd.launch.no_commands", "Пока нет ручных команд. Создайте их в приложении «Команды».")
            }
        }

        // ---- footer ------------------------------------------------------------------------------
        Rectangle {
            id: footer
            objectName: "palFooter"
            anchors { top: list.bottom; left: parent.left; right: parent.right }
            height: XUi.rowH
            color: Qt.alpha(ThemeBackend.surface0, 0.35)
            Row {
                anchors { left: parent.left; leftMargin: XUi.gap; verticalCenter: parent.verticalCenter }
                spacing: XUi.gap
                Text { text: "↑↓ " + root.t("cmd.launch.hint_pick", "выбор") + "   ↵ " + root.t("cmd.launch.hint_run", "запустить") + "   Esc " + root.t("cmd.launch.hint_close", "закрыть")
                       color: ThemeBackend.subtext0; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
            }
            Rectangle {
                id: autoToggle
                objectName: "palAutoToggle"
                anchors { right: parent.right; rightMargin: XUi.gapSm; verticalCenter: parent.verticalCenter }
                width: autoTxt.implicitWidth + XUi.gap * 1.5; height: XUi.btnH - XUi.gapXs; radius: XUi.radiusBtn
                color: XCmdLaunch.showAuto ? Qt.alpha(ThemeBackend.mauve, 0.25) : (autoArea.containsMouse ? ThemeBackend.surface1 : "transparent")
                border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.14)
                Text { id: autoTxt; anchors.centerIn: parent
                       text: "Tab · " + (XCmdLaunch.showAuto ? "☑ " : "☐ ") + root.t("cmd.launch.show_auto", "показывать автоматизации")
                       color: XCmdLaunch.showAuto ? ThemeBackend.text : ThemeBackend.subtext0; font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption }
                MouseArea { id: autoArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: XCmdLaunch.showAuto = !XCmdLaunch.showAuto }
            }
        }
    }
}
