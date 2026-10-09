import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../"
import ".."

// Bridge for the «Бездействие» and «Возвращение после бездействия» triggers. The engine daemon cannot see the
// Wayland idle state, so it publishes the idle durations it needs (in minutes) in $XDG_RUNTIME_DIR/serpantinum/cmd-idle.json
// and this item creates one IdleMonitor per duration and reports the changes back with `cmd emit idle.start|idle.stop`
// (the daemon applies per-node filters, the loop guard and everything else). With no idle automation the file does not
// exist and no monitor is created.
Item {
    id: bridge
    visible: false

    readonly property string requestPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/serpantinum/cmd-idle.json"
    readonly property string script: Caching.serpantinumDir + "/scripts/custom/cmd/x_cmd.sh"
    property var minutes: []

    function parse(text) {
        try {
            const m = JSON.parse(text).minutes;
            bridge.minutes = Array.isArray(m) ? m.filter(x => x > 0 && x <= 240) : [];
        } catch (e) { XLog.warn("cmd", "XCmdIdle.qml: could not parse JSON output (m)");
            bridge.minutes = [];
        }
    }

    function send(type, mins) {
        sender.createObject(bridge, { command: ["bash", bridge.script, "emit", type, JSON.stringify({ minutes: mins })] });
    }

    FileView {
        path: bridge.requestPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: bridge.parse(text())
        onLoadFailed: bridge.minutes = []
    }

    Component {
        id: sender
        Process {
            running: true
            onExited: destroy()
        }
    }

    Repeater {
        model: bridge.minutes
        delegate: Item {
            id: slot
            required property var modelData
            property bool wasIdle: false

            IdleMonitor {
                timeout: slot.modelData * 60
                respectInhibitors: true
                onIsIdleChanged: {
                    if (isIdle) {
                        slot.wasIdle = true;
                        bridge.send("idle.start", slot.modelData);
                    } else if (slot.wasIdle) {
                        slot.wasIdle = false;
                        bridge.send("idle.stop", slot.modelData);
                    }
                }
            }
        }
    }
}
