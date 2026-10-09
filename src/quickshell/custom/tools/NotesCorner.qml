import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../../"
import ".."

// Quick notes hot corner. A tiny layer-shell hover zone sits in the configured corner of every
// monitor. Hover (showDelay) -> card with the latest note; keep hovering (expandDelay) or click ->
// the full mini editor. Plain markdown files in the notes folder (x_notes.sh), autosave in the editor.
Item {
    id: root

    property string mode: "hidden"              // hidden | card | editor
    property var targetScreen: null
    property var notes: []                      // newest first, from x_notes.sh list
    property string currentPath: ""
    property string notesDir: ""

    readonly property var cfg: XToolsConf.notes
    readonly property string corner: cfg.corner
    readonly property bool atBottom: corner.indexOf("bottom") !== -1
    readonly property bool atRight: corner.indexOf("right") !== -1
    readonly property bool fullscreenActive: {
        try {
            if (typeof Hyprland !== "undefined" && Hyprland.focusedWorkspace)
                return Boolean(Hyprland.focusedWorkspace.hasFullscreen || (Hyprland.activeToplevel && Hyprland.activeToplevel.fullscreen));
        } catch (e) {}
        return false;
    }
    readonly property bool blocked: cfg.noFullscreen && fullscreenActive

    function s(v) { return Scaler.s(v); }
    function scriptPath() { return XToolsConf.scriptsDir + "/x_notes.sh"; }
    function screenOrCursor(scr) { return scr ?? Quickshell.cursorScreen ?? (Quickshell.screens.length > 0 ? Quickshell.screens[0] : null); }

    function refresh() { listProc.running = true; }

    function showCard(scr) {
        if (!cfg.enabled || blocked || mode === "editor") return;
        targetScreen = screenOrCursor(scr);
        refresh();
        mode = "card";
        hideTimer.stop();
    }

    function openEditor(scr, path) { XLog.info("tools", "UI: notes editor opened");
        targetScreen = screenOrCursor(scr ?? targetScreen);
        hideTimer.stop(); expandTimer.stop();
        if (path) currentPath = path;
        else if (notes.length > 0) currentPath = notes[0].path;
        if (currentPath === "") { newNote(); return; }
        mode = "editor";
    }

    function closeAll() { expandTimer.stop(); hideTimer.stop(); mode = "hidden"; refresh(); }

    function toggleEditor() {
        if (mode === "editor") closeAll();
        else openEditor(null, "");
    }

    function newNote() {
        newProc.running = true;
    }

    function cardHovered(inside) {
        if (inside) hideTimer.stop();
        else if (mode === "card") { hideTimer.restart(); expandTimer.stop(); }
    }

    Timer { id: hideTimer; interval: 450; onTriggered: root.mode = "hidden" }
    Timer { id: expandTimer; interval: Math.max(50, root.cfg.expandDelay - root.cfg.showDelay); onTriggered: if (root.mode === "card") root.openEditor(null, "") }
    Timer { id: showTimer; property var pendingScreen: null; interval: root.cfg.showDelay; onTriggered: { root.showCard(pendingScreen); expandTimer.restart(); } }

    Process {
        id: listProc
        command: ["bash", root.scriptPath(), "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { let a = JSON.parse(this.text.trim()); root.notes = Array.isArray(a) ? a : []; }
                catch (e) { XLog.warn("tools", "NotesCorner.qml: could not parse JSON output (a)"); root.notes = []; }
            }
        }
    }
    Process {
        id: newProc
        command: ["bash", root.scriptPath(), "new"]
        stdout: StdioCollector {
            onStreamFinished: {
                let p = this.text.trim();
                if (p !== "") { root.currentPath = p; root.refresh(); root.targetScreen = root.screenOrCursor(root.targetScreen); root.mode = "editor"; }
            }
        }
    }

    Component.onCompleted: refresh()

    // ---- hover zones ------------------------------------------------------------------------
    Variants {
        model: root.cfg.enabled && !root.blocked && (root.cfg.monitor === "all" || root.cfg.monitor === "") ? Quickshell.screens
             : (root.cfg.enabled && !root.blocked ? Quickshell.screens.filter(sc => sc.name === root.cfg.monitor) : [])

        delegate: PanelWindow {
            id: zone
            required property var modelData
            screen: modelData
            color: "transparent"
            visible: root.mode === "hidden"
            WlrLayershell.namespace: "qs-x-notes-zone"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            anchors { bottom: root.atBottom; top: !root.atBottom; right: root.atRight; left: !root.atRight }
            implicitWidth: Math.max(4, root.s(8)); implicitHeight: Math.max(4, root.s(8))

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.AllButtons
                onEntered: { if (root.cfg.noDrag && pressedButtons !== 0) return; showTimer.pendingScreen = zone.modelData; showTimer.restart(); }
                onExited: { showTimer.stop(); if (root.mode === "hidden") expandTimer.stop(); }
                onClicked: root.openEditor(zone.modelData, "")
            }
        }
    }

    NoteCard { id: card; ctl: root }
    NoteEditor { id: editor; ctl: root }
}
