pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Backend of the update feature (serpantinum-x). Everything runs through
// scripts/custom/x_update.sh and x_changelog.sh; the script is taken from the repo
// checkout when it exists (so a stale install copy can never break updating).
//
// Sidebar contract (skeleton): updateAvailable / updateLabel / buttonText.
Item {
    id: root

    // ---- state shown by the sidebar and the tab ------------------------------------------

    property var info: ({})                // last `check` result
    property bool checking: false
    property bool checkFailed: false
    property real lastCheckMs: 0

    property var status: ({})              // status.json of the worker
    property bool starting: false          // `run` was requested, status file not updated yet

    property var backups: []
    property var versions: []              // [{version, count}] newest first

    // update_available also while an update is running / its result is not acknowledged,
    // so the stock sidebar button stays visible and shows the progress.
    readonly property bool hasUpdate: info && info.hasUpdate === true
    readonly property bool running: starting || (status && status.status === "running")
    readonly property bool resultPending: !running && status && (status.status === "ok" || status.status === "error") && status.ack !== true
    readonly property bool resultOk: resultPending && status.status === "ok" && status.phase === "done" && (status.detail || "") === ""
    readonly property bool resultError: resultPending && status.status === "error"

    property bool updateAvailable: hasUpdate || running || resultPending
    property string updateLabel: (info && info.updateLabel) ? info.updateLabel : ""

    readonly property string phase: status && status.phase ? status.phase : ""
    readonly property int pct: status && status.pct !== undefined ? status.pct : 0
    readonly property string targetLabel: status && status.to ? status.to : updateLabel

    readonly property bool dryClean: info && info.dryRun ? info.dryRun.clean === true : true
    readonly property var dryFiles: info && info.dryRun && info.dryRun.files ? info.dryRun.files : []
    readonly property bool dryHookOnly: info && info.dryRun ? info.dryRun.hookOnly === true : false

    readonly property string buttonText: {
        if (running) return XI18n.t("update.sidebar_running", { pct: pct }, "Installing… " + pct + "%");
        if (resultOk) return XI18n.t("update.sidebar_done", { label: targetLabel }, "Updated to " + targetLabel);
        if (resultError) return XI18n.t("update.sidebar_error", undefined, "Update failed — rolled back");
        if (updateLabel !== "") return XI18n.t("update.sidebar_button", { label: updateLabel }, "Update " + updateLabel);
        return I18n.t("guide.update_available");
    }

    // ---- script resolution ---------------------------------------------------------------

    function scriptCmd(script, args) {
        return [
            "bash",
            "-c",
            // serpantinum-x _run picks the dev checkout copy (SERPANTINUM_FORK_DIR / update.toml) or the install copy
            'x="$2/../bin/serpantinum-x"; [ -x "$x" ] || x="$HOME/.local/bin/serpantinum-x"; s="$1"; shift 2; exec "$x" _run "$s" "$@"',
            "x-update",
            script,
            Caching.serpantinumDir
        ].concat(args);
    }

    // ---- check ---------------------------------------------------------------------------

    function check() {
        if (checking || running) return;
        checking = true;
        checkProc.running = true;
    }

    Process {
        id: checkProc
        command: root.scriptCmd("x_update.sh", ["check"])
        stdout: StdioCollector {
            onStreamFinished: {
                root.checking = false;
                try {
                    let o = JSON.parse(this.text.trim());
                    root.info = o;
                    root.checkFailed = o.status !== "ok";
                    root.lastCheckMs = Date.now();
                } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (o)");
                    root.checkFailed = true;
                }
            }
        }
    }

    Timer {   // first check shortly after the guide is first opened, then every 6 hours
        interval: 15000
        running: true
        repeat: false
        onTriggered: if (root.lastCheckMs === 0 || Date.now() - root.lastCheckMs > 60000) root.check()
    }
    Timer {
        interval: 6 * 60 * 60 * 1000
        running: true
        repeat: true
        onTriggered: root.check()
    }

    // ---- run + status polling ------------------------------------------------------------

    function startUpdate(allowDrift) { XLog.info("update", "UI: update requested allowDrift=" + !!allowDrift);
        if (running) return;
        starting = true;
        runProc.command = scriptCmd("x_update.sh", allowDrift === true ? ["run", "--allow-drift"] : ["run"]);
        runProc.running = true;
        statusPoll.start();
    }

    Process {
        id: runProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let o = JSON.parse(this.text.trim());
                    if (o.status === "error") {
                        root.starting = false;
                        root.status = { status: "error", phase: "preflight", code: o.code || "already_running", detail: "", pct: 0, ack: false };
                    }
                } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (o)");}
                root.readStatus();
            }
        }
    }

    function readStatus() { statusProc.running = true; }

    Process {
        id: statusProc
        command: root.scriptCmd("x_update.sh", ["status"])
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let o = JSON.parse(this.text.trim());
                    if (o && o.status) {
                        root.status = o;
                        if (o.status === "running") root.starting = false;
                        else if (root.starting && o.ts * 1000 >= root.startMs - 2000) root.starting = false;
                        if (o.status === "ok" && o.phase === "done") root.refreshAfterUpdate();
                    }
                } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (o)");}
            }
        }
    }

    property real startMs: 0
    onStartingChanged: if (starting) startMs = Date.now()

    Timer {
        id: statusPoll
        interval: 700
        repeat: true
        running: root.running
        onTriggered: root.readStatus()
    }

    property bool refreshedAfterUpdate: false
    function refreshAfterUpdate() {
        if (refreshedAfterUpdate) return;
        refreshedAfterUpdate = true;
        check();
        loadBackups();
    }

    function ackResult() {
        ackProc.running = true;
        let s = Object.assign({}, status);
        s.ack = true;
        status = s;
        refreshedAfterUpdate = false;
    }
    Process { id: ackProc; command: root.scriptCmd("x_update.sh", ["ack"]) }

    Component.onCompleted: { readStatus(); loadBackups(); }

    // ---- backups / restore ---------------------------------------------------------------

    function loadBackups() { backupsProc.running = true; }
    Process {
        id: backupsProc
        command: root.scriptCmd("x_update.sh", ["backups"])
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.backups = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (backups)"); root.backups = []; }
            }
        }
    }

    property string restoringName: ""
    function restore(name) { XLog.info("update", "UI: restore requested backup=" + name);
        if (restoringName !== "" || running) return;
        restoringName = name;
        restoreProc.command = scriptCmd("x_update.sh", ["restore", name]);
        restoreProc.running = true;
    }
    Process {
        id: restoreProc
        stdout: StdioCollector { onStreamFinished: root.restoringName = "" }
    }

    // ---- changelog -----------------------------------------------------------------------

    readonly property string changelogLang: I18n.currentLang !== undefined && I18n.currentLang !== "" ? I18n.currentLang : "en"

    property var latestChangelog: null     // result of `get latest`
    property bool latestLoading: false
    property var selectedChangelog: null
    property string selectedVersion: ""
    property bool selectedLoading: false

    function loadLatestChangelog() {
        if (latestLoading) return;
        latestLoading = true;
        latestProc.running = true;
    }
    Process {
        id: latestProc
        command: root.scriptCmd("x_changelog.sh", ["get", "latest", root.changelogLang])
        stdout: StdioCollector {
            onStreamFinished: {
                root.latestLoading = false;
                try { root.latestChangelog = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (latestChangelog)"); root.latestChangelog = null; }
            }
        }
    }

    function loadVersions() { versionsProc.running = true; }
    Process {
        id: versionsProc
        command: root.scriptCmd("x_changelog.sh", ["versions"])
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.versions = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (versions)"); root.versions = []; }
                if (root.selectedVersion === "" && root.versions.length > 0) root.selectVersion(root.versions[0].version);
            }
        }
    }

    property string pendingVersion: ""
    function selectVersion(v) {
        selectedVersion = v;
        selectedChangelog = null;
        selectedLoading = true;
        if (selectedProc.running) { pendingVersion = v; return; }
        pendingVersion = "";
        selectedProc.command = scriptCmd("x_changelog.sh", ["get", v, changelogLang]);
        selectedProc.running = true;
    }
    Process {
        id: selectedProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.pendingVersion !== "") { let v = root.pendingVersion; root.pendingVersion = ""; root.selectVersion(v); return; }
                root.selectedLoading = false;
                try { root.selectedChangelog = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("update", "XUpdate.qml: could not parse JSON output (selectedChangelog)"); root.selectedChangelog = null; }
            }
        }
    }

    // a new check result may change what "latest" means
    onInfoChanged: loadLatestChangelog()
}
