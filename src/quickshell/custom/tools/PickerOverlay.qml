import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../"
import ".."
import "ColorUtil.js" as ColorUtil

// Screen eyedropper window. start(): freeze the screen under the cursor (grim), then show PickerView
// full-screen above everything. LMB copies the colour (format from settings, Shift = the other one),
// Esc / RMB cancels, H opens the history.
PanelWindow {
    id: root

    property bool active: false
    property var targetScreen: null
    property string frozenUrl: ""

    signal picked(string text, string hexValue)
    signal historyRequested()

    function toggle() { active ? close() : start(); }

    function start() { XLog.info("tools", "UI: colour picker started");
        if (active || grimProc.running) return;
        targetScreen = Quickshell.cursorScreen ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null);
        if (!targetScreen) return;
        view.imageReady = false;
        grimProc.target = Caching.getRunDir("xtools") + "/picker-" + Date.now() + ".png";
        grimProc.running = true;
    }

    function close() {
        active = false;
        view.imageReady = false;
        if (grimProc.target !== "") Quickshell.execDetached(["rm", "-f", grimProc.target]);
        frozenUrl = "";
    }

    function copyColor(useAlt) { XLog.info("tools", "UI: colour copied alt=" + !!useAlt);
        let kind = XToolsConf.picker.format;
        let k = useAlt ? ColorUtil.altKind(kind) : kind;
        let hex = view.hex;
        let text = ColorUtil.format(hex, k);
        if (XToolsConf.picker.history) Quickshell.execDetached(["bash", XToolsConf.scriptsDir + "/x_colors.sh", "copy", hex, k]);
        else Quickshell.execDetached(["wl-copy", text]);
        root.picked(text, hex);
        close();
    }

    Process {
        id: grimProc
        property string target: ""
        command: ["grim", "-o", root.targetScreen ? root.targetScreen.name : "", "-l", "0", target]
        onExited: (code) => {
            if (code === 0) { root.frozenUrl = "file://" + target; root.active = true; }
            else XLog.error("tools", "colour picker could not capture the screen (grim exit " + code + ")");
        }
    }

    screen: targetScreen
    color: "transparent"
    visible: active
    WlrLayershell.namespace: "qs-x-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    focusable: active
    anchors { top: true; bottom: true; left: true; right: true }

    PickerView {
        id: view
        anchors.fill: parent
        frozenUrl: root.frozenUrl
        kind: XToolsConf.picker.format
        onCloseRequested: root.close()
        onCopyRequested: (alt) => root.copyColor(alt)
        onHistoryRequested: { root.close(); root.historyRequested(); }
    }
}
