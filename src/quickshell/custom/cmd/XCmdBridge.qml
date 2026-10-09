import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."

// The shell's end of the daemon's `ui.request` bridge (see scripts/custom/cmd/xcmd/protocol.py). It keeps one connection to
// the daemon socket, subscribes to the "ui" topic and turns requests into state for two small windows:
//   ask / confirm -> `current` (queued, one at a time) answered with ui_response {index|value|answer} or {cancel: true}
//   show          -> `result` (a popup with the text; the run is answered at once, it does not wait for the popup)
// Without a connection the daemon falls back to a notification, so a missing shell never blocks a command.
Item {
    id: bridge
    visible: false

    readonly property string socketPath: Quickshell.env("XCMD_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/serpantinum/cmdd.sock")
    property var queue: []                   // pending ask/confirm requests, the first one is on screen
    readonly property var current: queue.length > 0 ? queue[0] : null
    property var result: null                // {title, text} of the last «показать результат»
    property int seq: 0
    property bool wasConnected: false

    function onLine(line) {
        let m = null;
        try { m = JSON.parse(line); } catch (e) { XLog.warn("cmd", "XCmdBridge.qml: could not parse a daemon line"); return; }
        if (m.ev === "ui.request") bridge.request(m);
        else if (m.ev === "ui.cancel") bridge.drop(m.id);
    }
    function request(m) {
        const p = m.payload || ({});
        if (m.kind === "show") {
            XLog.info("cmd", "UI: show-result popup");
            bridge.result = { title: p.title || "", text: p.text || "" };
            bridge.respond(m.id, { shown: true });
        } else if (m.kind === "ask" || m.kind === "confirm") {
            XLog.info("cmd", "UI: " + m.kind + " dialog opened (mode=" + (p.mode || "confirm") + ")");
            bridge.queue = bridge.queue.concat([{ id: m.id, kind: m.kind, payload: p }]);
        } else {
            bridge.respond(m.id, {});
        }
    }
    function drop(id) {
        const n = bridge.queue.length;
        bridge.queue = bridge.queue.filter(q => q.id !== id);
        if (bridge.queue.length !== n) XLog.info("cmd", "UI: dialog closed by the daemon (timeout or run cancelled)");
    }
    // answer the dialog on screen; `data` is {index}|{value}|{answer}|{cancel: true}
    function answer(data) {
        const cur = bridge.current;
        if (cur === null) return;
        bridge.queue = bridge.queue.slice(1);
        XLog.info("cmd", "UI: dialog answered" + (data.cancel ? " (cancelled)" : ""));
        bridge.respond(cur.id, data);
    }
    function respond(id, data) {
        bridge.seq += 1;
        bridge.send({ id: 1000 + bridge.seq, method: "ui_response", params: Object.assign({ id: id }, data) });
    }
    function send(obj) {
        if (!sock.connected) return;
        sock.write(JSON.stringify(obj) + "\n");
        sock.flush();
    }

    Socket {
        id: sock
        path: bridge.socketPath
        parser: SplitParser { onRead: data => bridge.onLine(data) }
        onConnectedChanged: {
            if (connected) {
                bridge.wasConnected = true;
                XLog.info("cmd", "UI bridge connected to the daemon");
                bridge.send({ id: 1, method: "subscribe", params: { topics: ["ui"] } });
            } else {
                if (bridge.wasConnected) XLog.info("cmd", "UI bridge disconnected from the daemon");
                bridge.wasConnected = false;
                bridge.queue = [];
            }
        }
    }
    // the daemon may start later or restart: look for its socket every few seconds and connect once it exists (no retries
    // against a missing socket, so a stopped daemon leaves nothing in the shell log)
    Process {
        id: probe
        command: ["test", "-S", bridge.socketPath]
        onExited: (code) => { if (code === 0 && !sock.connected) sock.connected = true; }
    }
    Timer {
        interval: 5000; running: true; repeat: true; triggeredOnStart: true
        onTriggered: if (!sock.connected && !probe.running) probe.running = true
    }
}
