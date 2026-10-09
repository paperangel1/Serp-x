pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Bridge to the installer binary (serp-installer): "Change modules" and "Backup" buttons in the Updates tab.
// The binary is optional: installs made before the installer existed do not have it, then `available` stays
// false and the buttons are hidden. Probed with a short shell test whenever probe() is called (tab opened).
Item {
    id: root

    readonly property string binPath: (Quickshell.env("X_INSTALLER_BIN") || ((Quickshell.env("XDG_DATA_HOME")
        || ((Quickshell.env("HOME") || "") + "/.local/share")) + "/serpantinum-x/installer/serp-installer"))
    property bool available: false

    function probe() { if (!probeProc.running) probeProc.running = true; }

    // Opens the installer's module screen in a terminal.
    function openModules() {
        if (!available) { XLog.warn("installer", "XInstaller.qml: modules requested but the installer binary is missing"); return; }
        XLog.info("installer", "UI: change modules");
        Quickshell.execDetached(["kitty", "-e", root.binPath, "modules"]);
    }

    // Exports a backup through `serpantinum-x backup export` and keeps the terminal open to show the result.
    function exportBackup() {
        if (!available) { XLog.warn("installer", "XInstaller.qml: backup requested but the installer binary is missing"); return; }
        XLog.info("installer", "UI: backup export");
        Quickshell.execDetached(["kitty", "-e", "bash", "-c",
            'x="$HOME/.local/bin/serpantinum-x"; [ -x "$x" ] || x="$1/../bin/serpantinum-x"; "$x" backup export; echo; read -n 1 -s -r -p "Enter / any key"',
            "x-backup", Caching.serpantinumDir]);
    }

    Process {
        id: probeProc
        command: ["test", "-x", root.binPath]
        onExited: (code) => { root.available = code === 0; }
    }

    Component.onCompleted: probe()
}
