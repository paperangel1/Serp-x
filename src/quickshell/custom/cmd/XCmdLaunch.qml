pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."
import "LaunchLogic.js" as LL

// State shared by the launch surfaces of the Commands app: the palette, the bar button (+ its menu) and the desktop
// widget. Data comes from `x_cmd.sh ui-launch` / `pulse` (works with the daemon or in-process); runs, pins and the global pause
// go through the same CLI, so a manual command also runs when the daemon is not started. Tests set `fake = true`: no
// process is started, the state is injected and the CLI calls are only recorded in `calls`.
Item {
    id: root
    visible: false

    readonly property string script: Caching.serpantinumDir + "/scripts/custom/cmd/x_cmd.sh"
    readonly property string lang: (I18n.currentLang || "ru").indexOf("ru") === 0 ? "ru" : "en"

    property bool fake: false
    property var calls: []                    // fake mode: [{args: [...]}] of every CLI call

    // ---- data ------------------------------------------------------------------------------
    property var commands: []
    property var pinnedIds: []
    property bool pausedAll: false
    property string mode: "local"             // daemon | local
    property bool loaded: false
    property bool loading: false
    property string error: ""
    readonly property var pinnedCommands: LL.pinnedOf(commands, pinnedIds)
    function byId(id) { for (let i = 0; i < commands.length; i++) if (commands[i].id === id) return commands[i]; return null; }
    function byName(name) { for (let i = 0; i < commands.length; i++) if (commands[i].name === name) return commands[i]; return null; }

    // ---- palette / menu state --------------------------------------------------------------
    property bool paletteOpen: false
    property bool showAuto: false
    property bool menuOpen: false
    property real menuX: -1                   // anchor of the bar menu in screen coordinates (-1: not set)
    property real menuY: -1
    function openPalette() { if (paletteOpen) return; XLog.info("cmd", "UI: palette opened"); paletteOpen = true; menuOpen = false; refresh(); }
    function closePalette() { if (!paletteOpen) return; paletteOpen = false; }
    function togglePalette() { if (paletteOpen) closePalette(); else openPalette(); }
    function openMenu(x, y) { menuX = x; menuY = y; menuOpen = true; paletteOpen = false; refresh(); }
    function closeMenu() { menuOpen = false; }
    // the Commands window (graph of one command); fake mode only records the request
    property string lastOpened: ""
    function openInApp(name) { lastOpened = name; if (fake) return; if (name) XCmd.openCommand(name); else XCmd.openWindow(); }

    // ---- run state (for the widget and the palette rows) -------------------------------------------
    property var runStates: ({})              // id -> {state: running|ok|error, message, until}
    signal notice(string kind, string title, string sub)     // kind: running | ok | error (the host shows it as a toast)
    function stateOf(id) { const r = runStates[id]; return r ? r.state : ""; }
    function setRun(id, st) {
        const m = Object.assign({}, runStates);
        if (st === null) delete m[id]; else m[id] = st;
        runStates = m;
    }
    function tr(k, args, fb) { return XI18n.t(k, args, fb); }

    function run(c) {
        if (!c) return false;
        const why = LL.blockReason(c);
        if (why !== null) {
            XLog.info("cmd", "UI: run refused id=" + c.id + " why=" + why);
            notice("error", tr("cmd.launch.cannot_run", { name: c.name }, "Не запущена: " + c.name), blockText(why));
            return false;
        }
        if (stateOf(c.id) === "running") return false;
        XLog.info("cmd", "UI: run from launcher id=" + c.id);
        setRun(c.id, { state: "running", message: "", until: 0 });
        notice("running", tr("cmd.launch.started", { name: c.name }, "Запущено: " + c.name), "");
        if (fake) { calls = calls.concat([{ args: ["run", c.name] }]); return true; }
        const p = runComp.createObject(root, { cid: c.id, cname: c.name });
        p.command = ["bash", script, "--json", "run", c.name];
        p.running = true;
        return true;
    }
    function runDone(cid, cname, code, out, err) {
        let res = null;
        try { res = JSON.parse(out); } catch (e) { res = null; }
        const ok = res !== null ? (res.status === "ok" || res.status === "skipped") : code === 0;
        let msg = res !== null ? (res.message || "") : "";
        if (res === null) { try { msg = JSON.parse(err).message || ""; } catch (e) { msg = (err || "").trim().split("\n").pop(); } }
        if (!ok && res !== null && res.status === "denied" && msg === "") msg = blockText("unapproved");
        finishRun(cid, cname, ok, msg);
    }
    function finishRun(cid, cname, ok, msg) {
        setRun(cid, { state: ok ? "ok" : "error", message: msg || "", until: Date.now() + 5000 });
        clearTimer.restart();
        XLog.info("cmd", "UI: run finished id=" + cid + " ok=" + ok);
        notice(ok ? "ok" : "error", ok ? tr("cmd.launch.done", { name: cname }, "Выполнено: " + cname)
                                       : tr("cmd.launch.failed", { name: cname }, "Ошибка: " + cname), ok ? "" : (msg || ""));
        refresh();
        if (watchers > 0) pollPulse();
    }
    function blockText(why) {
        if (why === "errors") return tr("cmd.launch.why_errors", undefined, "В команде есть ошибки: откройте её и исправьте");
        if (why === "unapproved") return tr("cmd.launch.why_unapproved", undefined, "Права не подтверждены: откройте команду и подтвердите");
        if (why === "example") return tr("cmd.launch.why_example", undefined, "Это пример: добавьте его в свои команды");
        return "";
    }

    // ---- pin / pause ---------------------------------------------------------------------------
    function setPinned(id, on) {
        const c = byId(id);
        if (!c) return;
        XLog.info("cmd", "UI: " + (on ? "pin" : "unpin") + " id=" + id);
        pinnedIds = on ? (pinnedIds.indexOf(id) >= 0 ? pinnedIds : pinnedIds.concat([id])) : pinnedIds.filter(x => x !== id);
        commands = commands.map(x => x.id === id ? Object.assign({}, x, { pinned: on }) : x);
        cli([on ? "pin" : "unpin", id], () => refresh());
    }
    function togglePinned(id) { const c = byId(id); if (c) setPinned(id, !c.pinned); }
    function setPaused(on) {
        XLog.info("cmd", "UI: pause all " + on);
        pausedAll = on; pulse = Object.assign({}, pulse, { paused_all: on });
        cli([on ? "pause" : "resume"], () => pollPulse());
    }

    // ---- loading ---------------------------------------------------------------------------------
    function refresh() {
        if (fake || loading) return;
        loading = true;
        listProc.running = true;
    }
    function applyList(text) {
        loading = false;
        try {
            const d = JSON.parse(text);
            commands = d.commands || [];
            pinnedIds = d.pinned || [];
            pausedAll = !!d.paused_all;
            mode = d.mode || "local";
            error = "";
        } catch (e) {
            error = tr("cmd.launch.load_failed", undefined, "Не удалось прочитать список команд");
        }
        loaded = true;
    }
    property int subscribers: 0               // widget faces: refresh the list while at least one is alive
    function subscribe() { subscribers++; if (subscribers === 1) refresh(); }
    function unsubscribe() { subscribers = Math.max(0, subscribers - 1); }

    // ---- bar button: cheap pulse while a face is visible ---------------------------------------------
    property int watchers: 0
    property var pulse: ({ paused_all: false, failed_recent: 0, last: null, pinned: 0 })
    readonly property bool attention: pulse.paused_all === true || (pulse.failed_recent || 0) > 0
    function watch(d) { watchers = Math.max(0, watchers + d); if (watchers > 0 && d > 0) pollPulse(); }
    function pollPulse() { if (fake || pulseProc.running) return; pulseProc.running = true; }

    // ---- CLI queue (pin / pause) ----------------------------------------------------------------------
    property var cliQueue: []
    property bool cliBusy: false
    function cli(args, done) {
        if (fake) { calls = calls.concat([{ args: args }]); if (done) done(); return; }
        cliQueue = cliQueue.concat([{ args: args, done: done }]);
        cliNext();
    }
    function cliNext() {
        if (cliBusy || cliQueue.length === 0) return;
        cliBusy = true;
        cliCur = cliQueue[0];
        cliQueue = cliQueue.slice(1);
        cliProc.command = ["bash", script, "--json"].concat(cliCur.args);
        cliProc.running = true;
    }
    property var cliCur: null

    Component {
        id: runComp
        Process {
            id: rp
            property string cid: ""
            property string cname: ""
            property string out: ""
            property string err: ""
            stdout: StdioCollector { onStreamFinished: rp.out = this.text }
            stderr: StdioCollector { onStreamFinished: rp.err = this.text }
            onExited: (code) => { Qt.callLater(() => { root.runDone(cid, cname, code, out, err); destroy(); }); }
        }
    }
    Process {
        id: listProc
        command: ["bash", root.script, "ui-launch", "--lang", root.lang]
        stdout: StdioCollector { onStreamFinished: root.applyList(this.text) }
        onExited: (code) => { if (code !== 0) { root.loading = false; if (!root.loaded) { root.error = root.tr("cmd.launch.load_failed", undefined, "Не удалось прочитать список команд"); root.loaded = true; } } }
    }
    Process {
        id: pulseProc
        command: ["bash", root.script, "pulse"]
        stdout: StdioCollector { onStreamFinished: { try { root.pulse = JSON.parse(this.text); } catch (e) { } } }
    }
    Process {
        id: cliProc
        onExited: (code) => { const c = root.cliCur; root.cliCur = null; root.cliBusy = false; if (code !== 0) root.refresh(); else if (c && c.done) c.done(); root.cliNext(); }
    }
    Timer {
        id: clearTimer
        interval: 1000; repeat: true
        onTriggered: {
            const now = Date.now(); let changed = false; const m = Object.assign({}, root.runStates);
            for (const k in m) if (m[k].state !== "running" && m[k].until > 0 && m[k].until <= now) { delete m[k]; changed = true; }
            if (changed) root.runStates = m;
            if (Object.keys(m).length === 0) clearTimer.stop();
        }
    }
    Timer {      // visible surfaces only: the widget list and the pulse of a bar button; nothing runs when they are hidden
        interval: 30000; repeat: true
        running: !root.fake && (root.watchers > 0 || root.subscribers > 0)
        onTriggered: { if (root.watchers > 0) root.pollPulse(); if (root.subscribers > 0) root.refresh(); }
    }
}
