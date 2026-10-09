import QtQuick
import QtQuick.Layouts
import "../../"
import ".."

// Captures a keyboard combination. Click it, press a combo, get captured(mods, key).
//
//  * Every key is swallowed while capturing (Keys.onPressed + Keys.onShortcutOverride), so the
//    shell guide's own shortcuts (Ctrl+F search, Escape-to-close ...) never fire.
//  * Layout independent: the physical key (evdev scan code) is mapped to the US keysym, so a
//    Russian layout still produces "F", not "а".
//  * Esc cancels, Backspace (no modifiers) clears.
//  * `extraMods` lets the parent add modifiers by click (the compositor eats combos that are
//    already bound, e.g. SUPER+Q would close the window instead of reaching us).
Item {
    id: root

    property var mods: []
    property string key: ""
    property var extraMods: []
    property bool capturing: false
    property bool hasError: false
    property string statusText: ""            // line under the chips while idle
    property color statusColor: ThemeBackend.subtext0
    property string hintText: ""              // line under the chips while capturing
    property string placeholderText: ""

    property var heldMods: []                 // modifiers physically held right now
    readonly property var liveMods: XHotkeys.modOrder.filter(m => heldMods.indexOf(m) !== -1 || extraMods.indexOf(m) !== -1)

    signal captured(var mods, string key)
    signal cancelled()
    signal cleared()

    implicitHeight: Scaler.s(74)
    implicitWidth: Scaler.s(300)
    activeFocusOnTab: true

    function beginCapture() {
        capturing = true;
        heldMods = [];
        forceActiveFocus();
        popAnim.restart();
    }
    function stopCapture() {
        capturing = false;
        heldMods = [];
    }

    onActiveFocusChanged: if (!activeFocus && capturing) stopCapture()

    readonly property var bareMods: [
        Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R,
        Qt.Key_Hyper_L, Qt.Key_Hyper_R, Qt.Key_CapsLock, Qt.Key_NumLock, Qt.Key_ScrollLock, Qt.Key_Mode_switch
    ]

    // evdev code -> US keysym name (xkb keycode = evdev + 8)
    readonly property var scanMap: ({
        2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
        12: "minus", 13: "equal",
        16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y", 22: "U", 23: "I", 24: "O", 25: "P",
        26: "bracketleft", 27: "bracketright",
        30: "A", 31: "S", 32: "D", 33: "F", 34: "G", 35: "H", 36: "J", 37: "K", 38: "L",
        39: "semicolon", 40: "apostrophe", 41: "grave", 43: "backslash",
        44: "Z", 45: "X", 46: "C", 47: "V", 48: "B", 49: "N", 50: "M",
        51: "comma", 52: "period", 53: "slash"
    })

    function modOfKey(k) {
        if (k === Qt.Key_Meta || k === Qt.Key_Super_L || k === Qt.Key_Super_R) return "SUPER";
        if (k === Qt.Key_Control) return "CTRL";
        if (k === Qt.Key_Alt || k === Qt.Key_AltGr) return "ALT";
        if (k === Qt.Key_Shift) return "SHIFT";
        return "";
    }

    function modsOf(event) {
        let m = [];
        if (event.modifiers & Qt.MetaModifier) m.push("SUPER");
        if (event.modifiers & Qt.ControlModifier) m.push("CTRL");
        if (event.modifiers & Qt.AltModifier) m.push("ALT");
        if (event.modifiers & Qt.ShiftModifier) m.push("SHIFT");
        return m;
    }

    function keysymFor(event) {
        let k = event.key;
        let code = event.nativeScanCode > 8 ? event.nativeScanCode - 8 : 0;
        if (code > 0 && scanMap[code] !== undefined) return scanMap[code];

        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k);
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k);
        if (k >= Qt.Key_F1 && k <= Qt.Key_F35) return "F" + (k - Qt.Key_F1 + 1);
        switch (k) {
            case Qt.Key_Space: return "space";
            case Qt.Key_Return: return "Return";
            case Qt.Key_Enter: return "KP_Enter";
            case Qt.Key_Tab: return "Tab";
            case Qt.Key_Backtab: return "ISO_Left_Tab";
            case Qt.Key_Backspace: return "BackSpace";
            case Qt.Key_Delete: return "Delete";
            case Qt.Key_Insert: return "Insert";
            case Qt.Key_Home: return "Home";
            case Qt.Key_End: return "End";
            case Qt.Key_PageUp: return "Prior";
            case Qt.Key_PageDown: return "Next";
            case Qt.Key_Left: return "Left";
            case Qt.Key_Right: return "Right";
            case Qt.Key_Up: return "Up";
            case Qt.Key_Down: return "Down";
            case Qt.Key_Print: return "Print";
            case Qt.Key_Pause: return "Pause";
            case Qt.Key_Menu: return "Menu";
            case Qt.Key_Minus: return "minus";
            case Qt.Key_Equal: return "equal";
            case Qt.Key_BracketLeft: return "bracketleft";
            case Qt.Key_BracketRight: return "bracketright";
            case Qt.Key_Backslash: return "backslash";
            case Qt.Key_Semicolon: return "semicolon";
            case Qt.Key_Apostrophe: return "apostrophe";
            case Qt.Key_Comma: return "comma";
            case Qt.Key_Period: return "period";
            case Qt.Key_Slash: return "slash";
            case Qt.Key_QuoteLeft: return "grave";
            case Qt.Key_VolumeUp: return "XF86AudioRaiseVolume";
            case Qt.Key_VolumeDown: return "XF86AudioLowerVolume";
            case Qt.Key_VolumeMute: return "XF86AudioMute";
            case Qt.Key_MicMute: return "XF86AudioMicMute";
            case Qt.Key_MediaPlay: return "XF86AudioPlay";
            case Qt.Key_MediaPause: return "XF86AudioPause";
            case Qt.Key_MediaNext: return "XF86AudioNext";
            case Qt.Key_MediaPrevious: return "XF86AudioPrev";
            case Qt.Key_MonBrightnessUp: return "XF86MonBrightnessUp";
            case Qt.Key_MonBrightnessDown: return "XF86MonBrightnessDown";
        }
        return "";
    }

    Keys.onShortcutOverride: function(event) {
        if (root.capturing) event.accepted = true;
    }

    Keys.onReleased: function(event) {
        if (!root.capturing) return;
        event.accepted = true;
        let own = root.modOfKey(event.key);
        root.heldMods = root.modsOf(event).filter(m => m !== own);
    }

    Keys.onPressed: function(event) {
        if (!root.capturing) return;
        event.accepted = true;
        if (event.isAutoRepeat) return;

        if (root.bareMods.indexOf(event.key) !== -1) {
            let own = root.modOfKey(event.key);
            let held = root.modsOf(event);
            if (own !== "" && held.indexOf(own) === -1) held.push(own);
            root.heldMods = held;
            return;
        }

        let physical = root.modsOf(event);
        if (event.key === Qt.Key_Escape && physical.length === 0 && root.extraMods.length === 0) {
            root.stopCapture();
            root.cancelled();
            return;
        }
        if (event.key === Qt.Key_Backspace && physical.length === 0 && root.extraMods.length === 0) {
            root.stopCapture();
            root.mods = [];
            root.key = "";
            root.cleared();
            return;
        }

        let k = root.keysymFor(event);
        if (k === "") {
            shakeAnim.restart();
            return;
        }
        let all = XHotkeys.modOrder.filter(m => physical.indexOf(m) !== -1 || root.extraMods.indexOf(m) !== -1);
        root.stopCapture();
        root.mods = all;
        root.key = k;
        root.captured(all, k);
    }

    property real pop: 1.0
    SequentialAnimation {
        id: popAnim
        NumberAnimation { target: root; property: "pop"; to: 1.015; duration: 110; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "pop"; to: 1.0; duration: 320; easing.type: Easing.OutQuint }
    }
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: shakeT; property: "x"; to: -6; duration: 50 }
        NumberAnimation { target: shakeT; property: "x"; to: 6; duration: 50 }
        NumberAnimation { target: shakeT; property: "x"; to: -4; duration: 50 }
        NumberAnimation { target: shakeT; property: "x"; to: 0; duration: 50 }
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.beginCapture() }

    Rectangle {
        id: box
        anchors.fill: parent
        radius: ThemeBackend.borderRadius
        scale: root.pop
        transform: Translate { id: shakeT; x: 0 }
        color: root.hasError ? Qt.alpha(ThemeBackend.red, 0.10)
             : (root.capturing || hover.hovered) ? Qt.alpha(ThemeBackend.surface0, 0.85) : Qt.alpha(ThemeBackend.surface0, 0.55)
        border.width: root.capturing || root.hasError ? 2 : 1
        border.color: root.hasError ? Qt.alpha(ThemeBackend.red, 0.75)
                    : root.capturing ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.7)
        Behavior on color { ColorAnimation { duration: 160 } }
        Behavior on border.color { ColorAnimation { duration: 160 } }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Scaler.s(8)
        spacing: Scaler.s(6)

        Item { Layout.fillHeight: true }

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: Scaler.s(26)
            Layout.preferredWidth: chipsRow.implicitWidth + (root.capturing ? Scaler.s(14) : 0)

            ComboChips {
                id: chipsRow
                anchors.verticalCenter: parent.verticalCenter
                mods: root.capturing ? root.liveMods : root.mods
                key: root.capturing ? "" : root.key
                accent: root.capturing || root.hasError
                accentColor: root.hasError ? ThemeBackend.red : ThemeBackend.mauve
                showPlaceholder: !root.capturing
                placeholder: root.placeholderText
            }

            Rectangle {
                id: caret
                visible: root.capturing
                anchors.verticalCenter: parent.verticalCenter
                x: chipsRow.implicitWidth + Scaler.s(6)
                width: Scaler.s(2)
                height: Scaler.s(16)
                radius: 1
                color: ThemeBackend.mauve
                SequentialAnimation on opacity {
                    running: root.capturing
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.15; duration: 520 }
                    NumberAnimation { to: 1.0; duration: 520 }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: root.capturing ? root.hintText : root.statusText
            elide: Text.ElideRight
            font.family: ThemeBackend.fontFamily
            font.pixelSize: XUi.fCaption
            color: root.capturing ? ThemeBackend.subtext0 : (root.hasError ? ThemeBackend.red : root.statusColor)
            visible: text !== ""
        }

        Item { Layout.fillHeight: true }
    }
}
