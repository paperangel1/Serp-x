pragma Singleton
import QtQuick
import "../../"
import ".."
import "EditorLogic.js" as EL

// First-launch tutorial of the Commands window. The steps are data (tutorial.json, delivered by `ui-list`), the progress is
// persisted by the CLI (`tutorial set`). The editor reports what the user does through notify(); the pure transitions live in
// EditorLogic.js (tutAdvance & co, covered by editor_logic_test). TutorialOverlay draws the card and the highlight ring.
Item {
    id: root
    visible: false

    property var steps: []
    property var st: EL.tutState(null)
    property bool loaded: false
    property var targets: ({})                   // target name -> Item registered by the window parts
    readonly property bool active: st.active
    readonly property var current: st.active && st.step < steps.length ? steps[st.step] : null
    // «Хотите пройти обучение?» on the very first opening of the window
    readonly property bool offer: loaded && steps.length > 0 && EL.tutOffer(st) && XCmd.open && XCmd.dialog === null

    function load(d) {                           // from ui-list; the first load restores the saved progress, later ones keep it
        root.steps = (d && d.steps) || [];
        if (!root.loaded && d) { root.st = EL.tutState(d.state); root.loaded = true; }
    }
    function reg(name, item) { const t = Object.assign({}, root.targets); t[name] = item; root.targets = t; }
    function apply(ns, why) {
        if (JSON.stringify(ns) === JSON.stringify(root.st)) return;
        root.st = ns;
        XLog.info("cmd", "UI: tutorial " + why + " step=" + ns.step + (ns.done ? " done" : "") + (ns.skipped ? " skipped" : ""));
        XCmd.cli(EL.tutPersist(ns), function (r) {}, function (m) {});
    }
    function start() { root.apply(EL.tutStart(), "start"); }
    function replay() { XCmd.dialog = null; root.apply(EL.tutStart(), "replay"); }
    function next() { root.apply(EL.tutNext(root.st, root.steps), "next"); }
    function back() { root.apply(EL.tutBack(root.st, root.steps), "back"); }
    function skip() { root.apply(EL.tutSkip(root.st), "skip"); }
    function notify(kind, type, exec) { if (root.st.active) root.apply(EL.tutAdvance(root.st, root.steps, { kind: kind, type: type || "", exec: !!exec }), kind); }
}
