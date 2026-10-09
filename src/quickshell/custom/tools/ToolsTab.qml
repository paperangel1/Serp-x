import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../../"
import "../../reusables"
import ".."

// «Инструменты» tab: quick-notes corner, colour picker, text recognition (OCR).
Item {
    id: toolsTabRoot
    objectName: "toolsTab"
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

    readonly property var cornerKeys: ["bottom-right", "top-right", "bottom-left", "top-left"]
    readonly property var cornerLabels: [t("tools.tab.corner_br", undefined, "Справа внизу"), t("tools.tab.corner_tr", undefined, "Справа вверху"),
                                          t("tools.tab.corner_bl", undefined, "Слева внизу"), t("tools.tab.corner_tl", undefined, "Слева вверху")]
    readonly property var formatKeys: ["hex", "rgb", "hsl"]
    readonly property var formatLabels: ["HEX   #RRGGBB", "RGB   rgb(r, g, b)", "HSL   hsl(h, s%, l%)"]
    readonly property var langKeys: ["rus+eng", "rus", "eng"]
    readonly property var langLabels: [t("tools.tab.lang_both", undefined, "Русский + English"), t("tools.tab.lang_rus", undefined, "Русский"), t("tools.tab.lang_eng", undefined, "English")]

    // Combo of the hotkey the user bound to the notes (if any), shown read-only.
    readonly property string notesCombo: {
        try {
            let list = XHotkeys.custom || [];
            for (let i = 0; i < list.length; i++) {
                if (JSON.stringify(list[i]).indexOf("xtools notes") !== -1 || JSON.stringify(list[i]).indexOf("xtools\",\"notes") !== -1) {
                    let c = list[i];
                    let mods = c.mods || c.newMods || [];
                    let key = c.key || c.newKey || "";
                    if (key !== "") return mods.concat([key]).join(" + ");
                }
            }
        } catch (e) {}
        return "";
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

    component TG: Toggle {
        Layout.alignment: Qt.AlignVCenter
        accentColor: ThemeBackend.mauve
        baseColor: ThemeBackend.surface1
        handleColor: ThemeBackend.crust
        handleOffColor: ThemeBackend.text
    }

    component NS: NumberSelector {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: rootObj.s(112)
        implicitHeight: rootObj.s(32)
        suffix: " " + toolsTabRoot.t("tools.tab.ms", undefined, "мс")
        baseColor: ThemeBackend.surface0
        accentColor: ThemeBackend.mauve
        buttonColor: ThemeBackend.surface1
        buttonTextColor: ThemeBackend.text
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

            // ---------------- quick notes ----------------
            SectionLabel { text: toolsTabRoot.t("tools.tab.sec_notes", undefined, "БЫСТРЫЕ ЗАМЕТКИ") }

            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰈙"
                title: toolsTabRoot.t("tools.tab.notes_enabled", undefined, "Горячий угол")
                description: toolsTabRoot.t("tools.tab.notes_enabled_d", undefined, "Наведите курсор в угол — появится последняя заметка")
                TG { checked: XToolsConf.notes.enabled; onToggled: (c) => XToolsConf.set("notes", "enabled", c) }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰍽"
                title: toolsTabRoot.t("tools.tab.corner", undefined, "Угол экрана")
                description: toolsTabRoot.t("tools.tab.corner_d", undefined, "Где ждать курсор (верхний правый занят панелью)")
                DD {
                    options: toolsTabRoot.cornerLabels
                    currentIndex: Math.max(0, toolsTabRoot.cornerKeys.indexOf(XToolsConf.notes.corner))
                    onSelected: (i, v) => XToolsConf.set("notes", "corner", toolsTabRoot.cornerKeys[i])
                }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰥔"
                title: toolsTabRoot.t("tools.tab.delay", undefined, "Задержка")
                description: toolsTabRoot.t("tools.tab.delay_d", undefined, "Показать карточку / раскрыть редактор, мс")
                RowLayout {
                    spacing: rootObj.s(8)
                    NS { from: 100; to: 2000; stepSize: 50; value: XToolsConf.notes.showDelay; onTriggered: XToolsConf.set("notes", "showDelay", Math.round(value)) }
                    NS { from: 300; to: 4000; stepSize: 100; value: XToolsConf.notes.expandDelay; onTriggered: XToolsConf.set("notes", "expandDelay", Math.round(value)) }
                }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰊓"
                title: toolsTabRoot.t("tools.tab.no_fullscreen", undefined, "Не срабатывать в полноэкранном режиме")
                description: toolsTabRoot.t("tools.tab.no_fullscreen_d", undefined, "Игры и видео не будут открывать заметки случайно")
                TG { checked: XToolsConf.notes.noFullscreen; onToggled: (c) => XToolsConf.set("notes", "noFullscreen", c) }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰳽"
                title: toolsTabRoot.t("tools.tab.no_drag", undefined, "Не срабатывать при перетаскивании")
                description: toolsTabRoot.t("tools.tab.no_drag_d", undefined, "Пока зажата кнопка мыши (окно, файл, выделение)")
                TG { checked: XToolsConf.notes.noDrag; onToggled: (c) => XToolsConf.set("notes", "noDrag", c) }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰌌"
                title: toolsTabRoot.t("tools.tab.hotkey", undefined, "Запасная горячая клавиша")
                description: toolsTabRoot.t("tools.tab.hotkey_d", undefined, "Открыть заметку без мыши. Назначается во вкладке «Горячие клавиши»")
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: comboText.implicitWidth + rootObj.s(20); implicitHeight: rootObj.s(26)
                    radius: rootObj.s(6)
                    color: ThemeBackend.surface0
                    Text {
                        id: comboText
                        anchors.centerIn: parent
                        text: toolsTabRoot.notesCombo !== "" ? toolsTabRoot.notesCombo : toolsTabRoot.t("tools.tab.hotkey_none", undefined, "не назначена")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; font.weight: Font.DemiBold
                        color: toolsTabRoot.notesCombo !== "" ? ThemeBackend.text : ThemeBackend.subtext0
                    }
                }
                ClickButton {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: rootObj.s(32)
                    buttonText: toolsTabRoot.t("tools.tab.configure", undefined, "Настроить")
                    cornerRadius: ThemeBackend.borderRadius
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    onClicked: toolsTabRoot.rootObj.gotoTab("hotkeys")
                }
            }

            // ---------------- colour picker ----------------
            SectionLabel { text: toolsTabRoot.t("tools.tab.sec_picker", undefined, "ПИПЕТКА") }

            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰈊"
                title: toolsTabRoot.t("tools.tab.format", undefined, "Формат копирования")
                description: toolsTabRoot.t("tools.tab.format_d", undefined, "Что попадает в буфер по клику. Shift — альтернативный формат")
                DD {
                    options: toolsTabRoot.formatLabels
                    currentIndex: Math.max(0, toolsTabRoot.formatKeys.indexOf(XToolsConf.picker.format))
                    onSelected: (i, v) => XToolsConf.set("picker", "format", toolsTabRoot.formatKeys[i])
                }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰋚"
                title: toolsTabRoot.t("tools.tab.history", undefined, "История цветов")
                description: toolsTabRoot.t("tools.tab.history_d", { n: XToolsConf.picker.max }, "Хранить последние " + XToolsConf.picker.max + " выбранных цветов")
                ClickButton {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: rootObj.s(32)
                    buttonText: toolsTabRoot.t("tools.tab.open", undefined, "Открыть")
                    cornerRadius: ThemeBackend.borderRadius
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    onClicked: Quickshell.execDetached(["serpantinum", "ipc", "call", "xtools", "colors"])
                }
                TG { checked: XToolsConf.picker.history; onToggled: (c) => XToolsConf.set("picker", "history", c) }
            }

            // ---------------- OCR ----------------
            SectionLabel { text: toolsTabRoot.t("tools.tab.sec_ocr", undefined, "РАСПОЗНАВАНИЕ ТЕКСТА") }

            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󱄽"
                title: toolsTabRoot.t("tools.tab.langs", undefined, "Языки")
                description: toolsTabRoot.t("tools.tab.langs_d", undefined, "Какие языки искать на скриншоте")
                DD {
                    options: toolsTabRoot.langLabels
                    currentIndex: Math.max(0, toolsTabRoot.langKeys.indexOf(XToolsConf.ocr.langs))
                    onSelected: (i, v) => XToolsConf.set("ocr", "langs", toolsTabRoot.langKeys[i])
                }
            }
            SettingsRow {
                rootObj: toolsTabRoot.rootObj
                icon: "󰦨"
                title: toolsTabRoot.t("tools.tab.join", undefined, "Склеивать переносы строк")
                description: toolsTabRoot.t("tools.tab.join_d", undefined, "Превращать разорванные строки в сплошной абзац")
                TG { checked: XToolsConf.ocr.joinLines; onToggled: (c) => XToolsConf.set("ocr", "joinLines", c) }
            }

            Item { Layout.preferredHeight: rootObj.s(4) }
        }
    }
}
