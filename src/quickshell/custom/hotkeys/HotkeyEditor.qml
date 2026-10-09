import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// Inline editor of one existing hotkey (custom or shipped). Lives in the row's bottom area.
ColumnLayout {
    id: root
    objectName: "xEditor"

    required property var row                 // XHotkeys row
    signal closed()

    readonly property bool isShipped: row.source === "shipped"
    spacing: Scaler.s(10)
    readonly property alias combo: combo

    // ---- draft ------------------------------------------------------------------
    property string type: "command"            // app | command | shell | window | fixed
    property string appId: ""
    property string command: ""
    property string shellKey: ""
    property string windowKey: ""
    property string name: ""

    function detectTypeOf(r) {
        if (r.source === "custom" && r.custom) {
            let ty = r.custom.type;
            if (ty === "builtin") ty = "shell";
            if (ty === "app" || ty === "command" || ty === "shell" || ty === "window") {
                if (!(ty === "window" && !XHotkeys.windowActionFor(r.kind, r.args))) return ty;
            }
        }
        if (r.kind === "exec_cmd") {
            let cmd = r.args && r.args.length > 0 ? String(r.args[0]) : "";
            if (XHotkeys.shellActionByCommand(cmd)) return "shell";
            if (XHotkeys.appByCommand(cmd)) return "app";
            return "command";
        }
        return XHotkeys.windowActionFor(r.kind, r.args) ? "window" : "fixed";
    }

    function loadDraft() { loadDraftFrom(row); defaultSig = ""; }

    function draftSig() {
        return JSON.stringify([type, appId, command, shellKey, windowKey, name.trim(), combo.mods, combo.key]);
    }
    property string defaultSig: ""

    // "Reset to default" only fills the draft (so a conflict on the original combo is visible
    // and resolvable); Save then removes the override.
    function resetDraft() {
        let b = row.bind;
        loadDraftFrom({
            source: "shipped", kind: b.kind, args: b.args || [], label: XHotkeys.labelFor(b.kind, b.args),
            mods: row.origMods, key: row.origKey, locked: row.locked, bind: b, custom: null
        });
        combo.replaceRef = "";
        defaultSig = draftSig();
    }

    function loadDraftFrom(r) {
        type = detectTypeOf(r);
        name = r.label;
        let cmd = (r.kind === "exec_cmd" && r.args && r.args.length > 0) ? String(r.args[0]) : "";
        command = cmd;
        let app = r.source === "custom" && r.custom && r.custom.desktopId ? XHotkeys.appById(r.custom.desktopId) : XHotkeys.appByCommand(cmd);
        appId = app ? app.id : "";
        let sa = XHotkeys.shellActionByCommand(cmd);
        shellKey = sa ? sa.k : XHotkeys.shellActions[0].k;
        let wa = XHotkeys.windowActionFor(r.kind, r.args);
        windowKey = wa ? wa.k : XHotkeys.windowActions[0].k;
        combo.mods = r.mods.slice();
        combo.key = r.key;
    }
    Component.onCompleted: loadDraft()

    // ---- action → what gets stored -------------------------------------------------
    function actionSpec() {
        if (type === "app") {
            let app = XHotkeys.appById(appId);
            let c = app ? app.exec : "";
            return { type: "app", kind: "exec_cmd", args: [c], command: c, desktopId: appId, locked: false, repeating: false };
        }
        if (type === "command")
            return { type: "command", kind: "exec_cmd", args: [command], command: command, desktopId: "", locked: false, repeating: false };
        if (type === "shell") {
            let sa = XHotkeys.shellActions.find(a => a.k === shellKey);
            return { type: "shell", kind: "exec_cmd", args: [sa.c], command: sa.c, desktopId: "", locked: !!sa.locked, repeating: !!sa.repeating };
        }
        if (type === "window") {
            let wa = XHotkeys.windowActions.find(a => a.k === windowKey);
            return { type: "window", kind: wa.kind, args: wa.args, command: "", desktopId: "", locked: false, repeating: false };
        }
        return { type: "fixed", kind: row.kind, args: row.args, command: "", desktopId: "", locked: row.locked, repeating: false };
    }

    readonly property bool actionValid: type === "app" ? appId !== "" : type === "command" ? command.trim() !== "" : true
    readonly property bool canSave: combo.hasCombo && !combo.conflictOpen && actionValid

    // Everything is computed first and the editor is closed BEFORE anything is written:
    // a write rebuilds the hotkey list, which destroys this editor (and its context).
    function save() {
        if (!canSave) return;
        let replace = combo.replaceRef;
        let bind = row.bind;
        let wasShipped = isShipped;
        let isDefault = wasShipped && defaultSig !== "" && draftSig() === defaultSig;
        let a = actionSpec();
        let nm = name.trim() !== "" ? name.trim() : XHotkeys.labelFor(a.kind, a.args);
        let mods = combo.mods.slice();
        let key = combo.key;
        let isFixed = type === "fixed";
        let entry = null;
        if (!wasShipped) {
            entry = Object.assign({}, row.custom, { name: nm, mods: mods, key: key, type: a.type, command: a.command, desktopId: a.desktopId, enabled: true });
            if (a.type === "window") { entry.kind = a.kind; entry.args = a.args; }
            else { delete entry.kind; delete entry.args; }
            if (a.type === "shell") { entry.locked = a.locked; entry.repeating = a.repeating; }
        }

        closed();

        if (replace !== "") XHotkeys.disableRow(replace);
        if (isDefault) {
            XHotkeys.resetOverride(bind);
        } else if (wasShipped) {
            let spec = { mods: mods, key: key, name: nm };
            if (!isFixed) { spec.kind = a.kind; spec.args = a.args; }
            XHotkeys.saveOverride(bind, spec, false);
        } else {
            XHotkeys.saveCustom(entry);
        }
    }

    // ---- UI -----------------------------------------------------------------------
    readonly property var typeKeys: ["app", "command", "shell", "window"]
    readonly property var typeLabels: [
        XHotkeys.t("hotkeys.type.app", undefined, "Launch app"),
        XHotkeys.t("hotkeys.type.command", undefined, "Command"),
        XHotkeys.t("hotkeys.type.shell", undefined, "Shell action"),
        XHotkeys.t("hotkeys.type.window", undefined, "Window / workspace")
    ]

    component FieldLabel: Text {
        font.family: ThemeBackend.fontFamily
        font.pixelSize: XUi.fCaption
        font.bold: true
        color: ThemeBackend.text
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Scaler.s(14)

        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            spacing: Scaler.s(6)

            FieldLabel { text: XHotkeys.t("hotkeys.editor.action", undefined, "Action") }
            Dropdown {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                enabled: root.type !== "fixed"
                options: root.type === "fixed" ? [XHotkeys.t("hotkeys.type.system", undefined, "System action")] : root.typeLabels
                currentIndex: root.type === "fixed" ? 0 : Math.max(0, root.typeKeys.indexOf(root.type))
                accentColor: ThemeBackend.mauve
                baseColor: ThemeBackend.surface0
                hoverColor: ThemeBackend.surface1
                dropdownColor: ThemeBackend.surface0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                textColor: ThemeBackend.text
                activeTextColor: ThemeBackend.crust
                fontPixelSize: XUi.fBody
                onValueChanged: function(index, value) { if (root.type !== "fixed") root.type = root.typeKeys[index]; }
            }

            // target of the action
            FieldLabel {
                text: root.type === "app" ? XHotkeys.t("hotkeys.editor.program", undefined, "Program")
                    : root.type === "command" ? XHotkeys.t("hotkeys.editor.command", undefined, "Command")
                    : root.type === "shell" ? XHotkeys.t("hotkeys.editor.shell_action", undefined, "Shell action")
                    : root.type === "window" ? XHotkeys.t("hotkeys.editor.window_action", undefined, "Action")
                    : XHotkeys.t("hotkeys.editor.what", undefined, "Does")
            }
            Dropdown {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                visible: root.type === "app"
                options: XHotkeys.apps.map(a => a.name)
                currentIndex: Math.max(0, XHotkeys.apps.findIndex(a => a.id === root.appId))
                placeholderText: XHotkeys.t("hotkeys.editor.pick_app", undefined, "Pick an app")
                accentColor: ThemeBackend.mauve
                baseColor: ThemeBackend.surface0
                hoverColor: ThemeBackend.surface1
                dropdownColor: ThemeBackend.surface0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                textColor: ThemeBackend.text
                activeTextColor: ThemeBackend.crust
                fontPixelSize: XUi.fBody
                onValueChanged: function(index, value) { if (index >= 0 && index < XHotkeys.apps.length) root.appId = XHotkeys.apps[index].id; }
            }
            Input {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                visible: root.type === "command"
                text: root.command
                placeholderText: "kitty -e btop"
                baseColor: ThemeBackend.surface0
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.text
                subTextColor: ThemeBackend.subtext0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                cornerRadius: ThemeBackend.borderRadius
                fontPixelSize: XUi.fBody
                onTextEdited: function(t) { root.command = t; }
            }
            Dropdown {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                visible: root.type === "shell"
                options: XHotkeys.shellActions.map(a => XHotkeys.t("hotkeys.builtin." + a.k, undefined, a.c))
                currentIndex: Math.max(0, XHotkeys.shellActions.findIndex(a => a.k === root.shellKey))
                accentColor: ThemeBackend.mauve
                baseColor: ThemeBackend.surface0
                hoverColor: ThemeBackend.surface1
                dropdownColor: ThemeBackend.surface0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                textColor: ThemeBackend.text
                activeTextColor: ThemeBackend.crust
                fontPixelSize: XUi.fBody
                onValueChanged: function(index, value) { if (index >= 0) root.shellKey = XHotkeys.shellActions[index].k; }
            }
            Dropdown {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                visible: root.type === "window"
                options: XHotkeys.windowActions.map(a => XHotkeys.labelFor(a.kind, a.args))
                currentIndex: Math.max(0, XHotkeys.windowActions.findIndex(a => a.k === root.windowKey))
                accentColor: ThemeBackend.mauve
                baseColor: ThemeBackend.surface0
                hoverColor: ThemeBackend.surface1
                dropdownColor: ThemeBackend.surface0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                textColor: ThemeBackend.text
                activeTextColor: ThemeBackend.crust
                fontPixelSize: XUi.fBody
                onValueChanged: function(index, value) { if (index >= 0) root.windowKey = XHotkeys.windowActions[index].k; }
            }
            Text {
                visible: root.type === "fixed"
                Layout.fillWidth: true
                text: root.row.label
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fBody
                color: ThemeBackend.subtext0
                wrapMode: Text.WordWrap
            }

            FieldLabel { text: XHotkeys.t("hotkeys.editor.name", undefined, "Name") }
            Input {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(34)
                text: root.name
                placeholderText: XHotkeys.t("hotkeys.editor.name_placeholder", undefined, "Name")
                baseColor: ThemeBackend.surface0
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.text
                subTextColor: ThemeBackend.subtext0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                cornerRadius: ThemeBackend.borderRadius
                fontPixelSize: XUi.fBody
                onTextEdited: function(t) { root.name = t; }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            spacing: Scaler.s(6)

            FieldLabel { text: XHotkeys.t("hotkeys.editor.combo", undefined, "Combination") }
            ComboField {
                id: combo
                Layout.fillWidth: true
                selfRef: root.row.ref
            }
        }
    }

    ConflictCard {
        visible: combo.conflictOpen
        conflict: combo.conflict
        onReplace: combo.replaceRef = combo.conflict ? combo.conflict.ref : ""
        onChooseOther: combo.chooseOther()
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Scaler.s(8)

        ClickButton {
            visible: root.isShipped && root.row.changed
            Layout.preferredHeight: Scaler.s(34)
            horizontalPadding: Scaler.s(14)
            cornerRadius: ThemeBackend.borderRadius
            buttonText: root.row.bind ? XHotkeys.t("hotkeys.editor.reset", { name: XHotkeys.labelFor(root.row.bind.kind, root.row.bind.args), combo: XHotkeys.comboText(root.row.origMods, root.row.origKey) }, "Reset to default") : ""
            buttonIcon: "󰁯"
            textFontSize: XUi.fBody
            iconFontSize: XUi.fSub
            accentColor: ThemeBackend.surface0
            textColor: ThemeBackend.text
            maxTextWidth: Scaler.s(300)
            onTriggered: root.resetDraft()
        }
        ClickButton {
            visible: !root.isShipped
            Layout.preferredHeight: Scaler.s(34)
            horizontalPadding: Scaler.s(14)
            cornerRadius: ThemeBackend.borderRadius
            buttonText: XHotkeys.t("hotkeys.editor.delete", undefined, "Delete")
            buttonIcon: "󰆴"
            textFontSize: XUi.fBody
            iconFontSize: XUi.fSub
            accentColor: Qt.alpha(ThemeBackend.red, 0.18)
            textColor: ThemeBackend.red
            onTriggered: { XHotkeys.deleteCustom(root.row.custom.id); root.closed(); }
        }

        Item { Layout.fillWidth: true }

        ClickButton {
            Layout.preferredHeight: Scaler.s(34)
            horizontalPadding: Scaler.s(18)
            cornerRadius: ThemeBackend.borderRadius
            buttonText: XHotkeys.t("hotkeys.editor.cancel", undefined, "Cancel")
            textFontSize: XUi.fBody
            accentColor: ThemeBackend.surface0
            textColor: ThemeBackend.text
            onTriggered: root.closed()
        }
        ClickButton {
            Layout.preferredHeight: Scaler.s(34)
            horizontalPadding: Scaler.s(18)
            cornerRadius: ThemeBackend.borderRadius
            enabled: root.canSave
            opacity: root.canSave ? 1.0 : 0.45
            buttonText: XHotkeys.t("hotkeys.editor.save", undefined, "Save")
            buttonIcon: "󰄬"
            textFontSize: XUi.fBody
            iconFontSize: XUi.fSub
            accentColor: ThemeBackend.mauve
            textColor: ThemeBackend.crust
            onTriggered: root.save()
        }
    }
}
