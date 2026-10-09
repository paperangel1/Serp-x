import QtQuick
import Quickshell
import "custom"
import "custom/cmd"

// Offscreen harness for the debug overlay (copied into the quickshell tree by cmd_ui_test.sh): the real Commands window
// against fixture commands (real CLI) and a FAKE daemon (cmd_ui/fake_trace_daemon.py) that pushes a recorded trace.
// Prints DEBUG lines that the shell script checks; saves F_C3.png.
ShellRoot {
    id: shell
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    function refByName(name) {
        for (let i = 0; i < XCmd.all.length; i++) if (XCmd.all[i].name === name) return XCmd.refOf(XCmd.all[i]);
        return "";
    }
    FloatingWindow {
        id: win
        visible: true; width: 1600; height: 860; color: "#0f0e14"
        CmdView { id: view }
        Timer { interval: 200; running: true; onTriggered: XCmd.openWindow() }
        Timer { interval: 2500; running: true; onTriggered: { XCmd.openGraph(shell.refByName("Наушники")); } }
        Timer { interval: 3500; running: true; onTriggered: { XCmdDebug.toggleBp(XCmd.selectedRef, "n4"); XCmdDebug.panelOpen = true; console.log("DEBUG connected=" + XCmdDebug.connected); } }
        // wait for the 4 s socket probe, then rehearse
        Timer { interval: 8000; running: true; onTriggered: { console.log("DEBUG start connected=" + XCmdDebug.connected + " ref=" + XCmd.selectedRef + " sel=" + (XCmd.selected ? XCmd.selected.name + "/" + XCmd.selected.example : "null") + " screen=" + XCmd.screen + " g=" + (XCmd.graph !== null) + " editing=" + XCmd.editing); XCmdDebug.start("rehearse", false); } }
        Timer { interval: 10500; running: true
            onTriggered: {
                const ov = XCmdDebug.ov, cv = view.graphView.canvasItem, st = id => ov.nodes[id] ? ov.nodes[id].state.replace("error", "bad") : "-";
                console.log("DEBUG states n1=" + st("n1") + " n2=" + st("n2") + " n3=" + st("n3") + " n4=" + st("n4"));
                console.log("DEBUG run=" + ov.run + " status=" + ov.status + " live=" + ov.live + " rehearse=" + ov.rehearse + " steps=" + ov.steps.length + " vars=" + Object.keys(ov.vars).length);
                console.log("DEBUG failure=" + (ov.error ? ov.error.node + ":" + ov.error.message : "none") + " busy=" + XCmdDebug.busy);
                console.log("DEBUG wires=" + Object.keys(ov.wires).sort().join(","));
                console.log("DEBUG panel=" + view.graphView.debugOpen + " errbox=" + view.graphView.tracePanelItem.errorBox.visible + " badge=" + (cv.dbgOn));
                cv.hoverNode = "n2";
                view.graphView.tracePanelItem.focusNode("n3");
            }
        }
        Timer { interval: 11500; running: true
            onTriggered: {
                console.log("DEBUG tooltip=" + view.graphView.hoverRows.length + " sel=" + view.graphView.canvasItem.selNode);
                view.grabToImage(function(r) { r.saveToFile(shell.outDir + "/F_C3.png"); Qt.quit(); });
            }
        }
        Timer { interval: 40000; running: true; onTriggered: Qt.quit() }
    }
}
