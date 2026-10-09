import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// "New hotkey" flow: 1) what to do  2) pick the target  3) press the combination.
ColumnLayout {
    id: root
    objectName: "xAddPanel"

    signal closed()
    spacing: Scaler.s(6)

    // ---- draft ------------------------------------------------------------------
    property string type: "app"                // app | command | run | shell | window  (run is stored as a "command" entry)
    property string runName: ""
    property string appId: ""
    property string command: ""
    property string shellKey: ""
    property string windowKey: ""
    property string name: ""
    property bool nameTouched: false

    function autoName() {
        if (nameTouched) return;
        let n = "";
        if (type === "app") { let a = XHotkeys.appById(appId); n = a ? a.name : ""; }
        else if (type === "shell") { let sa = XHotkeys.shellActions.find(x => x.k === shellKey); n = sa ? XHotkeys.t("hotkeys.builtin." + sa.k, undefined, "") : ""; }
        else if (type === "window") { let wa = XHotkeys.windowActions.find(x => x.k === windowKey); n = wa ? XHotkeys.labelFor(wa.kind, wa.args) : ""; }
        else if (type === "command") n = command.trim();
        else if (type === "run") n = runName !== "" ? XHotkeys.t("hotkeys.add.run_name", { name: runName }, "Run: " + runName) : "";
        name = n;
    }
    onTypeChanged: autoName()
    onAppIdChanged: autoName()
    onRunNameChanged: autoName()
    onShellKeyChanged: autoName()
    onWindowKeyChanged: autoName()

    readonly property bool targetValid: type === "app" ? appId !== "" : type === "command" ? command.trim() !== "" : type === "run" ? runName !== "" : type === "shell" ? shellKey !== "" : windowKey !== ""
    readonly property bool canAdd: targetValid && combo.hasCombo && !combo.conflictOpen

    function add() {
        if (!canAdd) return;
        if (combo.replaceRef !== "") XHotkeys.disableRow(combo.replaceRef);
        let entry = { id: XHotkeys.newId("hk_"), mods: combo.mods, key: combo.key, type: type === "run" ? "command" : type, enabled: true, locked: false, repeating: false, desktopId: "" };
        if (type === "app") {
            let a = XHotkeys.appById(appId);
            entry.command = a ? a.exec : "";
            entry.desktopId = appId;
        } else if (type === "command") {
            entry.command = command.trim();
        } else if (type === "run") {
            entry.command = XHotkeys.runCommandLine(runName);
        } else if (type === "shell") {
            let sa = XHotkeys.shellActions.find(x => x.k === shellKey);
            entry.command = sa.c;
            entry.locked = !!sa.locked;
            entry.repeating = !!sa.repeating;
        } else {
            let wa = XHotkeys.windowActions.find(x => x.k === windowKey);
            entry.kind = wa.kind;
            entry.args = wa.args;
            entry.command = "";
        }
        entry.name = name.trim() !== "" ? name.trim() : (entry.kind ? XHotkeys.labelFor(entry.kind, entry.args) : XHotkeys.labelFor("exec_cmd", [entry.command]));
        XHotkeys.saveCustom(entry);
        closed();
    }

    // ---- pieces ---------------------------------------------------------------------
    component StepHeader: RowLayout {
        property int step: 1
        property string title: ""
        spacing: Scaler.s(8)
        Rectangle {
            implicitWidth: Scaler.s(20)
            implicitHeight: Scaler.s(20)
            radius: Scaler.s(10)
            color: ThemeBackend.mauve
            Text {
                anchors.centerIn: parent
                text: step
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fCaption
                font.bold: true
                color: ThemeBackend.crust
            }
        }
        Text {
            text: title
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fRow
            font.bold: true
            color: ThemeBackend.text
        }
    }

    component Pill: Rectangle {
        id: pill
        property string label: ""
        property string icon: ""
        property bool on: false
        signal tapped()
        implicitWidth: pr.implicitWidth + Scaler.s(28)
        implicitHeight: Scaler.s(34)
        radius: ThemeBackend.borderRadius
        color: on ? ThemeBackend.mauve : (ph.hovered ? Qt.alpha(ThemeBackend.surface1, 0.7) : Qt.alpha(ThemeBackend.surface0, 0.7))
        Behavior on color { ColorAnimation { duration: 140 } }
        RowLayout {
            id: pr
            anchors.centerIn: parent
            spacing: Scaler.s(8)
            Text {
                visible: pill.icon !== ""
                text: pill.icon
                font.family: ThemeBackend.iconFont
                font.pixelSize: XUi.fRow
                color: pill.on ? ThemeBackend.crust : ThemeBackend.text
            }
            Text {
                text: pill.label
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fBody
                font.bold: true
                color: pill.on ? ThemeBackend.crust : ThemeBackend.text
            }
        }
        HoverHandler { id: ph; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: pill.tapped() }
    }

    // ---- header ---------------------------------------------------------------------
    SettingsRow {
        Layout.fillWidth: true
        searchable: false
        icon: "󰐕"
        title: XHotkeys.t("hotkeys.add.title", undefined, "New hotkey")
        description: XHotkeys.t("hotkeys.add.desc", undefined, "Choose what to run, then press the keys")

        IconButton {
            Layout.alignment: Qt.AlignVCenter
            size: Scaler.s(32)
            Layout.preferredWidth: Scaler.s(32)
            Layout.preferredHeight: Scaler.s(32)
            cornerRadius: ThemeBackend.borderRadius
            buttonIcon: "󰅖"
            iconFontSize: XUi.fSub
            accentColor: ThemeBackend.surface1
            textColor: ThemeBackend.text
            onClicked: root.closed()
        }
    }

    // ---- body -----------------------------------------------------------------------
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: body.implicitHeight + Scaler.s(28)
        radius: ThemeBackend.borderRadius
        color: Qt.alpha(ThemeBackend.surface0, 0.4)

        ColumnLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Scaler.s(14)
            spacing: Scaler.s(10)

            StepHeader { step: 1; title: XHotkeys.t("hotkeys.add.step1", undefined, "What to do") }
            Flow {
                Layout.fillWidth: true
                spacing: Scaler.s(8)
                Pill { label: XHotkeys.t("hotkeys.type.app", undefined, "Launch app");  icon: "󰀻"; on: root.type === "app";     onTapped: root.type = "app" }
                Pill { label: XHotkeys.t("hotkeys.type.command", undefined, "Command"); icon: "󰆍"; on: root.type === "command"; onTapped: root.type = "command" }
                Pill { label: XHotkeys.t("hotkeys.type.run", undefined, "Run a command…"); icon: "󰐊"; on: root.type === "run"; onTapped: root.type = "run" }
                Pill { label: XHotkeys.t("hotkeys.type.shell", undefined, "Shell action"); icon: "󱓞"; on: root.type === "shell"; onTapped: root.type = "shell" }
                Pill { label: XHotkeys.t("hotkeys.type.window", undefined, "Window / workspace"); icon: "󰖲"; on: root.type === "window"; onTapped: root.type = "window" }
            }

            StepHeader {
                step: 2
                title: root.type === "app" ? XHotkeys.t("hotkeys.add.step2_app", undefined, "Pick an app")
                     : root.type === "command" ? XHotkeys.t("hotkeys.add.step2_command", undefined, "Enter the command")
                     : root.type === "run" ? XHotkeys.t("hotkeys.add.step2_run", undefined, "Pick a Commands command")
                     : XHotkeys.t("hotkeys.add.step2_action", undefined, "Pick an action")
            }

            AppPicker {
                Layout.fillWidth: true
                visible: root.type === "app"
                selectedId: root.appId
                onPicked: function(id) { root.appId = id; }
            }
            CmdPicker {
                Layout.fillWidth: true
                visible: root.type === "run"
                selectedName: root.runName
                onPicked: function(n) { root.runName = n; }
            }
            Input {
                Layout.fillWidth: true
                implicitHeight: Scaler.s(36)
                visible: root.type === "command"
                text: root.command
                leadingIcon: "󰆍"
                placeholderText: "kitty -e btop"
                baseColor: ThemeBackend.surface0
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.text
                subTextColor: ThemeBackend.subtext0
                borderColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                cornerRadius: ThemeBackend.borderRadius
                fontPixelSize: XUi.fBody
                onTextEdited: function(t) { root.command = t; root.autoName(); }
            }
            Flow {
                Layout.fillWidth: true
                visible: root.type === "shell"
                spacing: Scaler.s(8)
                Repeater {
                    model: XHotkeys.shellActions
                    delegate: Pill {
                        required property var modelData
                        label: XHotkeys.t("hotkeys.builtin." + modelData.k, undefined, modelData.c)
                        on: root.shellKey === modelData.k
                        onTapped: root.shellKey = modelData.k
                    }
                }
            }
            Flow {
                Layout.fillWidth: true
                visible: root.type === "window"
                spacing: Scaler.s(8)
                Repeater {
                    model: XHotkeys.windowActions
                    delegate: Pill {
                        required property var modelData
                        label: XHotkeys.labelFor(modelData.kind, modelData.args)
                        on: root.windowKey === modelData.k
                        onTapped: root.windowKey = modelData.k
                    }
                }
            }

            StepHeader { step: 3; title: XHotkeys.t("hotkeys.add.step3", undefined, "Press the combination") }
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(14)

                ComboField {
                    id: combo
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    selfRef: ""
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.alignment: Qt.AlignTop
                    spacing: Scaler.s(6)
                    Text {
                        text: XHotkeys.t("hotkeys.editor.name", undefined, "Name")
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: XUi.fCaption
                        font.bold: true
                        color: ThemeBackend.text
                    }
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
                        onTextEdited: function(t) { root.name = t; root.nameTouched = true; }
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
                    enabled: root.canAdd
                    opacity: root.canAdd ? 1.0 : 0.45
                    buttonText: XHotkeys.t("hotkeys.add.confirm", undefined, "Add")
                    buttonIcon: "󰐕"
                    textFontSize: XUi.fBody
                    iconFontSize: XUi.fSub
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.crust
                    onTriggered: root.add()
                }
            }
        }
    }

    Component.onCompleted: {
        shellKey = XHotkeys.shellActions[0].k;
        windowKey = XHotkeys.windowActions[0].k;
    }
}
