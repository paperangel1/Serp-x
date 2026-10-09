import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../"
import "../../reusables"
import ".."

// View of the note editor (see NoteEditor.qml for the layer-shell window around it).
// Mini editor for one markdown note: edit / preview, autosave (debounced), note list, new, delete, pin.
Item {
    id: win

    required property var ctl
    readonly property bool shown: ctl.mode === "editor" || panel.opacity > 0.01

    readonly property int margin: Scaler.s(14)
    readonly property string notePath: ctl.currentPath
    property bool pinned: false
    property alias text: edit.text          // exposed for tests and callers that prefill a note
    property bool previewMode: false
    property bool menuOpen: false
    property bool dirty: false
    property bool loadingText: false
    property string savedAt: ""
    readonly property string firstLine: {
        let m = /^#+\s+(.*)$/m.exec(edit.text);
        if (m && m[1].trim() !== "") return m[1].trim();
        let l = edit.text.split("\n").find(x => x.trim() !== "");
        return l ? l.trim().substring(0, 60) : XI18n.t("tools.notes.untitled", undefined, "Новая заметка");
    }
    readonly property int words: edit.text.trim() === "" ? 0 : edit.text.trim().split(/\s+/).length

    function s(v) { return Scaler.s(v); }
    function t(key, args, fb) { return XI18n.t(key, args, fb); }
    function shortPath(p) { return String(p).replace(/^\/home\/[^/]+/, "~"); }
    function p2(n) { return (n < 10 ? "0" : "") + n; }
    function wordsText(n) {
        let m = n % 10, h = n % 100;
        let w = (h >= 11 && h <= 14) ? "слов" : (m === 1 ? "слово" : (m >= 2 && m <= 4 ? "слова" : "слов"));
        return XI18n.currentLang === "ru" ? "Markdown  ·  " + n + " " + w : t("tools.notes.stats", { words: n }, "Markdown  ·  " + n + " words");
    }
    function nowText() { let d = new Date(); return p2(d.getHours()) + ":" + p2(d.getMinutes()); }

    function flush() { saveTimer.stop(); if (dirty && notePath !== "") file.setText(edit.text); }

    function deleteCurrent() {
        let p = notePath;
        saveTimer.stop(); dirty = false;
        trashProc.command = ["bash", ctl.scriptPath(), "trash", p];
        trashProc.running = true;
    }

    implicitWidth: s(560) + margin
    implicitHeight: s(468) + margin

    onShownChanged: if (shown) { previewMode = false; menuOpen = false; Qt.callLater(() => edit.forceActiveFocus()); }

    Process { id: trashProc; onExited: { win.ctl.currentPath = ""; win.ctl.refresh(); win.ctl.mode = "hidden"; } }

    FileView {
        id: file
        path: win.notePath
        blockLoading: true
        watchChanges: false
        onLoaded: { win.loadingText = true; edit.text = file.text(); win.loadingText = false; win.dirty = false; }
        onSaved: { win.dirty = false; win.savedAt = win.nowText(); win.ctl.refresh(); }
        onLoadFailed: (error) => { XLog.warn("tools", "notes: could not load the note file (error " + error + ")"); win.loadingText = true; edit.text = ""; win.loadingText = false; }
        onSaveFailed: (error) => XLog.error("tools", "notes: autosave failed (error " + error + ")")
    }

    Timer { id: saveTimer; interval: 800; onTriggered: if (win.dirty && win.notePath !== "") file.setText(edit.text) }

    Rectangle {
        id: panel
        x: ctl.atRight ? 0 : win.margin
        y: ctl.atBottom ? 0 : win.margin
        width: s(560); height: s(468)
        radius: ThemeBackend.borderRadius + s(6)
        color: ThemeBackend.crust
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface1, 0.9)
        opacity: ctl.mode === "editor" ? 1 : 0
        transform: Translate { y: (ctl.mode === "editor" ? 0 : (ctl.atBottom ? s(18) : -s(18))); Behavior on y { NumberAnimation { duration: 340; easing.type: Easing.OutQuint } } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) { if (win.menuOpen) win.menuOpen = false; else { win.flush(); win.ctl.closeAll(); } e.accepted = true; }
                else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_N) { win.flush(); win.ctl.newNote(); e.accepted = true; }
                else if ((e.modifiers & Qt.ControlModifier) && e.key === Qt.Key_S) { win.flush(); e.accepted = true; }
            }

            // ---- header -----------------------------------------------------------------
            RowLayout {
                id: header
                x: s(14); y: s(14)
                width: parent.width - s(28)
                height: s(40)
                spacing: s(10)

                Rectangle {
                    Layout.preferredWidth: s(40); Layout.preferredHeight: s(40)
                    radius: ThemeBackend.borderRadius
                    color: ThemeBackend.surface0
                    Text { anchors.centerIn: parent; text: "󰈙"; font.family: "Iosevka Nerd Font"; font.pixelSize: XUi.s(20); color: ThemeBackend.mauve }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: s(1)
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: win.firstLine
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.weight: Font.DemiBold
                        color: ThemeBackend.text
                    }
                    Text {
                        Layout.fillWidth: true; elide: Text.ElideMiddle
                        text: win.shortPath(win.notePath)
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                        color: ThemeBackend.subtext0
                    }
                }
                IconButton {
                    size: s(36); Layout.preferredWidth: s(36); Layout.preferredHeight: s(36)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰐕"; iconFontSize: XUi.fHead
                    accentColor: ThemeBackend.surface0; textColor: ThemeBackend.text
                    onClicked: { win.flush(); win.ctl.newNote(); }
                }
                IconButton {
                    size: s(36); Layout.preferredWidth: s(36); Layout.preferredHeight: s(36)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: win.pinned ? "󰐃" : "󰤱"; iconFontSize: XUi.fHead
                    accentColor: win.pinned ? ThemeBackend.mauve : ThemeBackend.surface0
                    textColor: win.pinned ? ThemeBackend.crust : ThemeBackend.text
                    onClicked: win.pinned = !win.pinned
                }
                IconButton {
                    size: s(36); Layout.preferredWidth: s(36); Layout.preferredHeight: s(36)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰍜"; iconFontSize: XUi.fHead
                    accentColor: win.menuOpen ? ThemeBackend.surface2 : ThemeBackend.surface0
                    textColor: ThemeBackend.text
                    onClicked: win.menuOpen = !win.menuOpen
                }
                IconButton {
                    size: s(36); Layout.preferredWidth: s(36); Layout.preferredHeight: s(36)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰅖"; iconFontSize: XUi.fHead
                    accentColor: ThemeBackend.red; textColor: ThemeBackend.crust
                    onClicked: { win.flush(); win.ctl.closeAll(); }
                }
            }

            // ---- mode tabs + stats -----------------------------------------------------------------
            Item {
                id: tabsRow
                x: s(14); y: header.y + header.height + s(10)
                width: parent.width - s(28); height: s(32)

                Rectangle {
                    id: tabsBox
                    width: s(190); height: s(32)
                    radius: ThemeBackend.borderRadius
                    color: ThemeBackend.surface0
                    Row {
                        anchors.fill: parent
                        Repeater {
                            model: [ { k: false, label: win.t("tools.notes.edit", undefined, "Правка") }, { k: true, label: win.t("tools.notes.preview", undefined, "Просмотр") } ]
                            delegate: Rectangle {
                                required property var modelData
                                width: tabsBox.width / 2; height: tabsBox.height
                                radius: ThemeBackend.borderRadius
                                color: win.previewMode === modelData.k ? ThemeBackend.mauve : "transparent"
                                Behavior on color { ColorAnimation { duration: 140 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: parent.modelData.label
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; font.weight: Font.DemiBold
                                    color: win.previewMode === parent.modelData.k ? ThemeBackend.crust : ThemeBackend.text
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.previewMode = parent.modelData.k }
                            }
                        }
                    }
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: win.wordsText(win.words)
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }

            // ---- editor / preview ---------------------------------------------------------------------
            Rectangle {
                id: area
                x: s(14); y: tabsRow.y + tabsRow.height + s(10)
                width: parent.width - s(28)
                height: parent.height - y - s(44)
                radius: ThemeBackend.borderRadius
                color: ThemeBackend.mantle
                border.width: 2
                border.color: edit.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface1, 0.8)
                Behavior on border.color { ColorAnimation { duration: 140 } }

                ScrollView {
                    id: sv
                    anchors.fill: parent
                    anchors.margins: s(2)
                    clip: true
                    visible: !win.previewMode
                    TextArea {
                        id: edit
                        wrapMode: TextArea.Wrap
                        selectByMouse: true
                        background: null
                        padding: s(12)
                        color: ThemeBackend.text
                        selectionColor: ThemeBackend.mauve
                        selectedTextColor: ThemeBackend.crust
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: XUi.fRow
                        placeholderText: win.t("tools.notes.placeholder", undefined, "Начните писать…")
                        placeholderTextColor: ThemeBackend.overlay1
                        onTextChanged: if (!win.loadingText) { win.dirty = true; saveTimer.restart(); }
                    }
                }
                Flickable {
                    anchors.fill: parent
                    anchors.margins: s(2)
                    clip: true
                    visible: win.previewMode
                    contentHeight: previewText.implicitHeight + s(24)
                    contentWidth: width
                    Text {
                        id: previewText
                        x: s(12); y: s(12)
                        width: parent.width - s(24)
                        text: edit.text
                        textFormat: Text.MarkdownText
                        wrapMode: Text.Wrap
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow
                        color: ThemeBackend.text
                        linkColor: ThemeBackend.blue
                        onLinkActivated: (l) => Qt.openUrlExternally(l)
                    }
                }
            }

            // ---- footer ---------------------------------------------------------------------------------
            RowLayout {
                x: s(14); y: parent.height - s(34)
                width: parent.width - s(28); height: s(20)
                spacing: s(8)
                Rectangle { Layout.preferredWidth: s(8); Layout.preferredHeight: s(8); radius: width / 2; color: win.dirty ? ThemeBackend.yellow : ThemeBackend.green }
                Text {
                    text: win.dirty ? win.t("tools.notes.saving", undefined, "Автосохранение · сохраняю…")
                                    : (win.savedAt !== "" ? win.t("tools.notes.saved", { time: win.savedAt }, "Автосохранение · сохранено в " + win.savedAt)
                                                           : win.t("tools.notes.saved_idle", undefined, "Автосохранение включено"))
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: win.t("tools.notes.keys", undefined, "Esc — свернуть  ·  Ctrl+N — новая")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }

            // ---- notes menu ------------------------------------------------------------------------------
            Rectangle {
                id: menu
                visible: win.menuOpen
                x: parent.width - width - s(14)
                y: header.y + header.height + s(6)
                width: s(300)
                height: Math.min(s(300), listCol.implicitHeight + s(16))
                radius: ThemeBackend.borderRadius + s(2)
                color: ThemeBackend.surface0
                border.width: 1; border.color: Qt.alpha(ThemeBackend.surface2, 0.8)
                z: 10

                Column {
                    id: listCol
                    anchors.fill: parent; anchors.margins: s(8)
                    spacing: s(4)
                    Repeater {
                        model: win.ctl.notes.slice(0, 6)
                        delegate: Rectangle {
                            required property var modelData
                            width: listCol.width; height: s(32)
                            radius: ThemeBackend.borderRadius
                            color: modelData.path === win.notePath ? ThemeBackend.surface2 : (rowMa.containsMouse ? ThemeBackend.surface1 : "transparent")
                            Text {
                                anchors.verticalCenter: parent.verticalCenter; x: s(10); width: parent.width - s(20)
                                elide: Text.ElideRight; text: modelData.title
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.text
                            }
                            MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { win.flush(); win.menuOpen = false; win.ctl.currentPath = parent.modelData.path; } }
                        }
                    }
                    Rectangle {
                        width: listCol.width; height: s(32)
                        radius: ThemeBackend.borderRadius
                        color: delMa.containsMouse ? Qt.alpha(ThemeBackend.red, 0.35) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; x: s(10); text: win.t("tools.notes.delete", undefined, "Удалить заметку"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.red }
                        MouseArea { id: delMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { win.menuOpen = false; win.deleteCurrent(); } }
                    }
                }
            }
        }
    }
}
