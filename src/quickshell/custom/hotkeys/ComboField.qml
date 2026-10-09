import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// "Combination" field of the editor: capture box + status line + modifier toggles.
// Knows nothing about saving; the editor reads mods/key/conflict/replaceRef.
ColumnLayout {
    id: root
    objectName: "xCombo"

    property string selfRef: ""
    property var mods: []
    property string key: ""
    property string replaceRef: ""        // a conflicting row the user agreed to take over

    readonly property var conflict: root.key !== "" ? XHotkeys.conflictFor(root.selfRef, root.mods, root.key) : null
    readonly property bool conflictOpen: conflict !== null && conflict.ref !== replaceRef
    readonly property bool hasCombo: root.key !== ""
    readonly property alias capturing: capture.capturing
    readonly property alias heldMods: capture.heldMods

    signal changed()

    function beginCapture() { capture.beginCapture(); }
    function stopCapture() { capture.stopCapture(); }
    function chooseOther() { replaceRef = ""; mods = []; key = ""; capture.beginCapture(); changed(); }

    spacing: Scaler.s(8)

    KeyCaptureInput {
        id: capture
        Layout.fillWidth: true
        mods: root.mods
        key: root.key
        extraMods: modRow.selected
        hasError: root.conflictOpen
        placeholderText: XHotkeys.t("hotkeys.combo.placeholder", undefined, "Click and press keys")
        hintText: XHotkeys.t("hotkeys.combo.capture_hint", undefined, "Press the new combination  ·  Esc — cancel  ·  Backspace — clear")
        statusText: root.conflictOpen ? XHotkeys.t("hotkeys.combo.taken", undefined, "This combination is already taken")
                  : (root.conflict ? XHotkeys.t("hotkeys.combo.will_replace", { name: root.conflict.label }, "Will take over from: " + root.conflict.label)
                  : (root.hasCombo ? XHotkeys.t("hotkeys.combo.free", undefined, "Combination is free") : ""))
        statusColor: root.conflict ? ThemeBackend.peach : ThemeBackend.subtext0
        onCaptured: function(m, k) {
            root.replaceRef = "";
            root.mods = m;
            root.key = k;
            modRow.selected = [];
            root.changed();
        }
        onCleared: { root.replaceRef = ""; root.mods = []; root.key = ""; modRow.selected = []; root.changed(); }
    }

    // Modifier toggles (only while capturing): the compositor swallows combinations that are
    // already bound, so they can also be picked by click and finished with a plain key press.
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: Scaler.s(26)

        RowLayout {
            id: modRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Scaler.s(6)
            visible: capture.capturing
            property var selected: []

            Text {
                text: XHotkeys.t("hotkeys.combo.modifiers", undefined, "Modifiers")
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fCaption
                color: ThemeBackend.subtext0
            }
            Repeater {
                model: XHotkeys.modOrder
                delegate: Item {
                    required property string modelData
                    implicitWidth: chip.implicitWidth
                    implicitHeight: chip.implicitHeight
                    KeyChip {
                        id: chip
                        text: modelData
                        accent: modRow.selected.indexOf(modelData) !== -1
                        opacity: tap.hovered ? 0.85 : 1.0
                    }
                    HoverHandler { id: tap; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            let s = modRow.selected.slice();
                            let i = s.indexOf(modelData);
                            if (i === -1) s.push(modelData); else s.splice(i, 1);
                            modRow.selected = s;
                        }
                    }
                }
            }
        }

        RowLayout {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Scaler.s(6)
            visible: !capture.capturing
            Text {
                text: "󰋼"
                font.family: ThemeBackend.iconFont
                font.pixelSize: XUi.fRow
                color: ThemeBackend.overlay1
            }
            Text {
                Layout.fillWidth: true
                text: XHotkeys.t("hotkeys.combo.info", undefined, "Hold the modifiers and press the main key, it is recorded automatically")
                font.family: ThemeBackend.fontFamily
                font.pixelSize: XUi.fCaption
                color: ThemeBackend.subtext0
                elide: Text.ElideRight
            }
        }
    }
}
