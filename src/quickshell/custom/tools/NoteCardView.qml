import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../"
import ".."

// View of the card (see NoteCard.qml for the layer-shell window around it).
// Small card with the latest note, shown by the hot corner. Pointer anywhere in the card (including the
// transparent margin towards the screen corner) keeps it alive; click expands it into the editor.
Item {
    id: win

    required property var ctl
    property var screen: null
    readonly property bool shown: ctl.mode === "card" || body.opacity > 0.01

    readonly property var latest: ctl.notes.length > 0 ? ctl.notes[0] : null
    readonly property int margin: Scaler.s(14)

    function s(v) { return Scaler.s(v); }

    function whenText(ts) {
        let d = new Date(ts * 1000), now = new Date();
        let p2 = (n) => (n < 10 ? "0" : "") + n;
        let hm = p2(d.getHours()) + ":" + p2(d.getMinutes());
        if (d.toDateString() === now.toDateString()) return XI18n.t("tools.notes.today", { time: hm }, "сегодня, " + hm);
        let y = new Date(now.getTime() - 86400000);
        if (d.toDateString() === y.toDateString()) return XI18n.t("tools.notes.yesterday", { time: hm }, "вчера, " + hm);
        return p2(d.getDate()) + "." + p2(d.getMonth() + 1) + ", " + hm;
    }

    // preview: the note body without its title line, trimmed to 3 lines
    function previewOf(n) {
        if (!n) return "";
        let lines = String(n.preview || "").split("\n");
        let i = lines.findIndex(l => /^#+\s+/.test(l));
        if (i === 0) lines = lines.slice(1);
        lines = lines.filter(l => l.trim() !== "");
        return lines.slice(0, 3).join("\n");
    }

    function countText(n) {
        let m = n % 10, h = n % 100;
        let w = (h >= 11 && h <= 14) ? "заметок" : (m === 1 ? "заметка" : (m >= 2 && m <= 4 ? "заметки" : "заметок"));
        // Russian plural forms are computed here; other languages use the translated string.
        return XI18n.currentLang === "ru" ? n + " " + w : XI18n.t("tools.notes.count", { n: n }, n + " notes");
    }

    implicitWidth: s(380) + margin
    implicitHeight: s(176) + margin

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: ctl.cardHovered(true)
        onExited: ctl.cardHovered(false)
        onClicked: ctl.openEditor(win.screen, "")
    }

    Rectangle {
        id: body
        x: ctl.atRight ? 0 : win.margin
        y: ctl.atBottom ? 0 : win.margin
        width: s(380); height: s(176)
        radius: ThemeBackend.borderRadius + s(4)
        color: ThemeBackend.crust
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface1, 0.9)
        opacity: ctl.mode === "card" ? 1 : 0
        transform: Translate { y: (ctl.mode === "card" ? 0 : (ctl.atBottom ? s(14) : -s(14))) ; Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } } }
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        RowLayout {
            x: s(14); y: s(12)
            width: parent.width - s(28)
            spacing: s(10)
            Rectangle {
                Layout.preferredWidth: s(34); Layout.preferredHeight: s(34)
                radius: ThemeBackend.borderRadius
                color: ThemeBackend.surface0
                Text { anchors.centerIn: parent; text: "󰈙"; font.family: "Iosevka Nerd Font"; font.pixelSize: XUi.fHead; color: ThemeBackend.mauve }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: s(1)
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: win.latest ? win.latest.title : XI18n.t("tools.notes.none", undefined, "Заметок пока нет")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.weight: Font.DemiBold
                    color: ThemeBackend.text
                }
                Text {
                    text: win.latest ? win.whenText(win.latest.mtime) : XI18n.t("tools.notes.none_sub", undefined, "нажмите, чтобы создать первую")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }
            Text {
                Layout.alignment: Qt.AlignTop
                visible: ctl.notes.length > 0
                text: win.countText(ctl.notes.length)
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                color: ThemeBackend.subtext0
            }
        }

        Text {
            x: s(14); y: s(58)
            width: parent.width - s(28)
            height: s(74)
            text: win.previewOf(win.latest)
            elide: Text.ElideRight
            maximumLineCount: 3
            wrapMode: Text.NoWrap
            lineHeight: 1.25
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
            color: ThemeBackend.text
        }

        Rectangle { x: s(14); y: parent.height - s(30); width: parent.width - s(28); height: 1; color: Qt.alpha(ThemeBackend.surface1, 0.6) }
        Text {
            x: s(14); y: parent.height - s(24)
            text: XI18n.t("tools.notes.card_hint", undefined, "задержите курсор или нажмите — откроется редактор")
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
            color: ThemeBackend.subtext0
        }
    }
}
