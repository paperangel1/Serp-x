pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."

// Backend of the Servers widget (serpantinum-x). All work is done by scripts/custom/servers/x_servers.py
// (via x_servers.sh): Remnawave nodes, restricted SSH commands, one-time enrollment. This singleton only
// holds the state the views show and starts those processes.
//
// Secrets never go through argv: the panel URL/token and the admin password are written to the stdin of
// the helper process and are not kept in any property after the call returns.
Item {
    id: root

    // ---- state --------------------------------------------------------------------------
    property bool fake: false                    // offscreen tests: no processes, state is injected
    property var servers: []                     // last poll
    property bool configured: false
    property string apiError: ""
    property real lastPollMs: 0
    property bool polling: false
    property string selectedId: ""
    property var cfgInfo: ({ urlSet: false, tokenSet: false, host: "", key: { exists: false, fingerprint: "" }, commands: [], problems: [] })
    property var lastRuns: ({})                  // serverId -> {command, code, ts}
    property int subscribers: 0

    // ---- settings (settings.json -> "servers") ----------------------------------------------
    readonly property var rawCfg: {
        let r = Config.rawSettings ? Config.rawSettings["servers"] : null;
        return (r && typeof r === "object") ? r : {};
    }
    readonly property int pollSeconds: rawCfg.pollSeconds !== undefined ? Math.max(10, rawCfg.pollSeconds) : 30
    readonly property var hiddenIds: Array.isArray(rawCfg.hidden) ? rawCfg.hidden : []

    function setSetting(key, value) { XLog.info("servers", "UI: setting changed " + key);
        if (!Config.dataReady) return false;
        Config.setSetting("servers." + key, value);
        return true;
    }
    function setHidden(id, hidden) {
        let cur = hiddenIds.filter(x => x !== id);
        if (hidden) cur.push(id);
        setSetting("hidden", cur);
    }
    function isHidden(id) { return hiddenIds.indexOf(id) !== -1; }

    readonly property var visibleServers: servers.filter(s => hiddenIds.indexOf(s.id) === -1)
    readonly property int onlineCount: visibleServers.filter(s => s.online === true).length
    readonly property var selected: {
        for (let i = 0; i < visibleServers.length; i++) if (visibleServers[i].id === selectedId) return visibleServers[i];
        return null;
    }

    // ---- commands -----------------------------------------------------------------------------
    readonly property var allCommands: cfgInfo.commands || []
    readonly property var diagCommands: allCommands.filter(c => c.group === "diag")
    readonly property var actionCommands: allCommands.filter(c => c.group === "action")
    readonly property var customCommandList: allCommands.filter(c => c.group === "custom")
    function cmdLabel(c) { return c ? t("servers.cmd." + c.id, undefined, c.label) : ""; }
    function commandById(id) {
        for (let i = 0; i < allCommands.length; i++) if (allCommands[i].id === id) return allCommands[i];
        return null;
    }

    // ---- terminal -------------------------------------------------------------------------------
    property bool termVisible: false
    property string termServerId: ""
    property string termCommandId: ""
    property var termLines: []
    property bool termRunning: false
    property var termExit: null                  // {code, ms, dropped, timedOut}
    property string termNonce: ""
    property var pending: null                   // {serverId, commandId} waiting for the confirm dialog
    property var _buf: []

    readonly property string termTitle: {
        let c = commandById(termCommandId);
        let s = serverById(termServerId);
        return (c ? cmdLabel(c) : termCommandId) + (s ? "  ·  " + s.name : "");
    }

    function serverById(id) {
        for (let i = 0; i < servers.length; i++) if (servers[i].id === id) return servers[i];
        return null;
    }
    function select(id) { selectedId = id; if (!fake && subscribers > 0) poll(true); }

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    // ---- script resolution -----------------------------------------------------------------------
    function scriptCmd(args) {
        return [
            "bash", "-c",
            'x="$1/../bin/serpantinum-x"; [ -x "$x" ] || x="$HOME/.local/bin/serpantinum-x"; shift; exec "$x" _run servers/x_servers.sh "$@"',
            "x-servers", Caching.serpantinumDir
        ].concat(args);
    }

    // ---- polling ---------------------------------------------------------------------------------
    property int _tick: 0

    function applyPoll(o) {
        servers = o.servers || [];
        configured = o.configured === true;
        apiError = o.apiError || "";
        lastPollMs = Date.now();
        if (selectedId === "" || !selectedById(selectedId)) {
            let first = visibleServers.length > 0 ? visibleServers[0].id : "";
            selectedId = first;
        }
    }
    function selectedById(id) {
        for (let i = 0; i < visibleServers.length; i++) if (visibleServers[i].id === id) return true;
        return false;
    }

    function poll(withSsh) {
        if (fake || polling) return;
        polling = true;
        let ids = visibleServers.map(s => s.id).join(",");
        pollProc.command = scriptCmd(["poll"].concat(ids !== "" ? ["--ids", ids] : []).concat(withSsh ? ["--ssh"] : []));
        pollProc.running = true;
    }
    function refresh() { poll(true); }
    function subscribe() { subscribers++; if (subscribers === 1 && !fake) { loadConfig(); poll(true); } }
    function unsubscribe() { subscribers = Math.max(0, subscribers - 1); }

    Process {
        id: pollProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.polling = false;
                try { root.applyPoll(JSON.parse(this.text.trim().split("\n").pop())); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (line 135)"); root.apiError = "bad_output"; }
            }
        }
    }
    Timer {
        interval: root.pollSeconds * 1000
        running: root.subscribers > 0 && !root.fake
        repeat: true
        onTriggered: { root._tick++; root.poll(root._tick % 2 === 0); }
    }

    function loadConfig() {
        if (fake) return;
        cfgProc.command = scriptCmd(["config"]);
        cfgProc.running = true;
        histProc.command = scriptCmd(["history", "-n", "60"]);
        histProc.running = true;
    }
    Process {
        id: histProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let o = JSON.parse(this.text.trim().split("\n").pop());
                    let lr = {};
                    (o.history || []).forEach(h => { if (!lr[h.server]) lr[h.server] = { command: h.command, code: h.code, ts: h.ts * 1000 }; });
                    root.lastRuns = Object.assign(lr, root.lastRuns);
                } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)");}
            }
        }
    }

    // Opens commands.toml in the default editor (creates it with a commented template first).
    function openCommandsFile() {
        let dir = cfgInfo.dir || "";
        if (dir === "") return;
        Quickshell.execDetached(["bash", "-c",
            'f="$1/commands.toml"; mkdir -p "$1"; if [ ! -f "$f" ]; then cat > "$f" <<\'EOF\'\n' +
            '# Свои команды сервера. Каждая команда — один скрипт на сервере.\n' +
            '# id: a-z, 0-9, дефис, до 32 символов. danger: none | confirm | typed\n' +
            '# script: локальный файл; он копируется на сервер кнопкой «Подключить» (Настройки → Серверы).\n#\n' +
            '# [[command]]\n# id = "backup-db"\n# label = "Бэкап базы"\n' +
            '# script = "~/.config/serpantinum/servers/scripts/backup-db.sh"\n# danger = "confirm"\n# timeout = 120\nEOF\nfi; exec xdg-open "$f"',
            "x-servers", dir]);
    }
    Process {
        id: cfgProc
        stdout: StdioCollector {
            onStreamFinished: { try { root.cfgInfo = JSON.parse(this.text.trim().split("\n").pop()); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (cfgInfo)");} }
        }
    }

    // ---- running commands ------------------------------------------------------------------------
    // Dangerous commands first go through the confirm dialog (danger = "confirm" | "typed").
    function requestRun(serverId, commandId) { XLog.info("servers", "UI: run requested command=" + commandId);
        let c = commandById(commandId);
        if (!c) return;
        if (c.danger === "confirm" || c.danger === "typed") { pending = { serverId: serverId, commandId: commandId }; return; }
        run(serverId, commandId);
    }
    function cancelPending() { pending = null; }
    function confirmPending(typedName) { XLog.info("servers", "UI: dangerous command confirmed");
        if (!pending) return false;
        let c = commandById(pending.commandId);
        let s = serverById(pending.serverId);
        if (c && c.danger === "typed" && (!s || typedName.trim() !== s.name)) return false;
        let p = pending;
        pending = null;
        run(p.serverId, p.commandId);
        return true;
    }

    function run(serverId, commandId) {
        if (fake) return;
        if (termRunning) runProc.running = false;
        termServerId = serverId;
        termCommandId = commandId;
        termLines = [];
        _buf = [];
        termExit = null;
        termNonce = "";
        termRunning = true;
        termVisible = true;
        runProc.command = scriptCmd(["run", serverId, commandId]);
        runProc.running = true;
    }
    function cancelRun() { XLog.info("servers", "UI: run cancelled"); if (termRunning) runProc.running = false; }
    function closeTerminal() { termVisible = false; if (termRunning) runProc.running = false; }
    function copyOutput() { Quickshell.execDetached(["wl-copy", termLines.join("\n")]); }
    function rerun() { if (termServerId !== "" && termCommandId !== "") run(termServerId, termCommandId); }

    function _flush() {
        if (_buf.length === 0) return;
        termLines = termLines.concat(_buf);
        _buf = [];
    }
    Timer { id: flushTimer; interval: 80; repeat: true; running: root.termRunning; onTriggered: root._flush() }

    Process {
        id: runProc
        stdout: SplitParser {
            onRead: line => {
                if (line.indexOf("::serp-start::") === 0) { root.termNonce = line.substring(14); return; }
                let tag = "::serp-exit::" + root.termNonce + "::";
                if (root.termNonce !== "" && line.indexOf(tag) === 0) {
                    try { root.termExit = JSON.parse(line.substring(tag.length)); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (termExit)"); root.termExit = { code: -1 }; }
                    return;
                }
                root._buf.push(line);
            }
        }
        onRunningChanged: {
            if (!running && root.termRunning) {
                root._flush();
                root.termRunning = false;
                if (root.termExit === null) root.termExit = { code: -1, cancelled: true };
                let lr = Object.assign({}, root.lastRuns);
                lr[root.termServerId] = { command: root.termCommandId, code: root.termExit.code, ts: Date.now() };
                root.lastRuns = lr;
                root.poll(true);
            }
        }
    }

    // ---- secrets / key / enrollment --------------------------------------------------------------------
    property string secretResult: ""             // "", "ok", or an error code for the last setSecret
    property string checkResult: ""              // "", "checking", "ok:<N>", or an error code
    property string keyResult: ""
    property string enrollState: ""              // "", "running", "ok", "error:<step>:<text>"
    property string oneLinerResult: ""

    function setSecret(name, value) {
        if (fake || value === "") return;
        secretProc.command = scriptCmd(["secret-set", name]);
        secretProc.secretValue = value;
        secretResult = "";
        secretProc.running = true;
    }
    Process {
        id: secretProc
        property string secretValue: ""
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: {
                try { let o = JSON.parse(this.text.trim().split("\n").pop()); root.secretResult = o.ok ? "ok" : (o.error || "error"); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)"); root.secretResult = "error"; }
                secretProc.secretValue = "";
                root.loadConfig();
            }
        }
        onRunningChanged: if (running) { write(secretValue + "\n"); }
    }

    function checkApi() {
        if (fake) return;
        checkResult = "checking";
        checkProc.command = scriptCmd(["check"]);
        checkProc.running = true;
    }
    Process {
        id: checkProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { let o = JSON.parse(this.text.trim().split("\n").pop()); root.checkResult = o.ok ? ("ok:" + o.nodes) : (o.error || "error"); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)"); root.checkResult = "error"; }
                if (root.checkResult.indexOf("ok:") === 0) root.poll(true);
            }
        }
    }

    function newKey(force) {
        if (fake) return;
        keyProc.command = scriptCmd(["key-new"].concat(force ? ["--force"] : []));
        keyProc.running = true;
    }
    Process {
        id: keyProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { let o = JSON.parse(this.text.trim().split("\n").pop()); root.keyResult = o.ok ? "ok" : (o.error || "error"); } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)"); root.keyResult = "error"; }
                root.loadConfig();
            }
        }
    }

    function copyOneLiner() {
        if (fake) return;
        oneLinerResult = "";
        oneProc.command = scriptCmd(["oneliner"]);
        oneProc.running = true;
    }
    Process {
        id: oneProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let o = JSON.parse(this.text.trim().split("\n").pop());
                    if (o.ok) { Quickshell.execDetached(["wl-copy", o.command]); root.oneLinerResult = "copied"; }
                    else root.oneLinerResult = o.error || "error";
                } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)"); root.oneLinerResult = "error"; }
            }
        }
    }

    // Enrollment with the admin password (used once; written to the helper's stdin only).
    function enroll(serverId, user, password, host, port, uninstall) {
        if (fake || password === "" || enrollState === "running") return;
        let a = ["enroll", "--user", user || "root"];
        if (uninstall === true) a.push("--uninstall");
        if (serverId !== "") a = a.concat(["--server", serverId]);
        if (host && host !== "") a = a.concat(["--host", host]);
        if (port && port > 0) a = a.concat(["--port", String(port)]);
        enrollProc.command = scriptCmd(a);
        enrollProc.pw = password;
        enrollState = "running";
        enrollProc.running = true;
    }
    Process {
        id: enrollProc
        property string pw: ""
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: {
                enrollProc.pw = "";
                try {
                    let o = JSON.parse(this.text.trim().split("\n").pop());
                    root.enrollState = o.ok ? (o.state === "removed" ? "removed" : "ok") : ("error:" + (o.step || "") + ":" + (o.error || ""));
                } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (o)"); root.enrollState = "error::" }
                root.poll(true);
            }
        }
        onRunningChanged: if (running) { write(pw + "\n"); }
    }

    // ---- manual servers (servers.toml): add / remove -----------------------------------------------------
    property string addState: ""                 // "", "running", "ok", "error:<code>:<field>"
    property string lastAddedId: ""
    property string removeState: ""              // "", "ok", "error"

    function addServer(name, host, port, user) {
        if (fake || addState === "running") return;
        addProc.command = scriptCmd(["add", "--name", name, "--host", host, "--port", String(port > 0 ? port : 22), "--user", user !== "" ? user : "serp"]);
        addState = "running";
        addProc.running = true;
    }
    Process {
        id: addProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let o = JSON.parse(this.text.trim().split("\n").pop());
                    if (o.ok) { root.lastAddedId = o.server ? o.server.id : ""; root.addState = "ok"; }
                    else root.addState = "error:" + (o.error || "") + ":" + (o.field || "");
                } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (add)"); root.addState = "error:add:"; }
                root.poll(true);
            }
        }
    }
    function removeServer(id, forgetHost) {
        if (fake) return;
        removeProc.command = scriptCmd(["remove", id].concat(forgetHost ? ["--forget-host"] : []));
        removeProc.running = true;
    }
    Process {
        id: removeProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.removeState = JSON.parse(this.text.trim().split("\n").pop()).ok ? "ok" : "error"; } catch (e) { XLog.warn("servers", "XServers.qml: could not parse JSON output (remove)"); root.removeState = "error"; }
                root.poll(true);
            }
        }
    }

    // ---- formatting helpers shared by the views --------------------------------------------------------
    function fmtUptime(sec) {
        if (sec === undefined || sec === null) return "—";
        let d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
        if (d > 0) return d + " " + t("servers.u.d", undefined, "д") + " " + h + " " + t("servers.u.h", undefined, "ч");
        if (h > 0) return h + " " + t("servers.u.h", undefined, "ч") + " " + m + " " + t("servers.u.m", undefined, "мин");
        return m + " " + t("servers.u.m", undefined, "мин");
    }
    function fmtBytes(b) {
        if (b === undefined || b === null) return "—";
        let u = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"], i = 0, v = Number(b);
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + u[i];
    }
    function cpuOf(s) { return (s && s.ssh && s.ssh.status && s.ssh.status.cpu !== undefined) ? s.ssh.status.cpu : -1; }
    function sshOk(s) { return !!(s && s.ssh && s.ssh.state === "ok"); }
    function ago(ms) {
        if (!ms) return "";
        let s = Math.max(0, Math.round((Date.now() - ms) / 1000));
        if (s < 60) return s + " " + t("servers.u.s", undefined, "с");
        if (s < 3600) return Math.round(s / 60) + " " + t("servers.u.m", undefined, "мин");
        return Math.round(s / 3600) + " " + t("servers.u.h", undefined, "ч");
    }
}
