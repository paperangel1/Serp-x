import QtQuick
import Quickshell
import "custom"
import "custom/cmd"

// Offscreen harness for the Commands window (copied into the quickshell tree by cmd_ui_test.sh).
// HARNESS_MODE = list | examples | graph | help | fn | big | perf | gallery | galleryopen | docs | tutorial. Data comes from the real CLI pointed at fake fixtures.
ShellRoot {
    id: shell
    readonly property string mode: Quickshell.env("HARNESS_MODE") || "list"
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"

    function refByName(name) {
        for (let i = 0; i < XCmd.all.length; i++) if (XCmd.all[i].name === name) return XCmd.refOf(XCmd.all[i]);
        return "";
    }
    function refGallery(gid) { for (let i = 0; i < XCmd.galleryEx.length; i++) if (XCmd.galleryEx[i].gallery === gid) return XCmd.galleryEx[i].file; return ""; }
    function save(name, cb) {
        view.grabToImage(function(r) { r.saveToFile(shell.outDir + "/" + name + ".png"); if (cb) cb(); });
    }

    FloatingWindow {
        id: win
        visible: true
        width: 1600; height: 860
        color: "#0f0e14"
        CmdView { id: view }
        property int frames: 0
        property real maxDt: 0
        FrameAnimation { running: true; onTriggered: { win.frames++; win.maxDt = Math.max(win.maxDt, frameTime); } }

        Timer { interval: 200; running: true; onTriggered: XCmd.openWindow() }

        // list screen with the first command selected
        Timer { interval: 3500; running: shell.mode === "list"; onTriggered: { XCmd.select(shell.refByName("Наушники")); } }
        Timer { interval: 5000; running: shell.mode === "list"; onTriggered: shell.save("F_C1", function() { Qt.quit(); }) }

        // gallery of the shipped examples
        Timer { interval: 2500; running: shell.mode === "examples"; onTriggered: { XCmd.filter = "examples"; XCmd.select(shell.refByName("Перебор списка")); } }
        Timer { interval: 4500; running: shell.mode === "examples"; onTriggered: shell.save("F_C_examples", function() { Qt.quit(); }) }

        // stage 8: example gallery browser, a gallery command opened read-only, the documentation viewer, the tutorial overlay
        Timer { interval: 2500; running: shell.mode === "gallery"; onTriggered: XCmd.openGallery() }
        Timer { interval: 4000; running: shell.mode === "gallery"; onTriggered: { console.log("UI gallery n=" + XCmd.gallery.length + " cards=" + XCmd.galleryEx.length + " pending=" + XCmd.gallery.filter(g => !g.ready).length + " withpkg=" + XCmd.gallery.filter(g => g.packages.length > 0).length + " screen=" + XCmd.screen); XCmd.galleryCat = "files"; } }
        Timer { interval: 5000; running: shell.mode === "gallery"; onTriggered: shell.save("F_C7_gallery", function() { Qt.quit(); }) }
        Timer { interval: 2500; running: shell.mode === "galleryopen"; onTriggered: XCmd.openGraph(shell.refGallery("focus-25")) }
        Timer { interval: 4500; running: shell.mode === "galleryopen"; onTriggered: { const g = XCmd.graph; console.log("UI galleryopen screen=" + XCmd.screen + " example=" + view.graphView.isExample + " comments=" + (g ? g.comments.length : -1) + " name=" + (g ? g.name : "") + " firstcomment=" + (g && g.comments.length > 0 ? g.comments[0].title : "") + " issues=" + (g ? g.report.errors : -1)); } }
        Timer { interval: 5200; running: shell.mode === "galleryopen"; onTriggered: shell.save("F_C7_open", function() { Qt.quit(); }) }
        Timer { interval: 2500; running: shell.mode === "docs"; onTriggered: XCmd.openDocs("security") }
        Timer { interval: 4500; running: shell.mode === "docs"; onTriggered: console.log("UI docs screen=" + XCmd.screen + " pages=" + XCmd.docsPages.length + " id=" + XCmd.docId + " len=" + XCmd.docText.length) }
        Timer { interval: 5200; running: shell.mode === "docs"; onTriggered: shell.save("F_C7_docs", function() { Qt.quit(); }) }
        Timer { interval: 2500; running: shell.mode === "tutorial"; onTriggered: { console.log("UI tutorial offer=" + XCmdTutorial.offer + " steps=" + XCmdTutorial.steps.length); XCmdTutorial.start(); } }
        Timer { interval: 3400; running: shell.mode === "tutorial"; onTriggered: { console.log("UI tutorial active=" + XCmdTutorial.active + " step=" + XCmdTutorial.st.step + " title=" + XCmdTutorial.current.title); XCmdTutorial.notify("command_created", "", false); } }
        Timer { interval: 4000; running: shell.mode === "tutorial"; onTriggered: { console.log("UI tutorial step=" + XCmdTutorial.st.step); XCmdTutorial.notify("node_added", "action.notify@1", false); console.log("UI tutorial step=" + XCmdTutorial.st.step + " (the event step waits for Next)"); XCmdTutorial.next(); } }
        Timer { interval: 4500; running: shell.mode === "tutorial"; onTriggered: { XCmdTutorial.notify("node_added", "action.notify@1", false); console.log("UI tutorial step=" + XCmdTutorial.st.step); } }
        Timer { interval: 5400; running: shell.mode === "tutorial"; onTriggered: shell.save("F_C7_tutorial", function() { Qt.quit(); }) }

        // graph screens
        Timer { interval: 2500; running: shell.mode === "graph" || shell.mode === "help"; onTriggered: XCmd.openGraph(shell.refByName("Наушники")) }
        Timer { interval: 4800; running: shell.mode === "graph"; onTriggered: shell.save("F_C2", function() { Qt.quit(); }) }
        Timer { interval: 4600; running: shell.mode === "help"; onTriggered: view.graphView.canvasItem.selNode = "n3" }
        Timer { interval: 5400; running: shell.mode === "help"; onTriggered: shell.save("F_C5", function() { Qt.quit(); }) }

        // 200-node graph: picture + a scripted pan to measure the frame rate (offscreen, software scene graph: indicative only)
        // a collapsed function node (call node of a library function) with its generated help panel (C5)
        Timer { interval: 2500; running: shell.mode === "fn"; onTriggered: XCmd.openGraph(shell.refByName("Вечер (функция)")) }
        Timer { interval: 4600; running: shell.mode === "fn"; onTriggered: view.graphView.canvasItem.selNode = "n2" }
        Timer { interval: 5400; running: shell.mode === "fn"; onTriggered: shell.save("F_C5_fn", function() { Qt.quit(); }) }
        Timer { interval: 2500; running: shell.mode === "big" || shell.mode === "perf"; onTriggered: XCmd.openGraph(shell.refByName("Большой граф")) }
        Timer { interval: 5500; running: shell.mode === "big"; onTriggered: shell.save("F_C2_big", function() { Qt.quit(); }) }
        Timer {
            interval: 5500; running: shell.mode === "perf"
            onTriggered: {
                const cv = view.graphView.canvasItem;
                cv.zoom = 1; cv.panX = 0;
                win.frames = 0; win.maxDt = 0;
                perfAnim.start();
            }
        }
        NumberAnimation {
            id: perfAnim
            target: view.graphView.canvasItem; property: "panX"; from: 0; to: -6000; duration: 2000
            onFinished: { console.log("PERF frames=" + win.frames + " maxFrameMs=" + Math.round(win.maxDt * 1000) + " ms=2000 nodes=" + view.graphView.canvasItem.nodes.length + " wires=" + view.graphView.canvasItem.wireGeo.length); Qt.quit(); }
        }
    }
}
