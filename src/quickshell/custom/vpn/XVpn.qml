pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."

// State and actions of the VPN module. The only backend is src/scripts/custom/vpn/x_vpn.sh (one JSON
// document per command). Polling runs only while something shows VPN state (bar face, popup, tab:
// they call watch(+1) / watch(-1)). With XVPN_FAKE_STATUS=<file> the status is read from that JSON
// file and every action is only logged: this is how the UI is rendered and tested offscreen.
Item {
    id: root
    visible: false

    readonly property string fakeFile: Quickshell.env("XVPN_FAKE_STATUS") || ""
    readonly property bool fake: fakeFile !== ""
    readonly property string script: Caching.serpantinumDir + "/scripts/custom/vpn/x_vpn.sh"

    property var st: ({})
    property int watchers: 0
    property bool popupOpen: false
    property real anchorX: -1          // x (window coordinates) of the bar pill that opened the popup; -1 = top-right corner
    property real anchorY: -1
    property bool busy: false
    property string lastError: ""

    readonly property string vstate: st.state || "off"
    readonly property string reason: st.reason || ""
    readonly property string reasonNode: st.reasonNode || ""
    readonly property string phase: st.phase || ""
    readonly property var node: st.node || null
    readonly property var nodes: st.nodes || []
    readonly property string mode: st.mode || "ru-direct"
    readonly property bool killSwitch: !!st.killSwitch
    readonly property bool blockIPv6: st.blockIPv6 !== false
    readonly property bool autoDisable: st.autoDisable !== false
    readonly property var traffic: st.traffic || null
    readonly property real trafficUsed: traffic ? (traffic.used || 0) : 0
    readonly property real trafficTotal: traffic ? (traffic.total || 0) : 0
    readonly property real trafficExpire: traffic ? (traffic.expire || 0) : 0
    readonly property var subscription: st.subscription || ({ configured: false })
    readonly property var geo: st.geo || ({})
    readonly property var core: st.core || ({})
    readonly property var service: st.service || ({})
    readonly property bool happActive: !!st.happActive
    readonly property var happ: st.happ || ({})
    readonly property string selection: st.selection || ""
    readonly property var subInfo: (st.subscription && st.subscription.info) || []
    readonly property bool measuring: pingProc.running || !!st.measuring
    readonly property var degraded: st.degraded || []
    readonly property var pingCfg: st.ping || ({})
    readonly property string pingDisplay: pingCfg.display || "digits"      // digits | bars | barsDigits | dots
    readonly property string pingMethod: pingCfg.method || "httpGet"
    readonly property bool connected: vstate === "on"
    readonly property bool transitional: vstate === "starting" || vstate === "switching"
    readonly property real since: st.since || 0

    // live speed (bytes/s) from the counters of the tunnel
    property real speedDown: 0
    property real speedUp: 0
    property real _prevRx: -1
    property real _prevTx: -1
    property real _prevTs: 0
    property real nowMs: Date.now()

    function watch(d) { watchers = Math.max(0, watchers + d); if (watchers > 0) poll(); }

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    function displayName(n) {
        if (!n) return "";
        let nm = n.name || "";
        if (n.flag && nm.indexOf(n.flag) !== 0) return n.flag + " " + nm;
        return nm;
    }
    function plainName(n) {
        if (!n) return "";
        let nm = n.name || "";
        if (n.flag && nm.indexOf(n.flag) === 0) nm = nm.substring(n.flag.length).trim();
        return nm;
    }

    function fmtRate(bps) {
        let v = Number(bps) || 0;
        if (v >= 1048576) return (v / 1048576).toFixed(1) + " " + t("vpn.units.mbs", undefined, "МБ/с");
        if (v >= 1024) return Math.round(v / 1024) + " " + t("vpn.units.kbs", undefined, "КБ/с");
        return Math.round(v) + " " + t("vpn.units.bs", undefined, "Б/с");
    }
    function fmtDate(ts) {
        if (!ts) return "—";
        let d = new Date(ts * 1000);
        let p = (n) => (n < 10 ? "0" : "") + n;
        return p(d.getDate()) + "." + p(d.getMonth() + 1);
    }
    function fmtDateFull(ts) {
        if (!ts) return "—";
        let d = new Date(ts * 1000);
        let p = (n) => (n < 10 ? "0" : "") + n;
        return p(d.getDate()) + "." + p(d.getMonth() + 1) + "." + d.getFullYear();
    }
    readonly property string geoDate: (geo && geo.updated) ? fmtDate(geo.updated) : "—"
    function fmtGb(bytes) { return (Number(bytes) / 1073741824).toFixed(bytes >= 10737418240 ? 0 : 1); }
    function fmtUptime(sec) {
        sec = Math.max(0, Math.floor(sec));
        let h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
        let p = (n) => (n < 10 ? "0" : "") + n;
        return p(h) + ":" + p(m) + ":" + p(s);
    }
    function ago(ts) {
        if (!ts) return "";
        let d = Math.max(0, Math.floor((Date.now() / 1000) - ts));
        if (d < 90) return t("vpn.ago.now", undefined, "только что");
        if (d < 5400) return t("vpn.ago.min", { n: Math.round(d / 60) }, Math.round(d / 60) + " мин назад");
        if (d < 172800) return t("vpn.ago.hour", { n: Math.round(d / 3600) }, Math.round(d / 3600) + " ч назад");
        return t("vpn.ago.day", { n: Math.round(d / 86400) }, Math.round(d / 86400) + " дн назад");
    }
    readonly property string modeLabel: {
        if (mode === "all") return t("vpn.mode.all", undefined, "Всё через VPN");
        if (mode === "direct") return t("vpn.mode.direct", undefined, "Всё напрямую");
        return t("vpn.mode.ru", undefined, "Россия напрямую");
    }

    function applyStatus(txt) {
        let j = null;
        try { j = JSON.parse(txt); } catch (e) { XLog.warn("vpn", "XVpn.qml: could not parse JSON output (j)"); return; }
        if (!j || typeof j !== "object" || j.ok === false || !j.state) return;
        let now = (j.ts || Date.now() / 1000);
        if (j.rxBytes !== undefined && _prevRx >= 0 && now > _prevTs) {
            let dt = now - _prevTs;
            speedDown = Math.max(0, (j.rxBytes - _prevRx) / dt);
            speedUp = Math.max(0, (j.txBytes - _prevTx) / dt);
        }
        if (j.rxBytes !== undefined) { _prevRx = j.rxBytes; _prevTx = j.txBytes; _prevTs = now; }
        if (j.state !== "on") { speedDown = 0; speedUp = 0; }
        st = j;
    }

    function poll() {
        if (fake) { fakeView.reload(); return; }
        if (!statusProc.running) statusProc.running = true;
    }

    // A state-changing action is dropped while another one runs or right after one finished:
    // a double click / double signal must not flip the VPN twice (it used to end up in a random state).
    property double lastActionMs: 0
    function run(args) {
        var act = args && args[0];
        var now = Date.now();
        if (!fake && (act === "toggle" || act === "connect" || act === "disconnect")
                && (busy || actProc.running || now - lastActionMs < 1500)) {
            XLog.info("vpn", "UI: action " + act + " ignored (busy or repeated within 1.5 s)");
            return;
        }
        lastActionMs = now;
        XLog.info("vpn", "UI: action " + act);
        if (fake) { console.log("xvpn(fake) action:", args.join(" ")); return; }
        busy = true;
        actProc.command = ["bash", script].concat(args);
        actProc.running = true;
    }
    function toggle() { if (connected || transitional) disconnect(); else connect(); }
    function connect(id) { run(id ? ["connect", id] : ["connect"]); }
    function disconnect() { run(["disconnect"]); }
    function switchNode(id) { run(["switch", id]); }
    function nextNode() { run(["next"]); }
    function refreshSubscription() { run(["refresh", "--force"]); }
    function pingAll() { run(["ping"]); }
    // TCP latency of the nodes (works while disconnected; the backend caches ~2 min). Does not lock the connect button.
    // "Refresh ping" button: bypass the ~2 min backend cache
    function remeasure() { XLog.info("vpn", "UI: refresh ping"); if (pingProc.running) return; pingForce = true; measure(); }
    function measure() { if (fake) { console.log("xvpn(fake) action: ping"); return; } if (!pingProc.running) pingProc.running = true; }
    // "Check again" (Happ): the status itself re-evaluates the Happ state
    function recheck() { XLog.info("vpn", "UI: recheck"); poll(); }
    function selectNode(id) { run(["select", id]); }

    // plain settings live in settings.json -> "vpn" (the python side reads them)
    function setSetting(key, value) { XLog.info("vpn", "UI: setting changed " + key);
        if (!Config.dataReady) return false;
        Config.setSetting("vpn." + key, value);
        Qt.callLater(poll);
        return true;
    }
    readonly property var cfg: (Config.rawSettings && Config.rawSettings["vpn"] && typeof Config.rawSettings["vpn"] === "object") ? Config.rawSettings["vpn"] : ({})

    Process {
        id: statusProc
        command: ["bash", root.script, "status"]
        stdout: StdioCollector { onStreamFinished: root.applyStatus(this.text.trim()) }
    }
    property bool pingForce: false
    Process {
        id: pingProc
        command: root.pingForce ? ["bash", root.script, "ping", "--force"] : ["bash", root.script, "ping"]
        onExited: { root.pingForce = false; root.poll(); }
    }
    Process {
        id: actProc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let j = JSON.parse(this.text.trim());
                    root.lastError = (j && j.ok === false) ? (j.error || "") : "";
                } catch (e) { XLog.warn("vpn", "XVpn.qml: could not parse JSON output (j)"); root.lastError = ""; }
            }
        }
        onExited: { root.busy = false; root.poll(); }
    }

    FileView {
        id: fakeView
        path: root.fake ? root.fakeFile : ""
        watchChanges: root.fake
        onFileChanged: reload()
        onLoaded: root.applyStatus(text())
    }

    Timer {
        interval: (root.connected || root.transitional) ? 3000 : 12000
        running: root.watchers > 0 && !root.fake
        repeat: true
        onTriggered: root.poll()
    }
    Timer {
        interval: 1000
        running: root.watchers > 0 && root.connected
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    Component.onCompleted: if (fake) fakeView.reload()
}
