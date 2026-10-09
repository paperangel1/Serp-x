pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Persistent logging for our QML (module logs under ~/.local/state/serpantinum/logs, see xlog.py).
//   XLog.info("hotkeys", "apply requested")      XLog.warn / XLog.error / XLog.debug (debug only when the level file says so)
// Every line goes to the quickshell log with the prefix "serpantinum-x:<module>" AND to the module file through ONE
// long-lived appender process fed over stdin (a process per line would be far too heavy). The appender redacts secrets.
// Never call it from hot paths (drag, wheel, per-frame timers); lines are rate-limited as a safety net.
Item {
    id: root

    readonly property string appender: Caching.serpantinumDir + "/scripts/custom/xlog/xlog.py"
    property bool debugEnabled: false
    property var queue: []
    property int budget: 60            // lines per second; extra lines are counted and reported once
    property int dropped: 0

    function log(module, level, msg) {
        const m = String(msg).replace(/\r?\n/g, "\\n").replace(/\t/g, " ");
        if (level === "debug" && !root.debugEnabled) return;
        const line = "serpantinum-x:" + module + " " + m;
        if (level === "error") console.error(line);
        else if (level === "warn") console.warn(line);
        else console.log(line);
        if (root.budget <= 0) { root.dropped++; return; }
        root.budget--;
        const rec = module + "\t" + level + "\t" + m + "\n";
        if (proc.running && proc.started) proc.write(rec);
        else if (root.queue.length < 200) root.queue.push(rec);
    }
    function debug(module, msg) { log(module, "debug", msg); }
    function info(module, msg) { log(module, "info", msg); }
    function warn(module, msg) { log(module, "warn", msg); }
    function error(module, msg) { log(module, "error", msg); }

    Process {
        id: proc
        property bool started: false
        running: Caching.serpantinumDir !== ""
        stdinEnabled: true
        command: ["python3", "-B", root.appender, "append-stdin"]
        onStarted: {
            proc.started = true;
            for (let i = 0; i < root.queue.length; i++) proc.write(root.queue[i]);
            root.queue = [];
        }
        onExited: { proc.started = false; restart.start(); }
    }
    Timer { id: restart; interval: 3000; onTriggered: proc.running = true }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: {
            if (root.dropped > 0) {
                const n = root.dropped; root.dropped = 0;
                root.budget = 60;
                root.log("doctor", "warn", "XLog rate limit: dropped " + n + " lines in the last second");
            } else root.budget = 60;
        }
    }

    // log level (debug on/off) is read once from the same switch the CLI uses: `serpantinum-x logs level debug`
    Process {
        id: levelProbe
        running: Caching.serpantinumDir !== ""
        command: ["python3", "-B", root.appender, "level"]
        stdout: StdioCollector { onStreamFinished: root.debugEnabled = (this.text.trim() === "debug") }
    }
}
