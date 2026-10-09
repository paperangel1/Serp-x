import QtQuick
import Quickshell
import "custom"
import "custom/cmd"

// Offscreen harness for the ask / show-result bridge (copied into the quickshell tree by cmd_ui_test.sh). The fake daemon
// (cmd_ui/fake_ui_daemon.py) sends requests; this "user" answers each dialog the way a person would through the same API.
ShellRoot {
    XCmdBridge { id: bridge }
    FloatingWindow { width: 600; height: 800; visible: true; color: "#0f0e14"
        CmdAskView { bridge: bridge; x: 20; y: 20 }
        CmdResultView { bridge: bridge; x: 20; y: 400 } }
    property int step: 0
    Timer {
        interval: 700; running: true; repeat: true
        onTriggered: {
            const c = bridge.current;
            if (c === null) { if (bridge.result !== null) { bridge.result = null; step++; if (step > 2) Qt.quit(); } return; }
            const mode = c.kind === "confirm" ? "confirm" : c.payload.mode;
            if (c.payload.title === "Отмена") bridge.answer({ cancel: true });
            else if (c.kind === "confirm") bridge.answer({ answer: true });
            else if (mode === "choice") bridge.answer({ index: 1 });
            else if (mode === "text") bridge.answer({ value: "привет" });
            else if (mode === "number") bridge.answer({ value: "2.5" });
            else bridge.answer({ answer: false });
        }
    }
    Timer { interval: 25000; running: true; onTriggered: Qt.quit() }
}
