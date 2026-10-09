pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "modules.js" as Mod

// Which optional serpantinum-x modules are switched on (~/.config/serpantinum-x/modules.json, written by the
// installer). No file = everything on. Usage: `visible: XModules.enabled("ocr")`.
Item {
    id: root

    readonly property string path: Quickshell.env("X_MODULES_FILE")
        || ((Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config")) + "/serpantinum-x/modules.json")

    property var list: null     // null = no usable file = all enabled

    function enabled(id) { return Mod.isEnabled(root.list, id); }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        watchChanges: true
        onLoaded: root.list = Mod.parse(file.text())
        onLoadFailed: root.list = null
        onFileChanged: file.reload()
    }
}
