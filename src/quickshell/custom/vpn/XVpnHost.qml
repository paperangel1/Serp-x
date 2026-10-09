import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import "../../bar"
import ".."

// Always-on part of the VPN feature, instantiated once from XTools: registers the bar module in the
// stock BarModuleRegistry (so it shows up in the panel settings), IPC entry points and the popup.
//
//   serpantinum ipc call xvpn toggle    connect / disconnect
//   serpantinum ipc call xvpn popup     open / close the popup
//   serpantinum ipc call xvpn next      switch to the next node
//
// Commands app (action.vpn.set, scripts/custom/cmd/xcmd/vpnapi.py). The daemon runs in the user systemd manager, where
// polkit refuses to start the tunnel, so it asks the shell (which lives in the graphical session). One printed line each;
// "err:<ru text>" is an error for the user; the actions only START the work, the caller polls `status`.
//   serpantinum ipc call xvpn connect "<node name|id|empty>"   turn on (or switch when already on)
//   serpantinum ipc call xvpn disconnect                       turn off
//   serpantinum ipc call xvpn switchTo "<node name|id>"        switch the node of a running tunnel
//   serpantinum ipc call xvpn status                           {"state","node","reason","happ"} (JSON, one line)
Item {
    id: root
    visible: false

    function register() {
        if (typeof BarModuleRegistry === "undefined" || !BarModuleRegistry.registerModule) return;
        BarModuleRegistry.registerModule("vpn", {
            name: XI18n.t("vpn.module.name", undefined, "VPN"),
            icon: "󰖂",
            defaultVariant: "default",
            horizontalFace: Qt.resolvedUrl("VpnFace.qml"),
            verticalFace: Qt.resolvedUrl("SideVpnFace.qml")
        });
    }
    Component.onCompleted: register()
    // re-register when the registry is rebuilt (e.g. language change re-evaluates its names)
    Connections {
        target: XI18n
        function onTranslationsChanged() { root.register(); }
    }

    IpcHandler {
        target: "xvpn"
        function toggle(): void { XVpn.toggle(); }
        function popup(): void { XVpn.anchorX = -1; XVpn.anchorY = -1; XVpn.popupOpen = !XVpn.popupOpen; }
        function next(): void { XVpn.nextNode(); }
        function connect(node: string): string { return root.cmdConnect(node); }
        function disconnect(): string { return root.cmdDisconnect(); }
        function switchTo(node: string): string { return root.cmdSwitch(node); }
        function status(): string { return root.cmdStatus(); }
    }

    // ---- Commands app entry points
    function _resolve(q) {
        let s = String(q || "").trim().toLowerCase();
        if (s === "") return "";
        let list = XVpn.nodes || [], hits = [];
        for (let i = 0; i < list.length; i++) {
            let n = list[i];
            if (String(n.id).toLowerCase() === s || XVpn.plainName(n).toLowerCase() === s || String(n.name || "").toLowerCase() === s) return n.id;
            if (XVpn.plainName(n).toLowerCase().indexOf(s) >= 0) hits.push(n.id);
        }
        return hits.length === 1 ? hits[0] : (hits.length > 1 ? "?" : "");
    }
    function _bad(q, id) {
        return id === "?" ? "err:Название «" + q + "» подходит нескольким узлам: уточните" : "err:Узел «" + q + "» не найден в списке VPN";
    }
    function cmdStatus() {
        XVpn.poll();
        return JSON.stringify({ state: XVpn.st.state || "unknown", node: XVpn.plainName(XVpn.node), reason: XVpn.reason, happ: XVpn.happActive });
    }
    function cmdConnect(q) {
        if (XVpn.happActive) { XLog.warn("vpn", "IPC connect refused: Happ active"); return "err:Сейчас работает Happ: наш VPN не включится, пока он активен (Happ не выключается автоматически)"; }
        if (XVpn.busy || XVpn.transitional) return "err:VPN сейчас занят предыдущим действием, подождите";
        let id = _resolve(q);
        if (String(q || "").trim() !== "" && (id === "" || id === "?")) return _bad(q, id);
        XLog.info("vpn", "IPC: connect" + (id ? " (node given)" : ""));
        if (XVpn.connected) { if (id) XVpn.switchNode(id); } else XVpn.connect(id);
        return "ok";
    }
    function cmdDisconnect() {
        XLog.info("vpn", "IPC: disconnect");
        if (!XVpn.connected && !XVpn.transitional) return "ok";
        XVpn.disconnect();
        return "ok";
    }
    function cmdSwitch(q) {
        let id = _resolve(q);
        if (id === "" || id === "?") return _bad(q, id);
        if (!XVpn.connected) return "err:VPN выключен: сначала включите его, потом переключайте узел";
        XLog.info("vpn", "IPC: switch node");
        XVpn.switchNode(id);
        return "ok";
    }

    VpnPopup { id: popup }
}
