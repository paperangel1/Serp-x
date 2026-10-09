import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import "../../widgets"
import ".."

// Always-on part of the Servers feature, instantiated once from XTools (custom/tools/XTools.qml):
//  - registers the «servers» widget type in the stock widget registry (no upstream edit),
//  - IPC entry points,
//  - the terminal and confirmation windows.
//
//   serpantinum ipc call xservers refresh                 poll the panel and the servers now
//   serpantinum ipc call xservers terminal                show / hide the last command output
//   serpantinum ipc call xservers run "<server>" <cmd>    run a command (dangerous ones still ask)
Item {
    id: host
    visible: false

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    function registerWidget() {
        if (WidgetRegistry.types && WidgetRegistry.types["servers"]) return;
        let types = Object.assign({}, WidgetRegistry.types);
        types["servers"] = {
            name: host.t("servers.widget_name", undefined, "Серверы"),
            icon: String.fromCodePoint(0xF048B),
            iconOffsetX: 0,
            defaultWidth: 320,
            defaultHeight: 360,
            defaultVariant: "compact",
            variants: {
                "compact":  { file: "../custom/servers/ServersFaceCompact.qml",  icon: "1", label: host.t("servers.variant_compact", undefined, "Список") },
                "detailed": { file: "../custom/servers/ServersFaceDetailed.qml", icon: "2", label: host.t("servers.variant_detailed", undefined, "Подробно") }
            }
        };
        WidgetRegistry.types = types;
    }
    Component.onCompleted: { registerWidget(); Qt.callLater(XServers.loadConfig); }

    IpcHandler {
        target: "xservers"
        function refresh(): void { XServers.refresh(); }
        function terminal(): void { XServers.termVisible = !XServers.termVisible; }
        function run(server: string, command: string): void {
            let want = server.toLowerCase();
            for (let i = 0; i < XServers.servers.length; i++) {
                let sv = XServers.servers[i];
                if (sv.id === server || sv.name.toLowerCase() === want) { XServers.requestRun(sv.id, command); return; }
            }
        }
    }

    ServerTerminal { id: terminalWin }
    ConfirmWindow { id: confirmWin }
}
