import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."

// Always-on part of the tools: IPC entry points, the colour picker overlay, the colour history panel,
// the notes hot corner. Instantiated once from Shell.qml (the only hook outside custom/ besides the
// screenshot toolbar button).
//
//   serpantinum ipc call xtools pick      colour picker
//   serpantinum ipc call xtools colors    colour history
//   serpantinum ipc call xtools notes     open / close the notes editor
//   serpantinum ipc call xtools newNote   new note
Item {
    id: root
    visible: false

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    // tools module off (modules.json): no IPC, no picker, no notes corner.
    Loader {
        active: XModules.enabled("tools")
        sourceComponent: Component {
            Item {
                IpcHandler {
                    target: "xtools"
                    function pick(): void { picker.toggle(); }
                    function colors(): void { history.toggle(); }
                    function notes(): void { notesCorner.toggleEditor(); }
                    function newNote(): void { notesCorner.newNote(); }
                }

                ToolToast { id: toast }

                PickerOverlay {
                    id: picker
                    onPicked: (text, hex) => toast.show(root.t("tools.picker.copied", { value: text }, "Цвет скопирован: " + text),
                                                       XToolsConf.picker.history ? root.t("tools.picker.added", undefined, "добавлен в историю") : "", Qt.color(hex), "top", 2400)
                    onHistoryRequested: history.show()
                }

                ColorHistory {
                    id: history
                    onCopiedColor: (text, hex) => toast.show(root.t("tools.picker.copied", { value: text }, "Цвет скопирован: " + text), "", Qt.color(hex), "top", 2000)
                }

                NotesCorner { id: notesCorner }
            }
        }
    }

    XServersHost { id: serversHost }
    XVpnHost {}
    XCmdHost {}
}
