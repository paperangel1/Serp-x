import QtQuick
import Quickshell
import "custom"
import "guide"

// Offscreen harness for the VPN UI (copied into the quickshell tree by vpn_ui_test.sh).
// HARNESS_MODE = tab | face | popup. All state is FAKE (assigned to XVpn.st); no backend runs.
ShellRoot {
    id: shell
    readonly property string mode: Quickshell.env("HARNESS_MODE") || "tab"
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"

    function nodes() {
        return [
            { id: "n1", name: "Нидерланды-1", flag: "🇳🇱", cc: "NL", protocol: "vless", pingMs: 38, pingState: "ok", tags: [], pingAge: 12, speedMbps: 412, speedAge: 300 },
            { id: "n2", name: "Германия-1", flag: "🇩🇪", cc: "DE", protocol: "vless", pingMs: 52, pingState: "ok", tags: [], pingAge: 12, speedMbps: 366, speedAge: 300 },
            { id: "n3", name: "Финляндия-1", flag: "🇫🇮", cc: "FI", protocol: "shadowsocks", pingMs: 64, pingState: "ok", tags: [], pingAge: 12, speedMbps: 274, speedAge: 300 },
            { id: "n4", name: "Швеция-1 LTE", flag: "🇸🇪", cc: "SE", protocol: "shadowsocks", pingMs: 71, pingState: "ok", tags: ["lte"], pingAge: 12, speedMbps: null, speedAge: null },
            { id: "n5", name: "США-1", flag: "🇺🇸", cc: "US", protocol: "shadowsocks", pingMs: 148, pingState: "ok", tags: [], pingAge: 12, speedMbps: 181, speedAge: 300 },
            { id: "n6", name: "Япония-1", flag: "🇯🇵", cc: "JP", protocol: "hysteria2", pingMs: 118, pingState: "ok", tags: ["udp"], pingAge: 12, speedMbps: null, speedAge: null }
        ];
    }
    function status(state) {
        let now = Date.now() / 1000;
        let ns = nodes();
        return {
            state: state, reason: state === "failed" ? "no_connectivity" : "",
            node: { id: "n1", name: "Нидерланды-1", flag: "🇳🇱", cc: "NL", protocol: "vless" },
            since: state === "on" ? now - 2537 : 0,
            mode: "ru-direct", killSwitch: false, blockIPv6: true, autoDisable: true,
            nodes: ns,
            traffic: { used: 40802189312, total: 214748364800, expire: now + 37 * 86400 },
            subscription: { configured: true, display: "https://panel.example/••••••••••••", updated: now - 7200, count: 6, kind: "links", title: "", intervalHours: 6 },
            ping: { method: "httpGet", display: "digits", timeout: 3, url: "https://www.gstatic.com/generate_204" },
            geo: { present: true, updated: now - 30 * 86400 },
            core: { path: "/usr/bin/xray", version: "26.3.27", exists: true, tun: true, hysteria: true },
            service: { installed: true, active: state === "on", polkit: true, unit: "serp-xray.service" },
            happActive: false, rxBytes: 0, txBytes: 0, ts: now, degraded: []
        };
    }
    function save(item, name, cb) {
        item.grabToImage(function(r) { r.saveToFile(shell.outDir + "/" + name + ".png"); if (cb) cb(); });
    }

    // ---- tab: the real settings window with the real GuideExtensions ----
    FloatingWindow {
        id: tabWin
        visible: shell.mode === "tab"
        width: 1200; height: 750
        color: "#0f0e14"
        Rectangle { id: tabBox; anchors.fill: parent; color: "#0f0e14"
            GuidePopup { id: gp; anchors.fill: parent; visible: true }
        }
        Timer { interval: 3500; running: shell.mode === "tab"; onTriggered: { XVpn.st = shell.status("on"); gp.gotoTab("vpn"); } }
        Timer { interval: 5500; running: shell.mode === "tab"; onTriggered: shell.save(tabBox, "F_V3", function() { Qt.quit(); }) }
    }

    // ---- face: the bar module in its three states ----
    FloatingWindow {
        id: faceWin
        visible: shell.mode === "face"
        width: 420; height: 52
        color: "transparent"
        Rectangle {
            id: bar
            anchors.fill: parent
            color: ThemeBackend.crust
            QtObject { id: fakeModule; property bool isCompact: false; property bool moduleActive: true; property var barWindow: null }
            VpnFace {
                id: face
                module: fakeModule
                width: targetWidth; height: 38
                anchors.centerIn: parent
            }
        }
        property int step: 0
        Timer { id: quitTimer; interval: 800; onTriggered: Qt.quit() }
        // even step: apply the next state; odd step: grab it (the pill needs ~700 ms to settle)
        Timer {
            interval: 1300; repeat: true; running: shell.mode === "face"
            onTriggered: {
                let seq = ["on", "off", "failed"];
                let i = Math.floor(faceWin.step / 2);
                if (faceWin.step % 2 === 0) {
                    if (i >= seq.length) { quitTimer.start(); running = false; return; }
                    XVpn.st = shell.status(seq[i]);
                    XVpn.speedDown = seq[i] === "on" ? 12.4 * 1048576 : 0;
                } else {
                    shell.save(bar, "face_" + seq[i], null);
                }
                faceWin.step++;
            }
        }
    }

    // ---- popup: the panel pinned at (0,0) ----
    FloatingWindow {
        id: popWin
        visible: shell.mode === "popup"
        width: 440; height: 700
        color: ThemeBackend.crust
        Rectangle { id: popBox; anchors.fill: parent; color: ThemeBackend.crust
        VpnPopupView {
            id: pop
            anchors.fill: parent
            inline: true; open: true
            dlHist: [3, 5, 4, 8, 6, 9, 12, 10, 14, 13, 12, 15, 11, 13, 16, 18, 14, 12, 15, 17, 19, 16, 13, 12, 14, 15].map(function(v) { return v * 1048576 * 0.8; })
            ulHist: [1, 1, 2, 1, 1, 3, 2, 1, 1, 2, 1, 1, 2, 3, 1, 1, 2, 1, 1, 1, 2, 1, 2, 1, 1, 1].map(function(v) { return v * 1048576 * 0.08; })
        }
        }
        Timer { interval: 3000; running: shell.mode === "popup"; onTriggered: { XVpn.st = shell.status("on"); XVpn.speedDown = 12.4 * 1048576; XVpn.speedUp = 1.2 * 1048576; XVpn.nowMs = Date.now(); } }
        Timer { interval: 4600; running: shell.mode === "popup"; onTriggered: shell.save(popBox, "F_V2", function() { Qt.quit(); }) }
    }

    // ---- ping: every display mode and state, checked through the popup's own functions ----
    FloatingWindow {
        id: pingWin
        visible: shell.mode === "ping"
        width: 440; height: 700
        color: ThemeBackend.crust
        Rectangle { id: pingBox; anchors.fill: parent; color: ThemeBackend.crust
            VpnPopupView { id: pp; anchors.fill: parent; inline: true; open: true }
        }
        property var sample: [
            { id: "a", name: "A", protocol: "vless", pingMs: 21, pingState: "ok", tags: [] },
            { id: "b", name: "B", protocol: "vless", pingMs: 250, pingState: "ok", tags: [] },
            { id: "c", name: "C", protocol: "vless", pingMs: 900, pingState: "ok", tags: [] },
            { id: "d", name: "D", protocol: "vless", pingMs: null, pingState: "timeout", tags: [] },
            { id: "e", name: "E", protocol: "vless", pingMs: null, pingState: "error", tags: [] },
            { id: "f", name: "F", protocol: "hysteria2", pingMs: null, pingState: "na", tags: ["udp"] },
            { id: "g", name: "G", protocol: "vless", pingMs: null, pingState: "measuring", tags: [] }
        ]
        property int step: 0
        Timer {
            interval: 700; repeat: true; running: shell.mode === "ping"
            onTriggered: {
                let modes = ["digits", "bars", "barsDigits", "dots"];
                let i = pingWin.step++;
                if (i >= modes.length) { Qt.quit(); return; }
                let st = shell.status("on");
                st.nodes = pingWin.sample;
                st.ping.display = modes[i];
                XVpn.st = st;
                Qt.callLater(function() {
                    let out = pingWin.sample.map(function(n) { return pp.pingText(n); }).join(" | ");
                    console.log("PINGTEXT " + modes[i] + ": " + out + " || hint=" + pp.nodeHint(pingWin.sample[5]));
                    shell.save(pingBox, "ping_" + modes[i], null);
                });
            }
        }
    }
}
