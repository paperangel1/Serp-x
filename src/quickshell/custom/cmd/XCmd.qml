pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import ".."
import "EditorLogic.js" as EL

// State of the Commands window. Data comes from `x_cmd.sh ui-list` / `ui-get` / `ui-schema` (one JSON document per call;
// works with the daemon or in-process); every change goes through the same CLI (`save`, `new`, `rename`, `delete`, ...), so
// the window never touches command files itself. Tests point the CLI at temp dirs through the XCMD_* environment.
Item {
    id: root
    visible: false

    readonly property string script: Caching.serpantinumDir + "/scripts/custom/cmd/x_cmd.sh"
    readonly property string lang: (I18n.currentLang || "ru").indexOf("ru") === 0 ? "ru" : "en"

    property bool open: false
    property string screen: "list"           // list | graph
    property string filter: "all"            // all | manual | auto | examples | trash
    property string query: ""
    property var commands: []
    property var examples: []
    property var gallery: []                 // example gallery cards (ui-list "gallery")
    property var docsPages: []               // [{id, title, group}] of the documentation viewer
    property string docId: ""
    property string docText: ""
    property bool docLoading: false
    property string galleryCat: "all"
    property var trash: []
    property var errors: ({})
    property bool pausedAll: false
    property string mode: "local"            // daemon | local
    property var service: ({})
    property bool loaded: false
    property bool loading: false
    property string error: ""
    property string selectedRef: ""          // id of a user command or file path of an example
    property var graph: null
    property bool graphLoading: false
    property string toast: ""
    property real toastUntil: 0
    property var toastAction: null           // {label, run} shown next to the toast (e.g. "Вернуть")

    // editor
    property bool editing: false
    property var baseCatalog: ({})           // type string -> editor catalogue entry (ui-schema)
    property var ifaceCatalog: ({})          // «Вход/Выход функции» of the function graph being edited
    readonly property var catalog: Object.keys(ifaceCatalog).length > 0 ? Object.assign({}, baseCatalog, ifaceCatalog) : baseCatalog
    property var functions: []               // the function library (fn list)
    property var helpById: ({})              // node id -> help (ui-schema nodes)
    property var dialog: null                // modal dialog of the window: {kind: new|rename|delete|import|export|permission|unsaved|imported, ...}
    property string pendingEdit: ""

    // gallery commands are read-only «examples» for the graph screen: they open from their files like the plain examples
    readonly property var galleryEx: gallery.map(g => ({ id: "gallery-" + g.id, gallery: g.id, name: g.name, description: g.description, example: true,
        file: g.file, enabled: false, imported: false, kind: "manual", triggers: [], nodes: g.nodes, errors: 0, warnings: 0,
        capabilities: g.capabilities, caps: [], approved: false, icon: "", policy: ({}) }))
    readonly property var all: commands.concat(examples).concat(galleryEx)
    function refOf(c) { return c.example ? c.file : c.id; }
    function find(ref) { for (let i = 0; i < all.length; i++) if (refOf(all[i]) === ref) return all[i]; return null; }
    readonly property var selected: find(selectedRef)
    function matches(c) {
        let q = query.trim().toLowerCase();
        if (q === "") return true;
        return (c.name + " " + c.description + " " + (c.triggers || []).join(" ")).toLowerCase().indexOf(q) >= 0;
    }
    function listFor(kind) {
        let src = filter === "examples" ? examples : commands;
        return src.filter(c => (kind === "" || c.kind === kind) && matches(c));
    }
    readonly property int nManual: commands.filter(c => c.kind === "manual").length
    readonly property int nAuto: commands.filter(c => c.kind === "auto").length
    readonly property int nAutoOn: commands.filter(c => c.kind === "auto" && c.enabled).length
    function helpFor(type) { return helpById[(type || "").split("@")[0]] || null; }

    function openWindow() { XLog.info("cmd", "UI: window opened"); open = true; refresh(); if (Object.keys(catalog).length === 0) reloadSchema(); }
    function closeWindow() { open = false; screen = "list"; dialog = null; if (editing) stopEdit(); }
    function toggleWindow() { if (open) closeWindow(); else openWindow(); }
    function openCommand(name) {
        openWindow();
        pendingOpen = name;
    }
    property string pendingOpen: ""

    function refresh() {
        if (loading) return;
        loading = true;
        listProc.running = true;
    }
    function applyList(text) {
        loading = false;
        try {
            let d = JSON.parse(text);
            commands = d.commands || [];
            examples = d.examples || [];
            gallery = d.gallery || [];
            docsPages = d.docs || [];
            XCmdTutorial.load(d.tutorial);
            functions = d.functions || [];
            trash = d.trash || [];
            errors = d.errors || ({});
            pausedAll = !!d.paused_all;
            mode = d.mode || "local";
            service = d.service || ({});
            loaded = true;
            error = "";
            if (pendingOpen !== "") {
                let want = pendingOpen.toLowerCase(); pendingOpen = "";
                for (let i = 0; i < commands.length; i++)
                    if (commands[i].id.toLowerCase() === want || commands[i].name.toLowerCase() === want) { openGraph(refOf(commands[i])); return; }
                showToast(XI18n.t("cmd.toast.not_found", { name: want }, "Команда не найдена: " + want));
            }
            if (filter === "trash" && trash.length === 0) filter = "all";
            if (editing) return;
            if (selectedRef === "" || find(selectedRef) === null) {
                let first = commands.length > 0 ? commands[0] : (examples.length > 0 ? examples[0] : null);
                select(first ? refOf(first) : "");
            } else if (graph === null) {
                select(selectedRef);
            }
        } catch (e) {
            error = XI18n.t("cmd.error.list", undefined, "Не удалось прочитать список команд");
            loaded = true;
        }
    }
    function select(ref, quiet) {
        selectedRef = ref;
        if (!quiet) graph = null;
        if (ref === "") return;
        pendingGraph = ref;
        graphLoading = !quiet;
        graphProc.command = ["bash", script, "ui-get", ref, "--lang", lang];
        graphProc.running = true;
    }
    property string pendingGraph: ""
    function applyGraph(text) {
        graphLoading = false;
        try {
            let g = JSON.parse(text);
            if (g.id !== undefined && (pendingGraph === (g.file || g.id) || pendingGraph === g.id)) {
                graph = g;
                if (pendingEdit !== "" && (pendingEdit === g.id || pendingEdit === g.file)) {
                    pendingEdit = "";
                    screen = "graph";
                    startEdit();
                }
            }
        } catch (e) { graph = null; }
    }
    function openGraph(ref) {
        if (ref !== selectedRef || graph === null) select(ref);
        screen = "graph";
    }
    function closeGraph() { if (editing) { leaveEditor(); return; } screen = "list"; }

    // ---- editor entry / exit ----------------------------------------------------------------------------------
    function openEditor(ref) {      // open a user command straight in edit mode
        const c = find(ref);
        if (c && c.example) return;
        pendingEdit = ref;
        if (ref === selectedRef && graph !== null && graph.id !== undefined && !graph.file) { pendingEdit = ""; screen = "graph"; startEdit(); }
        else select(ref);
    }
    function startEdit() {
        if (graph === null || graph.file) return;      // examples (graph.file) are read-only
        XEdit.begin(graph);
        editing = true;
    }
    function stopEdit() {
        if (XEdit.mode === "function") { popFunction(); return; }
        const id = XEdit.command && XEdit.command.id ? XEdit.command.id : selectedRef;
        XEdit.end();
        editing = false;
        if (id) select(id, true);
        refresh();
    }
    function leaveEditor() {      // back button / Esc in the editor
        if (!editing) { screen = "list"; return; }
        if (XEdit.mode === "function") { closeFunctionEditor(); return; }
        if (XEdit.dirty) { dialog = { kind: "unsaved" }; return; }
        stopEdit();
        screen = "list";
    }
    function afterSave(res) {
        if (XEdit.mode === "function") {
            showToast(XI18n.t("cmd.fn.saved", { name: res.name }, "Функция сохранена: " + res.name));
            reloadSchema(); refresh();
            return;
        }
        showToast(XI18n.t("cmd.toast.saved", { name: res.name }, "Сохранено: " + res.name));
        selectedRef = res.id;
        refresh();
        select(res.id, true);
    }

    // ---- functions (custom nodes) -------------------------------------------------------------------------------
    property var schemaDone: null
    function reloadSchema(done) {            // the catalogue carries the function library: reload after every change of it
        schemaDone = done || null;
        schemaProc.running = true;
    }
    function fnById(fid) { for (let i = 0; i < functions.length; i++) if (functions[i].id === fid) return functions[i]; return null; }
    function fnIdOfType(type) { const b = (type || "").split("@")[0]; return b.indexOf("fn.") === 0 ? b.slice(3) : ""; }
    // «Свернуть в узел»: the pins are inferred by EditorLogic from the wires crossing the selection; the engine stores the function
    function collapseSelection() {
        if (!editing || XEdit.sel === null) return;
        const r = EL.collapseSelection(XEdit.command, catalog, XEdit.sel.nodes, { name: "", description: "" });
        if (!r.ok) { showToast(r.reason); return; }
        const tn = p => Object.assign({ tn: EL.typeName(p.type, lang) }, p);
        dialog = { kind: "fn_collapse", pins: { inputs: r.pins.inputs.map(tn), outputs: r.pins.outputs.map(tn), exec: r.pins.exec }, count: r.count, warnings: r.warnings, name: "" };
    }
    function collapseConfirm(name, description) {
        const nm = (name || "").trim();
        if (nm === "") return;
        const r = EL.collapseSelection(XEdit.command, catalog, XEdit.sel.nodes, { name: nm, description: description || "" });
        if (!r.ok) { dialogError(r.reason); return; }
        XLog.info("cmd", "UI: collapse into function name=" + nm + " nodes=" + r.count);
        cli(["fn", "create", "--name", nm, "--fn-json", JSON.stringify(r.fn)], res => {
            reloadSchema(() => {                      // the call node type must be in the catalogue before it is drawn
                const a = EL.applyCollapse(XEdit.command, r.plan, res.type);
                XEdit.commit(a.cmd);                  // ONE undo step: the group is replaced by the call node
                XEdit.setSel(({ [a.id]: true }), ({}), ({}));
                dialog = null;
                refresh();
                showToast(XI18n.t("cmd.fn.collapsed", { name: res.name }, "Создана функция «" + res.name + "»"));
            });
        }, msg => dialogError(msg));
    }
    function expandSelected() {
        const ids = Object.keys(XEdit.sel.nodes);
        if (!editing || ids.length !== 1) return;
        const n = EL.findNode(XEdit.command, ids[0]), fid = n ? fnIdOfType(n.type) : "";
        if (fid === "") return;
        XLog.info("cmd", "UI: expand function call fn=" + fid);
        cli(["fn", "show", fid], fn => {
            const r = EL.expandCall(XEdit.command, catalog, ids[0], fn);
            if (!r.ok) { showToast(r.reason); return; }
            XEdit.commit(r.cmd);
            XEdit.setSel(r.ids, ({}), ({}));
            if (r.warnings.length > 0) showToast(XI18n.t("cmd.fn.expand_vars", undefined, "Переменные функции добавлены в команду; одноимённые остались общими"));
        }, msg => showToast(msg));
    }
    property bool fnStandalone: false        // a function opened from the library (no command editing underneath)
    function openFunctionOfType(type) { const f = fnIdOfType(type); if (f !== "") openFunction(f); }
    function editSelectedFunction() {
        const ids = Object.keys(XEdit.sel.nodes);
        if (ids.length !== 1) return;
        const n = EL.findNode(XEdit.command, ids[0]);
        if (n) openFunctionOfType(n.type);
    }
    // «Редактировать функцию»: the function graph opens in the same canvas; the command stays underneath (breadcrumbs back)
    function openFunction(fid) {
        XLog.info("cmd", "UI: open function fn=" + fid);
        fnLoadProc.fid = fid;
        fnLoadProc.command = ["bash", script, "ui-fn-get", fid, "--lang", lang];
        fnLoadProc.running = true;
    }
    function applyFunctionGraph(g) {
        if (!editing) {                          // from the library or the viewer
            fnStandalone = true;
            graph = g;
            screen = "graph";
            XEdit.begin(g);
            XEdit.setFunctionMode(g, null);
            editing = true;
        } else {
            if (XEdit.mode === "function" && XEdit.fnStack.length > 2) { showToast(XI18n.t("cmd.fn.too_deep", undefined, "Слишком глубокая вложенность")); return; }
            const parent = XEdit.snapshot();
            XEdit.begin(g);
            XEdit.setFunctionMode(g, parent);
        }
        ifaceCatalog = EL.indexCatalog(g.iface_catalog || []);
    }
    function closeFunctionEditor() {             // breadcrumb «команда ›»
        if (XEdit.mode !== "function") return;
        if (XEdit.dirty) { dialog = { kind: "fn_unsaved" }; return; }
        popFunction();
    }
    function popFunction() {
        const hadParent = XEdit.fnStack.length > 0;
        if (hadParent) {
            XEdit.restore(XEdit.fnStack[XEdit.fnStack.length - 1]);
            const top = XEdit.mode === "function" && XEdit.fnIface ? EL.indexCatalog(XEdit.fnIface) : ({});
            ifaceCatalog = top;
            reloadSchema();                      // the interface or capabilities of the function may have changed
        } else {
            XEdit.end(); editing = false; fnStandalone = false; ifaceCatalog = ({});
            graph = null; screen = "list"; filter = "functions"; reloadSchema(); refresh();
        }
    }
    function fnRename(ref, name) {
        cli(["fn", "rename", ref, name], r => {
            dialog = null; reloadSchema(); refresh();
            if (editing && XEdit.mode === "function" && XEdit.command.id === r.id) XEdit.setName(r.name);
        }, msg => dialogError(msg));
    }
    function fnDuplicate(ref) {
        cli(["fn", "duplicate", ref], r => { reloadSchema(); refresh(); showToast(XI18n.t("cmd.fn.duplicated", { name: r.name }, "Копия функции: " + r.name)); }, msg => showToast(msg));
    }
    function fnAskDelete(ref) {
        cli(["fn", "usages", ref], r => { const f = fnById(ref); dialog = { kind: "fn_delete", ref: ref, name: f ? f.name : ref, usages: r.usages || [] }; }, msg => showToast(msg));
    }
    function fnDelete(ref) {
        cli(["fn", "delete", ref], r => { dialog = null; reloadSchema(); refresh();
                                          showToast(XI18n.t("cmd.fn.deleted", { name: r.deleted, days: r.keep_days }, "Функция «" + r.deleted + "» удалена: хранится в корзине " + r.keep_days + " дн.")); },
            msg => dialogError(msg));
    }
    function fnExport(ref, path) {
        cli(["fn", "export", ref, path], r => { dialog = null; showToast(XI18n.t("cmd.toast.exported", { path: r.path }, "Экспортировано: " + r.path)); }, msg => dialogError(msg));
    }
    function fnImport(path) {
        cli(["fn", "import", path], r => {
            dialog = null; reloadSchema(); refresh(); filter = "functions";
            const renamed = (r.functions || []).filter(i => i.status === "renamed");
            showToast(renamed.length > 0 ? XI18n.t("cmd.fn.imported_conflict", { name: r.name }, "Импортировано «" + r.name + "»: есть конфликт имён, локальные функции не тронуты")
                                         : XI18n.t("cmd.fn.imported", { name: r.name }, "Импортирована функция «" + r.name + "»"));
        }, msg => dialogError(msg));
    }

    // ---- CLI calls (serialised) -------------------------------------------------------------------------------
    property var cliQueue: []
    property var cliCur: null
    property string cliOut: ""
    property string cliErr: ""
    property int cliCode: 0
    function cli(args, ok, fail) {
        cliQueue = cliQueue.concat([{ args: args, ok: ok, fail: fail }]);
        cliNext();
    }
    function cliNext() {
        if (cliCur !== null || cliQueue.length === 0) return;
        cliCur = cliQueue[0];
        cliQueue = cliQueue.slice(1);
        cliOut = ""; cliErr = "";
        cliProc.command = ["bash", script, "--json"].concat(cliCur.args);
        cliProc.running = true;
    }
    function cliFinish() {
        const cur = cliCur;
        cliCur = null;
        let res = null;
        try { res = JSON.parse(cliOut); } catch (e) { XLog.warn("cmd", "XCmd.qml: could not parse JSON output (res)"); res = null; }
        if (cliCode === 0 && res !== null) { if (cur.ok) cur.ok(res); }
        else {
            let msg = XI18n.t("cmd.error.cli", undefined, "Не удалось выполнить действие");
            try { const e = JSON.parse(cliErr); if (e.message) msg = e.message; } catch (e) { XLog.warn("cmd", "XCmd.qml: could not parse JSON output (e)"); if (cliErr.trim() !== "") msg = cliErr.trim().split("\n")[0]; }
            if (cur.fail) cur.fail(msg); else showToast(msg);
        }
        cliNext();
    }
    function dialogError(msg) { if (dialog !== null) { const d = Object.assign({}, dialog); d.error = msg; dialog = d; } else showToast(msg); }

    // ---- command management -----------------------------------------------------------------------------------
    function createCommand(name, fromRef) { XLog.info("cmd", "UI: create command name=" + name + (fromRef ? " from=" + fromRef : ""));
        let args = ["new", "--name", name];
        const c = fromRef ? find(fromRef) : null;
        if (c && c.example) args = args.concat(["--from", c.file]);
        cli(args, r => { dialog = null; openEditor(r.id); refresh(); XCmdTutorial.notify("command_created", "", false); },
            msg => dialogError(msg));
    }
    // ---- example gallery and documentation (stage 8) -----------------------------------------------------------
    function openGallery() { XLog.info("cmd", "UI: gallery opened"); screen = "gallery"; }
    function openDocs(id) { XLog.info("cmd", "UI: docs opened"); screen = "docs"; loadDoc(id || docId || "index"); }
    function closeSub() { screen = "list"; }
    function loadDoc(id) {
        docId = id; docLoading = true;
        docProc.command = ["bash", script, "docs", "--lang", lang, "--page", id];
        docProc.running = true;
    }
    function addGallery(gid) {               // «Добавить в мои команды»: a disabled copy, rights not approved
        XLog.info("cmd", "UI: gallery add " + gid);
        cli(["gallery", "add", gid, "--lang", lang], r => {
            filter = "all"; screen = "list"; refresh(); select(r.id);
            showToast(r.ready ? XI18n.t("cmd.gallery.added", { name: r.name }, "Добавлено: " + r.name)
                              : XI18n.t("cmd.gallery.added_pending", { name: r.name, nodes: r.missing.length }, "Добавлено: " + r.name + ". Запуск появится вместе с узлами: " + r.missing.length));
        }, msg => showToast(msg));
    }
    function copyExample(ref) {     // «Добавить в мои команды»
        const c = find(ref);
        if (!c || !c.example) return;
        if (c.gallery) { addGallery(c.gallery); return; }
        cli(["list"], l => {
            const taken = (l.commands || []).map(x => x.name.toLowerCase());
            let name = c.name, n = 2;
            while (taken.indexOf(name.toLowerCase()) >= 0) name = c.name + " " + (n++);
            cli(["new", "--name", name, "--from", c.file], r => { filter = "all"; openEditor(r.id); refresh(); }, msg => showToast(msg));
        }, msg => showToast(msg));
    }
    function duplicateCommand(ref) { XLog.info("cmd", "UI: duplicate command ref=" + ref);
        const c = find(ref);
        if (!c || c.example) return;
        cli(["duplicate", c.name], r => { showToast(XI18n.t("cmd.toast.duplicated", { name: r.name }, "Копия создана: " + r.name)); selectedRef = r.id; refresh(); select(r.id); },
            msg => showToast(msg));
    }
    function renameCommand(ref, name) {
        const c = find(ref);
        if (!c) return;
        cli(["rename", c.name, name], r => {
            dialog = null;
            if (editing && XEdit.command && XEdit.command.id === c.id) XEdit.setName(r.name);   // keep the open document in step
            refresh(); select(r.id, true);
        }, msg => dialogError(msg));
    }
    function deleteCommand(ref) { XLog.info("cmd", "UI: delete command ref=" + ref);
        const c = find(ref);
        if (!c || c.example) return;
        cli(["delete", c.name], r => {
            dialog = null;
            if (editing) { XEdit.end(); editing = false; }
            screen = "list"; graph = null; selectedRef = "";
            refresh();
            showToast(XI18n.t("cmd.toast.deleted", { name: r.deleted, days: r.keep_days }, "Удалена «" + r.deleted + "». Хранится в корзине " + r.keep_days + " дн."), 9000,
                      { label: XI18n.t("cmd.toast.undo", undefined, "Вернуть"), run: () => restoreCommand(r.id) });
        }, msg => dialogError(msg));
    }
    function restoreCommand(idOrName) {
        cli(["restore", idOrName], r => { toast = ""; toastAction = null; filter = "all"; refresh(); select(r.id);
                                          showToast(XI18n.t("cmd.toast.restored", { name: r.name }, "Восстановлена: " + r.name)); }, msg => showToast(msg));
    }
    function importFile(path) {
        cli(["import", path], r => {
            dialog = null;
            refresh();
            if ((r.suspicious && r.suspicious.length > 0) || (r.warnings && r.warnings.length > 0)) dialog = { kind: "imported", result: r };
            else showToast(XI18n.t("cmd.toast.imported", { name: r.command }, "Импортирована «" + r.command + "»: выключена, права не подтверждены"));
            filter = "all"; selectedRef = r.id; select(r.id);
        }, msg => dialogError(msg));
    }
    function exportCommand(ref, path) {
        const c = find(ref);
        if (!c || c.example) return;
        cli(["export", c.name, path], r => { dialog = null; showToast(XI18n.t("cmd.toast.exported", { path: r.path }, "Экспортировано: " + r.path)); },
            msg => dialogError(msg));
    }
    function setEnabled(ref, on) {
        const c = find(ref);
        if (!c || c.example) return;
        if (on && !c.approved) {
            dialog = { kind: "permission", ref: ref, name: c.name, caps: c.caps || [] };
            return;
        }
        cli([on ? "enable" : "disable", c.name], r => { refresh(); if (selectedRef === ref) select(ref, true); }, msg => showToast(msg));
    }
    function approveAndEnable(ref) { XLog.info("cmd", "UI: approve and enable ref=" + ref);
        const c = find(ref);
        if (!c) return;
        cli(["approve", c.name, "--yes"], r => cli(["enable", c.name], r2 => { dialog = null; refresh(); select(ref, true); }, msg => dialogError(msg)),
            msg => dialogError(msg));
    }
    function togglePin(id) {      // star in the list: pinned commands lead the palette, the bar menu and the widget
        const c = commands.find(x => x.id === id);
        if (!c) return;
        const on = !c.pinned;
        XLog.info("cmd", "UI: " + (on ? "pin" : "unpin") + " id=" + id);
        commands = commands.map(x => x.id === id ? Object.assign({}, x, { pinned: on }) : x);
        cli([on ? "pin" : "unpin", id], r => refresh(), msg => { showToast(msg); refresh(); });
    }
    function setPaused(on) { cli([on ? "pause" : "resume"], r => { pausedAll = !!r.paused_all; refresh(); }, msg => showToast(msg)); }

    function run(ref) { XLog.info("cmd", "UI: run requested ref=" + ref);
        let c = find(ref);
        if (!c || c.example) return;
        runProc.command = ["bash", script, "--json", "run", c.name];
        runProc.running = true;
        showToast(XI18n.t("cmd.toast.started", { name: c.name }, "Запущено: " + c.name));
    }

    function when(ts) {
        if (!ts) return "";
        const d = new Date(ts * 1000), now = new Date();
        const hm = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
        const day = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        if (d.getTime() >= day) return XI18n.t("cmd.time.today", undefined, "сегодня") + " " + hm;
        if (d.getTime() >= day - 86400000) return XI18n.t("cmd.time.yesterday", undefined, "вчера") + " " + hm;
        return ("0" + d.getDate()).slice(-2) + "." + ("0" + (d.getMonth() + 1)).slice(-2) + " " + hm;
    }
    function showToast(text, ms, action) {
        toast = text; toastAction = action || null; toastUntil = Date.now() + (ms || 3000);
        toastTimer.interval = (ms || 3000) + 100; toastTimer.restart();
    }

    Process {
        id: listProc
        command: ["bash", root.script, "ui-list", "--lang", root.lang]
        stdout: StdioCollector { onStreamFinished: root.applyList(this.text) }
        onExited: (code) => { if (code !== 0) { root.loading = false; if (!root.loaded) { root.error = XI18n.t("cmd.error.list", undefined, "Не удалось прочитать список команд"); root.loaded = true; } } }
    }
    Process {
        id: docProc
        stdout: StdioCollector { onStreamFinished: { root.docText = this.text; root.docLoading = false; } }
        onExited: (code) => { if (code !== 0) { root.docLoading = false; root.docText = XI18n.t("cmd.docs.failed", undefined, "Не удалось открыть страницу"); } }
    }
    Process {
        id: graphProc
        stdout: StdioCollector { onStreamFinished: root.applyGraph(this.text) }
        onExited: (code) => { if (code !== 0) root.graphLoading = false; }
    }
    Process {
        id: schemaProc
        command: ["bash", root.script, "ui-schema", "--lang", root.lang]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(this.text);
                    root.baseCatalog = EL.indexCatalog(d.catalog || []);
                    const h = ({});
                    (d.nodes || []).forEach(n => h[n.id] = n);
                    root.helpById = h;
                } catch (e) { XLog.warn("cmd", "XCmd.qml: could not parse JSON output (d)"); }
                const f = root.schemaDone; root.schemaDone = null;
                if (f) f();
            }
        }
    }
    Process {
        id: fnLoadProc
        property string fid: ""
        stdout: StdioCollector { onStreamFinished: { try { const g = JSON.parse(this.text); if (g.function !== undefined) root.applyFunctionGraph(g); } catch (e) { XLog.warn("cmd", "XCmd.qml: could not parse JSON output (fn)"); } } }
    }
    Process {
        id: runProc
        onExited: Qt.callLater(root.refresh)
    }
    Process {
        id: cliProc
        stdout: StdioCollector { onStreamFinished: root.cliOut = this.text }
        stderr: StdioCollector { onStreamFinished: root.cliErr = this.text }
        onExited: (code) => { root.cliCode = code; cliDone.restart(); }
    }
    Timer { id: cliDone; interval: 30; onTriggered: root.cliFinish() }
    Timer { id: toastTimer; interval: 3100; onTriggered: { root.toast = ""; root.toastAction = null; } }
    Timer { interval: 8000; running: root.open && root.screen === "list" && !root.editing && root.dialog === null; repeat: true; onTriggered: root.refresh() }
}
