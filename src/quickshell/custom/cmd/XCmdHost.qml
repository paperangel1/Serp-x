import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."

// Always-on part of the Commands feature, instantiated once from XTools (custom/tools/XTools.qml): the IPC entry
// points and the window. The engine itself is the separate process `serpantinum-cmdd` (see scripts/custom/cmd).
//
//   serpantinum ipc call xcmd open | toggle | close
//   serpantinum ipc call xcmd openCommand "<name>"      open the window straight on the graph of a command
//   serpantinum ipc call xcmd palette | paletteToggle | paletteClose   command palette (search + run; see XCmdLaunchHost.qml)
//
// Action support (stage 9a; contract in scripts/custom/cmd/xcmd-ipc.md; the logic lives in XCmdShell.qml):
//   serpantinum ipc call xcmd getDnd | setDnd <bool>          do-not-disturb
//   serpantinum ipc call xcmd getTheme | setTheme <spec>      dark / light / toggle [:scheme-x]
//   serpantinum ipc call xcmd getNightFilter | setNightFilter <spec>
//   serpantinum ipc call xcmd getBar | setBar <show|hide|toggle>   bar visibility (autohide setting)
Item {
    id: host
    visible: false

    IpcHandler {
        target: "xcmd"
        function open(): void { XCmd.openWindow(); }
        function close(): void { XCmd.closeWindow(); }
        function toggle(): void { XCmd.toggleWindow(); }
        function openCommand(name: string): void { XCmd.openCommand(name); }
        function palette(): void { XCmdLaunch.openPalette(); }
        function paletteClose(): void { XCmdLaunch.closePalette(); }
        function paletteToggle(): void { XCmdLaunch.togglePalette(); }
        function getDnd(): bool { return shellApi.getDnd(); }
        function setDnd(on: bool): void { shellApi.setDnd(on); }
        function getTheme(): string { return shellApi.getTheme(); }
        function setTheme(spec: string): string { return shellApi.setTheme(spec); }
        function getNightFilter(): string { return shellApi.getNightFilter(); }
        function setNightFilter(spec: string): string { return shellApi.setNightFilter(spec); }
        function getBar(): string { return shellApi.getBar(); }
        function setBar(spec: string): string { return shellApi.setBar(spec); }
    }

    XCmdShell { id: shellApi }

    CmdWindow { id: win }

    XCmdIdle {}

    XCmdLaunchHost {}

    // ask / show-result requests of running commands (daemon -> shell)
    XCmdBridge { id: uiBridge }
    CmdAskDialog { bridge: uiBridge }
    CmdResultPopup { bridge: uiBridge }
}
