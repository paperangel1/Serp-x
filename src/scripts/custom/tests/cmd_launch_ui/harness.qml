import QtQuick
import Quickshell
import "custom"
import "custom/cmd"

// Offscreen harness of the launch surfaces (palette, bar button + menu, desktop widget); copied into the quickshell tree by
// cmd_launch_ui_test.sh. XCmdLaunch.fake = true: no process is started, data is injected, CLI calls are recorded.
// Results are printed as "LCH key: value".
ShellRoot {
    id: shell
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    property int step: 0
    property int closeCount: 0
    property var notices: []

    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        let ch = item.children || [];
        for (let i = 0; i < ch.length; i++) { let r = find(ch[i], name); if (r) return r; }
        return null;
    }
    function findAll(item, name, out) {
        if (!item) return out;
        if (item.objectName === name) out.push(item);
        let ch = item.children || [];
        for (let i = 0; i < ch.length; i++) findAll(ch[i], name, out);
        return out;
    }
    // the ListView keeps its delegates in contentItem
    function rows(view, name) { return findAll(view.contentItem ? view.contentItem : view, name, []); }
    function say(k, v) { console.log("LCH " + k + ": " + v); }
    function shot(name) { grid.grabToImage(function(r) { r.saveToFile(shell.outDir + "/launch_" + name + ".png"); }); }
    function callsText() { return JSON.stringify(XCmdLaunch.calls.map(c => c.args)); }

    readonly property var data: [
        { id: "focus", name: "Фокус 25 минут", description: "Не беспокоить и таймер", kind: "manual", enabled: true, approved: true, errors: 0, icon: "timer", pinned: true,
          triggers: [], keywords: ["Таймер", "Уведомление"], last_run: { ts: Date.now() / 1000 - 300, status: "ok" } },
        { id: "cache", name: "Очистить кэш", description: "", kind: "manual", enabled: true, approved: true, errors: 0, icon: "terminal", pinned: false,
          triggers: [], keywords: ["Выполнить команду"], last_run: { ts: Date.now() / 1000 - 7200, status: "error" } },
        { id: "shot", name: "Сфотографировать экран", description: "Скриншот в буфер", kind: "manual", enabled: true, approved: false, errors: 0, icon: "clipboard", pinned: false, triggers: [], keywords: ["Буфер обмена"] },
        { id: "broken", name: "Сломанная", description: "Граф с ошибкой", kind: "manual", enabled: true, approved: true, errors: 2, icon: "unknown", pinned: false, triggers: [], keywords: [] },
        { id: "night", name: "Ночной режим", description: "Включать вечером", kind: "auto", enabled: true, approved: true, errors: 0, icon: "moon", pinned: false, triggers: ["Время"], keywords: ["Тема"] },
        { id: "quote", name: "Имя \"с\" кавычками", description: "", kind: "manual", enabled: true, approved: true, errors: 0, icon: "play", pinned: true, triggers: [], keywords: [] }
    ]

    Connections {
        target: XCmdLaunch
        function onNotice(kind, title, sub) { shell.notices = shell.notices.concat([kind + "|" + title + "|" + sub]); }
    }

    FloatingWindow {
        id: win
        visible: true
        width: 1180; height: 940
        color: "#0f0e14"
        Rectangle {
            id: grid; anchors.fill: parent; color: "#0f0e14"
            CmdPaletteView { id: pal; x: 20; y: 20; width: 640; active: false; onCloseRequested: shell.closeCount++ }
            Rectangle {   // a mock bar with the face
                id: bar; x: 690; y: 20; width: 470; height: 44; color: "#181825"; radius: 12
                Row { anchors.centerIn: parent; spacing: 12
                    Item { id: faceHost; width: 44; height: 44; CmdFace { id: face; anchors.fill: parent } }
                    Item { id: sideHost; width: 44; height: 44; SideCmdFace { id: sideFace; anchors.fill: parent } }
                }
            }
            CmdMenuView { id: menu; x: 690; y: 80; width: 280 }
            CmdWidgetView { id: wgC; x: 690; y: 330; width: 320; height: 190; mode: "compact" }
            CmdWidgetView { id: wgD; x: 690; y: 540; width: 360; height: 260; mode: "detailed" }
            CmdWidgetView { id: wgE; x: 20; y: 560; width: 320; height: 150; mode: "compact"; visible: false }
        }
    }

    Timer {
        interval: 350; running: true; repeat: true
        onTriggered: { shell.step++; shell.go(shell.step); }
    }

    function go(n) {
        const L = XCmdLaunch;
        if (n === 1) {
            L.fake = true; L.loaded = true; L.commands = []; L.pinnedIds = [];
            L.pulse = ({ paused_all: false, failed_recent: 0, last: null, pinned: 0 });
        } else if (n === 2) {
            say("empty_text", find(pal, "palEmpty").text);
            say("empty_rows", rows(find(pal, "palList"), "palRow").length);
            say("menu_nopins", find(menu, "menuNoPins").visible);
            say("wg_empty_visible", find(wgC, "wgEmpty").visible);
            say("watchers_after_faces", L.watchers);
            L.error = "Не удалось прочитать список команд";
        } else if (n === 3) {
            say("error_text", find(pal, "palEmpty").text);
            L.error = "";
            L.commands = shell.data; L.pinnedIds = ["focus", "quote"];
            L.pulse = ({ paused_all: false, failed_recent: 0, last: null, pinned: 2 });
        } else if (n === 4) {
            const r = rows(find(pal, "palList"), "palRow");
            say("rows_default", r.length);                                  // 5 manual, the automation is hidden
            say("first_pinned", pal.results[0].id + "," + pal.results[1].id);
            say("auto_hidden", pal.results.some(c => c.kind === "auto"));
            say("blocked_rows", rows(find(pal, "palList"), "palBlock").length);
            say("block_text_unapproved", rows(find(pal, "palList"), "palBlock").map(b => b.text).join("|"));
            shot("palette_default");
        } else if (n === 5) {
            find(pal, "palSearch").text = "фок";
        } else if (n === 6) {
            say("filter_fok", pal.results.map(c => c.id).join(","));
            find(pal, "palSearch").text = "уведомл";
        } else if (n === 7) {
            say("filter_keyword", pal.results.map(c => c.id).join(","));    // node keyword «Уведомление»
            find(pal, "palSearch").text = "фкс";
        } else if (n === 8) {
            say("filter_fuzzy", pal.results.map(c => c.id).join(","));
            find(pal, "palSearch").text = "ночн";
        } else if (n === 9) {
            say("filter_auto_hidden", pal.results.length + "|" + find(pal, "palEmpty").text);
            pal.toggleAuto();
        } else if (n === 10) {
            say("filter_auto_shown", pal.results.map(c => c.id).join(","));
            say("auto_badge", rows(find(pal, "palList"), "palKind").length);
            say("auto_toggle_text", find(pal, "palAutoToggle").children[0].text);
            find(pal, "palSearch").text = "zzzz";
        } else if (n === 11) {
            say("nothing_text", find(pal, "palEmpty").text);
            find(pal, "palSearch").text = "";
            pal.toggleAuto();
        } else if (n === 12) {
            // run the first (pinned) row
            pal.index = 0;
            pal.runCurrent();
            say("run_calls", callsText());
            say("run_state", L.stateOf("focus"));
            say("closed_after_run", shell.closeCount);
            say("notice_running", shell.notices[shell.notices.length - 1]);
        } else if (n === 13) {
            say("row_status_running", rows(find(pal, "palList"), "palStatus").map(x => x.text)[0]);
            shot("palette_running");
            L.finishRun("focus", "Фокус 25 минут", false, "нет доступа к dbus");
        } else if (n === 14) {
            say("error_state", L.stateOf("focus"));
            say("notice_error", shell.notices[shell.notices.length - 1]);
            say("row_status_error", rows(find(pal, "palList"), "palStatus").map(x => x.text)[0]);
            shot("palette_error");
        } else if (n === 15) {
            // blocked: unapproved command is not run, the reason goes to the toast
            const before = L.calls.length;
            find(pal, "palSearch").text = "сфот";
            pal.index = 0;
            pal.runCurrent();
            say("blocked_not_run", L.calls.length === before);
            say("blocked_notice", shell.notices[shell.notices.length - 1]);
            say("blocked_open_btn", rows(find(pal, "palList"), "palOpen").length);
            say("blocked_row_text", rows(find(pal, "palList"), "palBlock").map(b => b.text).join("|"));
            shot("palette_blocked");
        } else if (n === 16) {
            find(pal, "palSearch").text = "сломан";
        } else if (n === 17) {
            pal.index = 0; pal.runCurrent();
            say("errors_notice", shell.notices[shell.notices.length - 1]);
            find(pal, "palSearch").text = "";
        } else if (n === 18) {
            // pin / unpin through the star, selection wraps
            L.calls = [];
            L.togglePinned("cache");
            say("pin_calls", callsText());
            say("pinned_ids", L.pinnedIds.join(","));
            say("pinned_flag", L.byId("cache").pinned);
            L.togglePinned("focus");
            say("unpin_calls", callsText());
            pal.index = 0; pal.move(-1);
            say("wrap_index", pal.index === pal.results.length - 1);
        } else if (n === 19) {
            // bar button: dot states
            say("watchers", L.watchers);
            say("dot_none", find(face, "cmdDot").visible);
            L.pulse = ({ paused_all: true, failed_recent: 0, last: null, pinned: 2 });
        } else if (n === 20) {
            say("dot_paused", find(face, "cmdDot").visible + "," + find(face, "cmdDot").color);
            say("side_dot_paused", find(sideFace, "cmdDot").visible);
            shot("face_paused");
            L.pulse = ({ paused_all: false, failed_recent: 2, last: { name: "x", status: "error", ts: 1 }, pinned: 2 });
        } else if (n === 21) {
            say("dot_failed", find(face, "cmdDot").visible + "," + find(face, "cmdDot").color);
            shot("face_failed");
            L.pulse = ({ paused_all: false, failed_recent: 0, last: null, pinned: 2 });
        } else if (n === 22) {
            say("dot_cleared", find(face, "cmdDot").visible);
            // menu
            say("menu_items", findAll(menu, "menuPinned", []).length);
            say("menu_pause_btn", find(menu, "menuPause") !== null);
            L.calls = [];
            find(menu, "menuPause").triggered();
            say("menu_pause_calls", callsText());
            find(menu, "menuApp").triggered();
            say("menu_open_app", L.lastOpened === "" ? "app" : L.lastOpened);
            find(menu, "menuPalette").triggered();
            say("menu_palette_open", L.paletteOpen);
            L.closePalette();
            shot("menu");
        } else if (n === 23) {
            // widget compact / detailed
            say("wg_buttons", findAll(wgC, "wgButton", []).length);
            say("wg_rows", findAll(wgD, "wgRow", []).length);
            say("wg_empty_hidden", find(wgC, "wgEmpty").visible);
            L.calls = [];
            findAll(wgC, "wgButton", [])[0].children[findAll(wgC, "wgButton", [])[0].children.length - 1].clicked(null);
            say("wg_click_calls", callsText());
            say("wg_state_running", L.stateOf(L.pinnedCommands[0].id));
        } else if (n === 24) {
            shot("widget_running");
            L.finishRun(L.pinnedCommands[0].id, L.pinnedCommands[0].name, true, "");
        } else if (n === 25) {
            say("wg_state_ok", L.stateOf(L.pinnedCommands[0].id));
            say("wg_info", findAll(wgD, "wgInfo", []).map(t => t.text).join("|"));
            shot("widget_ok");
            L.finishRun(L.pinnedCommands[0].id, L.pinnedCommands[0].name, false, "boom");
        } else if (n === 26) {
            say("wg_state_error", L.stateOf(L.pinnedCommands[0].id));
            say("wg_info_error", findAll(wgD, "wgInfo", []).map(t => t.text)[0]);
            shot("widget_error");
        } else if (n === 27) {
            // the face releases its watch when it is destroyed
            faceHost.children[0].destroy();
            sideHost.children[0].destroy();
        } else if (n === 28) {
            say("watchers_released", L.watchers);
            say("subscribers", L.subscribers);
            Qt.quit();
        }
    }
}
