import QtQuick
import "../../"
import ".."

// Small popup next to a node input (or a comment) that edits one literal. Enter saves, Esc cancels; a wrong value stays
// open with the reason. Kinds: text | int | float | color | time | list | choice | comment_title | comment_text.
Rectangle {
    id: ve
    property bool shown: false
    property string kind: "text"
    property string label: ""
    property string typeLabel: ""
    property var choices: []
    property var choiceLabels: ({})
    property var minValue: null
    property var maxValue: null
    property string itemType: "text"       // element type for kind: list
    property string error: ""
    signal committed(var value, bool clear)
    signal cancelled()

    visible: shown
    width: kind === "list" || kind === "comment_text" ? 340 : 280
    height: kind === "choice" ? 56 + choices.length * 34 + 16 : (kind === "list" || kind === "comment_text" ? 210 : 112 + (error !== "" ? 20 : 0))
    radius: 12
    color: ThemeBackend.mantle
    border.width: 1
    border.color: Qt.alpha(error !== "" ? "#f38ba8" : ThemeBackend.mauve, 0.7)
    z: 50
    function t(k, fb, args) { return XI18n.t(k, args, fb); }

    function openWith(k, lab, typeLab, current, opts) {
        kind = k; label = lab; typeLabel = typeLab; error = "";
        choices = opts && opts.choices ? opts.choices : [];
        choiceLabels = opts && opts.labels ? opts.labels : ({});
        minValue = opts && opts.min !== undefined ? opts.min : null;
        maxValue = opts && opts.max !== undefined ? opts.max : null;
        itemType = opts && opts.itemType ? opts.itemType : "text";
        let txt = "";
        if (k === "list") txt = Array.isArray(current) ? current.join("\n") : "";
        else if (current !== undefined && current !== null) txt = String(current);
        single.text = txt; multi.text = txt;
        shown = true;
        Qt.callLater(function () {
            if (kind === "list" || kind === "comment_text") { multi.forceActiveFocus(); multi.selectAll(); }
            else { single.forceActiveFocus(); single.selectAll(); }
        });
    }
    function close() { shown = false; }
    function convert(s) {
        const lines = kind === "list" ? s.split("\n").map(x => x.trim()).filter(x => x !== "") : [];
        if (kind === "list") {
            const out = [];
            for (let i = 0; i < lines.length; i++) {
                if (itemType === "int" || itemType === "float") {
                    const v = Number(lines[i]);
                    if (isNaN(v) || (itemType === "int" && Math.floor(v) !== v)) return { error: t("cmd.edit.err_number_line", "Строка " + (i + 1) + ": нужно число", { n: i + 1 }) };
                    out.push(v);
                } else out.push(lines[i]);
            }
            return { value: out };
        }
        if (kind === "int" || kind === "float") {
            if (s.trim() === "") return { clear: true };
            const v = Number(s.replace(",", "."));
            if (isNaN(v)) return { error: t("cmd.edit.err_number", "Нужно число") };
            if (kind === "int" && Math.floor(v) !== v) return { error: t("cmd.edit.err_int", "Нужно целое число") };
            if (minValue !== null && v < minValue) return { error: t("cmd.edit.err_min", "Не меньше " + minValue, { v: minValue }) };
            if (maxValue !== null && v > maxValue) return { error: t("cmd.edit.err_max", "Не больше " + maxValue, { v: maxValue }) };
            return { value: v };
        }
        if (kind === "color") {
            if (s.trim() === "") return { clear: true };
            return /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(s.trim()) ? { value: s.trim() } : { error: t("cmd.edit.err_color", "Цвет вида #RRGGBB") };
        }
        if (kind === "time") {
            if (s.trim() === "") return { clear: true };
            return /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/.test(s.trim()) ? { value: s.trim() } : { error: t("cmd.edit.err_time", "Время вида ЧЧ:ММ") };
        }
        if (kind === "comment_title" || kind === "comment_text") return { value: s };
        return s === "" ? { clear: true } : { value: s };
    }
    function commit(s) {
        const r = convert(s);
        if (r.error) { error = r.error; return; }
        shown = false;
        committed(r.value, !!r.clear);
    }
    function pickChoice(v) { shown = false; committed(v, false); }

    CT { x: 14; y: 10; width: parent.width - 28; size: 12; font.bold: true; text: ve.label }
    CT { x: 14; y: 30; width: parent.width - 28; size: 10; c: ThemeBackend.subtext0; text: ve.typeLabel }

    Rectangle {
        visible: ve.kind !== "list" && ve.kind !== "comment_text" && ve.kind !== "choice"
        x: 12; y: 52; width: parent.width - 24; height: 36; radius: 9; color: ThemeBackend.surface0
        border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.14)
        Rectangle { visible: ve.kind === "color"; x: parent.width - 30; y: 8; width: 20; height: 20; radius: 10
                    color: /^#[0-9a-fA-F]{6}$/.test(single.text) ? single.text : "transparent"; border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.3) }
        TextInput {
            id: single
            x: 10; y: 0; width: parent.width - (ve.kind === "color" ? 50 : 20); height: parent.height
            verticalAlignment: TextInput.AlignVCenter
            color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(12)
            clip: true
            onTextChanged: ve.error = ""
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { ve.commit(text); e.accepted = true; }
                else if (e.key === Qt.Key_Escape) { ve.shown = false; ve.cancelled(); e.accepted = true; }
            }
        }
    }
    Rectangle {
        visible: ve.kind === "list" || ve.kind === "comment_text"
        x: 12; y: 52; width: parent.width - 24; height: parent.height - 52 - 38; radius: 9; color: ThemeBackend.surface0
        border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.14)
        Flickable {
            anchors.fill: parent; anchors.margins: 8
            contentWidth: width; contentHeight: multi.implicitHeight
            clip: true
            TextEdit {
                id: multi
                width: parent.width
                color: ThemeBackend.text; selectionColor: ThemeBackend.mauve
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.cmdFont(12)
                wrapMode: TextEdit.Wrap
                onTextChanged: ve.error = ""
                Keys.onPressed: (e) => {
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) { ve.commit(text); e.accepted = true; }
                    else if (e.key === Qt.Key_Escape) { ve.shown = false; ve.cancelled(); e.accepted = true; }
                }
            }
        }
    }
    Column {
        visible: ve.kind === "choice"
        x: 12; y: 52; width: parent.width - 24; spacing: 4
        Repeater {
            model: ve.choices
            delegate: Rectangle {
                width: parent.width; height: 30; radius: 8; color: cma.containsMouse ? ThemeBackend.surface1 : ThemeBackend.surface0
                CT { x: 12; y: 7; text: ve.choiceLabels[modelData] !== undefined ? ve.choiceLabels[modelData] : String(modelData); size: 12 }
                MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ve.pickChoice(modelData) }
            }
        }
    }
    CT { visible: ve.error !== ""; x: 14; y: parent.height - 44; width: parent.width - 28; size: 10; c: "#f38ba8"; text: ve.error }
    CT {
        visible: ve.kind !== "choice"
        x: 14; y: parent.height - 24; width: parent.width - 28; size: 10; c: ThemeBackend.subtext0
        text: ve.kind === "list" || ve.kind === "comment_text" ? ve.t("cmd.edit.hint_multi", "Ctrl+Enter — сохранить · Esc — отмена") : ve.t("cmd.edit.hint", "Enter — сохранить · Esc — отмена")
    }
}
