pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "."
import "hotkeys/CmdQuote.js" as CQ

// Backend + view-model of the Hotkeys tab.
//   * state: shipped binds (introspected from the Hyprland Lua config), the user's
//     hotkeys.custom[] / hotkeys.overrides[] (settings.json via the stock Config singleton)
//   * effective rows grouped for the UI, conflict detection, labels
//   * apply = scripts/custom/x_keybinds.sh (generate user_keybinds.lua + reload Hyprland)
// Nothing here edits hyprland.lua unless the user explicitly asks (fixRequire()).
Item {
    id: root

    // ------------------------------------------------------------------ environment
    readonly property string scriptPath: Caching.serpantinumDir + "/scripts/custom/x_keybinds.sh"
    readonly property bool isHyprland: String(SystemInfo.desktopEnv || "").toLowerCase().indexOf("hypr") !== -1

    function t(key, args, fallback) { return XI18n.t(key, args, fallback); }

    // ------------------------------------------------------------------ settings
    readonly property var hotkeyCfg: {
        let raw = Config.rawSettings ? Config.rawSettings["hotkeys"] : null;
        let h = (raw && typeof raw === "object") ? raw : {};
        return {
            custom: Array.isArray(h.custom) ? h.custom : [],
            overrides: Array.isArray(h.overrides) ? h.overrides : []
        };
    }
    readonly property var custom: hotkeyCfg.custom
    readonly property var overrides: hotkeyCfg.overrides

    function cfgCopy() { return JSON.parse(JSON.stringify(root.hotkeyCfg)); }

    // Every write goes through here. Refuses while the settings file has not been read yet:
    // writing then would replace the whole hotkeys section with a near-empty one.
    function commit(cfg) {
        if (!Config.dataReady) return false;
        let raw = Config.rawSettings ? Config.rawSettings["hotkeys"] : null;
        let merged = Object.assign({}, (raw && typeof raw === "object") ? raw : {}, cfg);
        Config.setSetting("hotkeys", merged);
        root.scheduleApply();
        return true;
    }

    function newId(prefix) { return prefix + Date.now().toString(36) + Math.floor(Math.random() * 1296).toString(36); }

    // ------------------------------------------------------------------ keys
    readonly property var modBits: ({ "SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64 })
    readonly property var modOrder: ["SUPER", "CTRL", "ALT", "SHIFT"]

    function maskOf(mods) {
        let m = 0;
        for (let i = 0; i < (mods || []).length; i++) m |= (modBits[mods[i]] || 0);
        return m;
    }
    function modsFromMask(mask) {
        return modOrder.filter(m => ((mask || 0) & modBits[m]) !== 0);
    }

    readonly property var keyAliases: ({
        "enter": "return", "esc": "escape", "pgup": "prior", "page_up": "prior",
        "pgdn": "next", "page_down": "next", "spacebar": "space", "bksp": "backspace", "del": "delete", "ins": "insert"
    })
    function normKey(k) {
        let s = String(k || "").trim().toLowerCase();
        return keyAliases[s] || s;
    }
    function identity(mods, key) { return maskOf(mods) + "|" + normKey(key); }
    function identityFromMask(mask, key) { return (mask || 0) + "|" + normKey(key); }

    readonly property var keyNames: ({
        "return": "Enter", "kp_enter": "Enter", "escape": "Esc", "backspace": "Backspace", "delete": "Del", "insert": "Ins",
        "prior": "PgUp", "next": "PgDn", "space": "Space", "tab": "Tab", "iso_left_tab": "Tab",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "print": "PrtSc", "grave": "`",
        "minus": "−", "equal": "=", "bracketleft": "[", "bracketright": "]", "backslash": "\\",
        "semicolon": ";", "apostrophe": "'", "comma": ",", "period": ".", "slash": "/",
        "xf86audioraisevolume": "Vol +", "xf86audiolowervolume": "Vol −", "xf86audiomute": "Mute",
        "xf86audiomicmute": "Mic", "xf86audioplay": "Play", "xf86audiopause": "Pause", "xf86audionext": "Next ▸",
        "xf86audioprev": "◂ Prev", "xf86monbrightnessup": "Bright +", "xf86monbrightnessdown": "Bright −",
        "xf86poweroff": "Power", "mouse:272": "LMB", "mouse:273": "RMB", "mouse:274": "MMB"
    })
    function prettyKey(k) {
        let s = String(k || "");
        let n = keyNames[s.toLowerCase()];
        if (n) return n;
        if (s.length === 1) return s.toUpperCase();
        return s;
    }
    function comboText(mods, key) {
        return (mods || []).concat(key ? [prettyKey(key)] : []).join(" + ");
    }

    // ------------------------------------------------------------------ catalogues
    // [id, command, locked]
    readonly property var shellActions: [
        { k: "launcher",   c: "serpantinum msg toggle launcher" },
        { k: "clipboard",  c: "serpantinum msg toggle clipboard" },
        { k: "network",    c: "serpantinum msg toggle network" },
        { k: "volume",     c: "serpantinum msg toggle volume" },
        { k: "calendar",   c: "serpantinum msg toggle calendar" },
        { k: "music",      c: "serpantinum msg toggle music" },
        { k: "system",     c: "serpantinum msg toggle system" },
        { k: "wallpaper",  c: "serpantinum msg toggle wallpaper" },
        { k: "guide",      c: "serpantinum msg toggle guide" },
        { k: "autohide",   c: "serpantinum msg toggle autohide" },
        { k: "lock",       c: "serpantinum lock", locked: true },
        { k: "screenshot", c: "serpantinum screenshot", locked: true },
        { k: "screenshot_edit", c: "serpantinum screenshot --edit", locked: true },
        { k: "screenshot_full", c: "serpantinum screenshot --full", locked: true },
        { k: "screenshot_full_edit", c: "serpantinum screenshot --full --edit", locked: true },
        { k: "vol_raise",  c: "serpantinum volume raise", locked: true, repeating: true },
        { k: "vol_lower",  c: "serpantinum volume lower", locked: true, repeating: true },
        { k: "vol_mute",   c: "serpantinum volume mute-toggle", locked: true },
        { k: "mic_mute",   c: "serpantinum volume mic-toggle", locked: true },
        { k: "brightness_raise", c: "serpantinum brightness raise", locked: true },
        { k: "brightness_lower", c: "serpantinum brightness lower", locked: true },
        { k: "reload",     c: "serpantinum reload" },
        { k: "xpick",      c: "serpantinum ipc call xtools pick" },
        { k: "xcolors",    c: "serpantinum ipc call xtools colors" },
        { k: "xnotes",     c: "serpantinum ipc call xtools notes" },
        { k: "xnote_new",  c: "serpantinum ipc call xtools newNote" },
        { k: "xservers_refresh",  c: "serpantinum ipc call xservers refresh" },
        { k: "xservers_terminal", c: "serpantinum ipc call xservers terminal" },
        { k: "xvpn_toggle", c: "serpantinum ipc call xvpn toggle" },
        { k: "xvpn_popup",  c: "serpantinum ipc call xvpn popup" },
        { k: "xvpn_next",   c: "serpantinum ipc call xvpn next" },
        { k: "xcmd_toggle", c: "serpantinum ipc call xcmd toggle" },
        { k: "xcmd_palette", c: "serpantinum ipc call xcmd palette" }
    ]

    // Window / workspace actions, stored as a vetted dispatcher kind + args.
    readonly property var windowActions: [
        { k: "close",      kind: "window.close", args: [] },
        { k: "float",      kind: "window.float",  args: [{ action: "toggle" }] },
        { k: "focus_left",  kind: "focus", args: [{ direction: "left" }] },
        { k: "focus_right", kind: "focus", args: [{ direction: "right" }] },
        { k: "focus_up",    kind: "focus", args: [{ direction: "up" }] },
        { k: "focus_down",  kind: "focus", args: [{ direction: "down" }] },
        { k: "move_left",  kind: "window.move", args: [{ direction: "l" }] },
        { k: "move_right", kind: "window.move", args: [{ direction: "r" }] },
        { k: "move_up",    kind: "window.move", args: [{ direction: "u" }] },
        { k: "move_down",  kind: "window.move", args: [{ direction: "d" }] }
    ]

    // «Запустить команду…»: the exec line of a hotkey that runs a Commands command by name (shell-quoted, see CmdQuote.js)
    function runCommandLine(name) { return CQ.runLine(name); }

    function shellActionByCommand(cmd) {
        for (let i = 0; i < shellActions.length; i++) if (shellActions[i].c === cmd) return shellActions[i];
        return null;
    }
    function windowActionFor(kind, args) {
        let a = JSON.stringify(args || []);
        for (let i = 0; i < windowActions.length; i++)
            if (windowActions[i].kind === kind && JSON.stringify(windowActions[i].args) === a) return windowActions[i];
        return null;
    }

    readonly property var groupDefs: [
        { id: "mine",    icon: "󰓎" },
        { id: "windows", icon: "󰖲" },
        { id: "media",   icon: "󰎆" },
        { id: "system",  icon: "󰌾" },
        { id: "apps",    icon: "󰀻" },
        { id: "shell",   icon: "󱓞" }
    ]

    // ------------------------------------------------------------------ desktop apps
    property var apps: []

    function execForEntry(e) {
        if (!e) return "";
        let cmd = "";
        if (e.command && e.command.length > 0) cmd = e.command.join(" ");
        else cmd = (e.execString || "").replace(/%[fFuUdDnNickvm]/g, "").replace(/\s+/g, " ").trim();
        if (e.runInTerminal) {
            let tc = (Config.getSetting("launcher", {}) || {}).terminalCommand || "kitty -e";
            cmd = tc + " " + cmd;
        }
        return cmd;
    }

    function loadApps() {
        let list = [];
        if (typeof DesktopEntries !== "undefined" && DesktopEntries.applications && DesktopEntries.applications.values) {
            let entries = DesktopEntries.applications.values;
            for (let i = 0; i < entries.length; i++) {
                let e = entries[i];
                if (e.noDisplay) continue;
                let exec = execForEntry(e);
                list.push({
                    id: e.id || "", name: e.name || "", comment: e.genericName || e.comment || "",
                    icon: e.icon || "", exec: exec,
                    execBase: String(exec.split(" ")[0] || "").split("/").pop()
                });
            }
        }
        list.sort((a, b) => (a.name || "").localeCompare(b.name || ""));
        root.apps = list;
    }

    // Compare commands with the path of the program stripped, so "/usr/bin/brave" == "brave".
    // Deliberately exact otherwise: "kitty -e btop" must NOT be mistaken for the app "kitty".
    function normCmd(c) {
        let parts = String(c || "").trim().split(/\s+/);
        if (parts.length === 0 || parts[0] === "") return "";
        parts[0] = parts[0].split("/").pop();
        return parts.join(" ");
    }
    function appByCommand(cmd) {
        let n = normCmd(cmd);
        if (n === "") return null;
        for (let i = 0; i < apps.length; i++) if (normCmd(apps[i].exec) === n) return apps[i];
        return null;
    }
    function appById(id) {
        for (let i = 0; i < apps.length; i++) if (apps[i].id === id) return apps[i];
        return null;
    }

    // ------------------------------------------------------------------ labels
    function dirWord(d) {
        let m = { l: "left", r: "right", u: "up", d: "down", left: "left", right: "right", up: "up", down: "down" };
        return t("hotkeys.dir." + (m[d] || d), undefined, String(d));
    }

    function labelFor(kind, args) {
        if (kind === "exec_cmd") {
            let cmd = (args && args.length > 0) ? String(args[0]) : "";
            let sa = shellActionByCommand(cmd);
            if (sa) return t("hotkeys.builtin." + sa.k, undefined, cmd);
            let wm = cmd.match(/^serpantinum msg workspace (\d+)( move)?$/);
            if (wm) return t(wm[2] ? "hotkeys.builtin.workspace_move" : "hotkeys.builtin.workspace", { n: wm[1] }, cmd);
            let pc = cmd.match(/^playerctl (play-pause|next|previous)$/);
            if (pc) return t("hotkeys.media." + pc[1].replace(/-/g, "_"), undefined, cmd);
            let app = appByCommand(cmd);
            if (app) return app.name;
            return cmd;
        }
        let a0 = (args && args.length > 0 && args[0] && typeof args[0] === "object") ? args[0] : null;
        if (kind === "focus" && a0 && a0.direction) return t("hotkeys.dsp.focus", undefined, "Focus") + ": " + dirWord(a0.direction);
        if (kind === "window.move" && a0 && a0.direction) return t("hotkeys.dsp.window_move", undefined, "Move window") + ": " + dirWord(a0.direction);
        if (kind === "window.resize") {
            if (!a0) return t("hotkeys.dsp.window_resize_mouse", undefined, "Resize window (mouse)");
            let arrow = a0.x < 0 ? "←" : a0.x > 0 ? "→" : a0.y < 0 ? "↑" : "↓";
            return t("hotkeys.dsp.window_resize", undefined, "Resize window") + ": " + arrow;
        }
        if (kind === "window.drag") return t("hotkeys.dsp.window_drag", undefined, "Drag window (mouse)");
        let k = "hotkeys.dsp." + String(kind || "").replace(/\./g, "_");
        let lbl = t(k, undefined, "");
        return lbl !== "" ? lbl : (kind || "?");
    }

    // Second line of a row: what kind of thing this is + the command / category.
    function detailFor(kind, args, typeHint) {
        if (kind === "exec_cmd") {
            let cmd = (args && args.length > 0) ? String(args[0]) : "";
            if (shellActionByCommand(cmd) || /^serpantinum /.test(cmd))
                return t("hotkeys.type.shell", undefined, "Shell action");
            if (appByCommand(cmd) || typeHint === "app")
                return t("hotkeys.type.app", undefined, "Launch app") + " · " + cmd;
            return t("hotkeys.type.command", undefined, "Command") + " · " + cmd;
        }
        return t("hotkeys.type.window", undefined, "Window / workspace");
    }

    function groupOf(kind, args) {
        if (kind === "exec_cmd") {
            let c = (args && args.length > 0) ? String(args[0]) : "";
            if (/^serpantinum msg workspace /.test(c)) return "windows";
            if (/^serpantinum msg toggle /.test(c) || c === "serpantinum reload") return "shell";
            if (/^serpantinum (volume|brightness)/.test(c) || /^playerctl /.test(c)) return "media";
            if (/^serpantinum (lock|screenshot|exit|poweroff|reboot)/.test(c)) return "system";
            return "apps";
        }
        return "windows";
    }

    function iconFor(kind, args, desktopHint) {
        if (kind === "exec_cmd") {
            let c = (args && args.length > 0) ? String(args[0]) : "";
            let app = desktopHint ? appById(desktopHint) : appByCommand(c);
            if (app && app.icon) return { image: app.icon, glyph: "󰀻" };
            if (/^serpantinum/.test(c)) return { image: "", glyph: "󱓞" };
            return { image: "", glyph: "󰆍" };
        }
        if (kind === "window.close") return { image: "", glyph: "󰅖" };
        if (kind === "window.float") return { image: "", glyph: "󰖲" };
        if (kind === "focus") return { image: "", glyph: "󰆾" };
        return { image: "", glyph: "󰖯" };
    }

    // ------------------------------------------------------------------ binds / rows
    property var allBinds: []
    property bool bindsLoaded: false
    property var groups: []
    property var rows: []
    property string groupsSig: ""

    function isGenerated(b) { return String(b.src || "").endsWith("user_keybinds.lua"); }

    function overrideFor(bind) {
        let id = identityFromMask(bind.modmask, bind.key);
        for (let i = 0; i < overrides.length; i++) {
            let o = overrides[i];
            if (o && identity(o.originalMods, o.originalKey) === id) return o;
        }
        return null;
    }

    function rebuild() {
        let out = [];
        let shipped = allBinds.filter(b => !isGenerated(b));
        for (let i = 0; i < shipped.length; i++) {
            let b = shipped[i];
            let ov = overrideFor(b);
            let origMods = modsFromMask(b.modmask);
            let moved = ov && ov.newKey;       // a disabled override keeps showing the combo it would restore
            let kind = ov && ov.kind ? ov.kind : b.kind;
            let args = ov && ov.args ? ov.args : (b.args || []);
            let label = (ov && ov.name) ? ov.name : labelFor(b.kind, b.args);
            out.push({
                ref: "sh|" + identityFromMask(b.modmask, b.key),
                source: "shipped",
                group: ov ? "mine" : groupOf(b.kind, b.args),
                bind: b,
                override: ov,
                changed: !!ov,
                badge: ov ? "changed" : "",
                disabled: !!(ov && ov.disabled),
                mods: moved ? (ov.newMods || []) : origMods,
                key: moved ? (ov.newKey || "") : b.key,
                origMods: origMods,
                origKey: b.key,
                kind: kind,
                args: args,
                label: label,
                detail: detailFor(kind, args, ""),
                icon: iconFor(kind, args, ""),
                locked: !!(b.opts && b.opts.locked)
            });
        }
        let mine = [];
        for (let j = 0; j < custom.length; j++) {
            let c = custom[j];
            if (!c || !c.id) continue;
            let kind = c.kind ? c.kind : "exec_cmd";
            let args = c.kind ? (c.args || []) : [c.command || ""];
            mine.push({
                ref: "cu|" + c.id,
                source: "custom",
                group: "mine",
                custom: c,
                badge: "own",
                disabled: c.enabled === false,
                mods: c.mods || [],
                key: c.key || "",
                kind: kind,
                args: args,
                label: c.name || labelFor(kind, args),
                detail: detailFor(kind, args, c.type),
                icon: iconFor(kind, args, c.desktopId),
                locked: !!c.locked
            });
        }
        out = mine.concat(out);

        let gs = [];
        for (let g = 0; g < groupDefs.length; g++) {
            let d = groupDefs[g];
            let rs = out.filter(r => r.group === d.id);
            if (rs.length === 0) continue;
            gs.push({ id: d.id, icon: d.icon, rows: rs });
        }
        let sig = JSON.stringify(gs.map(g => ({ id: g.id, rows: g.rows.map(r => [r.ref, r.mods, r.key, r.label, r.detail, r.badge, r.disabled, r.kind, r.args, r.custom ? r.custom.desktopId : "", r.bind ? r.bind.live : null]) })));
        root.rows = out;
        if (sig !== groupsSig) {
            groupsSig = sig;
            groups = gs;
        }
    }

    function rowByRef(ref) {
        for (let i = 0; i < rows.length; i++) if (rows[i].ref === ref) return rows[i];
        return null;
    }

    readonly property int totalCount: rows.length
    readonly property int changedCount: rows.filter(r => r.source === "shipped" && r.changed).length
    readonly property int ownCount: rows.filter(r => r.source === "custom").length

    onCustomChanged: rebuild()
    onOverridesChanged: rebuild()
    onAllBindsChanged: rebuild()
    onAppsChanged: rebuild()
    Connections {
        target: XI18n
        function onTranslationsChanged() { root.rebuild(); }
        function onIsReadyChanged() { root.rebuild(); }
    }

    // Conflict: the first enabled row that effectively owns this combo (other than selfRef).
    function conflictFor(selfRef, mods, key) {
        if (!key) return null;
        let id = identity(mods, key);
        for (let i = 0; i < rows.length; i++) {
            let r = rows[i];
            if (r.ref === selfRef || r.disabled) continue;
            if (identity(r.mods, r.key) === id) return r;
        }
        return null;
    }

    // ------------------------------------------------------------------ edits
    function saveCustom(entry) { XLog.info("hotkeys", "UI: save custom hotkey name=" + (entry && entry.name) + " type=" + (entry && entry.type));
        let cfg = cfgCopy();
        let idx = cfg.custom.findIndex(c => c && c.id === entry.id);
        if (idx !== -1) cfg.custom[idx] = entry; else cfg.custom.push(entry);
        return commit(cfg);
    }
    function deleteCustom(id) {
        let cfg = cfgCopy();
        cfg.custom = cfg.custom.filter(c => c && c.id !== id);
        return commit(cfg);
    }
    function setCustomEnabled(id, enabled) {
        let cfg = cfgCopy();
        let c = cfg.custom.find(x => x && x.id === id);
        if (!c) return false;
        c.enabled = !!enabled;
        return commit(cfg);
    }

    // spec: { mods, key, kind, args, name }  (kind/args = the dispatcher to bind; defaults to the original)
    function saveOverride(bind, spec, disabled) { XLog.info("hotkeys", "UI: save override disabled=" + !!disabled);
        let cfg = cfgCopy();
        let targetId = identityFromMask(bind.modmask, bind.key);
        let idx = cfg.overrides.findIndex(o => o && identity(o.originalMods, o.originalKey) === targetId);
        let prev = idx !== -1 ? cfg.overrides[idx] : null;
        let kind = (spec && spec.kind) ? spec.kind : (prev && prev.kind ? prev.kind : bind.kind);
        let args = (spec && spec.args) ? spec.args : (prev && prev.args ? prev.args : (bind.args || []));
        let mods = (spec && spec.mods) ? spec.mods : (prev ? (prev.newMods || []) : modsFromMask(bind.modmask));
        let key = (spec && spec.key !== undefined) ? spec.key : (prev ? (prev.newKey || "") : bind.key);
        if (!key && !disabled) { key = bind.key; mods = modsFromMask(bind.modmask); }
        let name = (spec && spec.name !== undefined) ? spec.name : (prev ? prev.name : "");

        let sameKeys = identity(mods, key) === targetId;
        let sameAction = kind === bind.kind && JSON.stringify(args) === JSON.stringify(bind.args || []);
        let defaultName = labelFor(bind.kind, bind.args);
        if (!disabled && sameKeys && sameAction && (!name || name === defaultName)) {
            if (idx !== -1) cfg.overrides.splice(idx, 1);
        } else {
            let entry = {
                id: prev ? prev.id : ("ov_" + Date.now().toString(36)),
                name: name || defaultName,
                originalKeys: bind.keys,
                originalMods: modsFromMask(bind.modmask),
                originalKey: bind.key,
                kind: kind,
                args: args,
                disabled: !!disabled,
                newMods: mods,
                newKey: key
            };
            if (idx !== -1) cfg.overrides[idx] = entry; else cfg.overrides.push(entry);
        }
        return commit(cfg);
    }

    function setShippedEnabled(bind, enabled) {
        let ov = overrideFor(bind);
        if (!ov) return enabled ? true : saveOverride(bind, null, true);
        let spec = { mods: ov.newMods || [], key: ov.newKey || "", kind: ov.kind, args: ov.args, name: ov.name };
        return saveOverride(bind, spec, !enabled);
    }

    // Used by "Replace" in the conflict card: the row that loses its combination.
    function disableRow(ref) {
        let r = rowByRef(ref);
        if (!r) return false;
        return r.source === "custom" ? setCustomEnabled(r.custom.id, false) : setShippedEnabled(r.bind, false);
    }

    function resetOverride(bind) { XLog.info("hotkeys", "UI: reset override");
        let cfg = cfgCopy();
        let targetId = identityFromMask(bind.modmask, bind.key);
        cfg.overrides = cfg.overrides.filter(o => !o || identity(o.originalMods, o.originalKey) !== targetId);
        return commit(cfg);
    }

    // ------------------------------------------------------------------ apply
    property string applyState: "idle"     // idle | pending | running | ok | error
    property string applyError: ""
    property bool requirePresent: true
    property bool importDone: false

    function scheduleApply() {
        if (!isHyprland) return;
        applyState = "pending";
        applyTimer.interval = 500;
        applyTimer.restart();
    }

    // Waits for pending settings writes and for the one-time import, but never forever.
    property int applyWaitTicks: 0
    Timer {
        id: applyTimer
        repeat: false
        onTriggered: {
            let busy = Config.isWriting || Config.pendingPayload !== null || !root.importDone;
            if (busy && root.applyWaitTicks < 24) {
                root.applyWaitTicks++;
                interval = 250;
                restart();
                return;
            }
            root.applyWaitTicks = 0;
            root.applyNow(false);
        }
    }

    function applyNow(ensureRequire) { XLog.info("hotkeys", "UI: apply requested ensureRequire=" + !!ensureRequire);
        if (!isHyprland) return;
        applyState = "running";
        applyProc.command = ["bash", scriptPath, "apply"].concat(ensureRequire ? ["--ensure-require"] : []);
        applyProc.running = false;
        applyProc.running = true;
    }

    function fixRequire() { XLog.info("hotkeys", "UI: fix require line requested"); applyNow(true); }

    Process {
        id: applyProc
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                let res = null;
                try { res = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("hotkeys", "XHotkeys.qml: could not parse JSON output (res)");}
                if (!res) {
                    root.applyState = "error";
                    root.applyError = String(this.text || "").trim() || "no response";
                } else {
                    root.requirePresent = res.requirePresent !== false;
                    root.applyState = res.ok ? "ok" : "error";
                    root.applyError = res.ok ? "" : String(res.error || res.stage || "");
                }
                XLog[root.applyState === "ok" ? "info" : "warn"]("hotkeys", "UI: apply result state=" + root.applyState + (root.applyError ? " error=" + String(root.applyError).slice(0, 200) : ""));
                okResetTimer.restart();
                refreshTimer.restart();
            }
        }
    }

    Timer { id: refreshTimer; interval: 400; repeat: false; onTriggered: root.refreshBinds() }
    Timer { id: okResetTimer; interval: 4000; repeat: false; onTriggered: if (root.applyState === "ok") root.applyState = "idle" }

    // ------------------------------------------------------------------ list / status / orphans
    function refreshBinds() {
        if (!isHyprland) return;
        bindsProc.running = false;
        bindsProc.running = true;
    }

    Process {
        id: bindsProc
        running: false
        command: ["bash", root.scriptPath, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = [];
                try { list = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("hotkeys", "XHotkeys.qml: could not parse JSON output (list)");}
                root.allBinds = Array.isArray(list) ? list : [];
                root.bindsLoaded = true;
                root.maybeImportOrphans();
            }
        }
    }

    Process {
        id: statusProc
        running: false
        command: ["bash", root.scriptPath, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let st = JSON.parse(this.text.trim());
                    root.requirePresent = !!st.requirePresent;
                } catch (e) { XLog.warn("hotkeys", "XHotkeys.qml: could not parse JSON output (st)");}
            }
        }
    }

    property bool importStarted: false
    property var importedNames: []

    function maybeImportOrphans() {
        if (importStarted || !isHyprland || !Config.dataReady || !bindsLoaded) return;
        importStarted = true;
        orphansProc.running = true;
    }

    Connections {
        target: Config
        function onDataReadyChanged() { root.maybeImportOrphans(); }
    }

    // Binds that live in user_keybinds.lua but that settings.json lost (an old bug): keep them,
    // instead of letting the next apply silently delete them.
    Process {
        id: orphansProc
        running: false
        command: ["bash", root.scriptPath, "orphans"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = [];
                try { list = JSON.parse(this.text.trim()); } catch (e) { XLog.warn("hotkeys", "XHotkeys.qml: could not parse JSON output (list)");}
                root.importOrphans(Array.isArray(list) ? list : []);
            }
        }
    }

    // Old bug: some overrides point at an "original" combo that does not exist in the shipped
    // config (they were recorded from an already-generated bind). They are really user
    // hotkeys; turn them into custom[] entries so they show up and stay editable.
    // Never runs when the shipped list looks broken (nothing would be recognised).
    function migrateGhostOverrides(cfg, added) {
        let shipped = allBinds.filter(b => !isGenerated(b));
        if (shipped.length < 10) return;
        let known = {};
        shipped.forEach(b => { known[identityFromMask(b.modmask, b.key)] = true; });
        cfg.overrides = cfg.overrides.filter(ov => {
            if (!ov) return false;
            if (known[identity(ov.originalMods, ov.originalKey)]) return true;
            let isExec = ov.kind === "exec_cmd" && ov.args && ov.args.length > 0 && typeof ov.args[0] === "string";
            if (!isExec || ov.disabled || !ov.newKey) return true;
            let id = identity(ov.newMods, ov.newKey);
            if (cfg.custom.some(c => c && identity(c.mods, c.key) === id)) return true;
            let cmd = ov.args[0];
            let app = appByCommand(cmd);
            let entry = {
                id: "hk_" + ov.id, name: ov.name || labelFor("exec_cmd", ov.args),
                mods: ov.newMods || [], key: ov.newKey, type: app ? "app" : "command",
                command: cmd, desktopId: app ? app.id : "", enabled: true, locked: false, repeating: false, imported: true
            };
            cfg.custom.push(entry);
            added.push(entry);
            return false;
        });
    }

    function importOrphans(list) { XLog.info("hotkeys", "UI: import orphans count=" + (list ? list.length : 0));
        let cfg = cfgCopy();
        let added = [];
        for (let i = 0; i < list.length; i++) {
            let o = list[i];
            let id = identity(o.mods, o.key);
            let exists = cfg.custom.some(c => c && (c.id === o.id || identity(c.mods, c.key) === id))
                || cfg.overrides.some(ov => ov && !ov.disabled && identity(ov.newMods, ov.newKey) === id);
            if (exists) continue;
            cfg.custom.push(o);
            added.push(o);
        }
        migrateGhostOverrides(cfg, added);
        root.importDone = true;
        if (added.length > 0) {
            root.importedNames = added.map(a => a.name + " (" + comboText(a.mods, a.key) + ")");
            commit(cfg);
        }
    }

    // ------------------------------------------------------------------ lifecycle
    property bool initialised: false
    function init() {
        if (!isHyprland) return;
        if (!initialised) {
            initialised = true;
            loadApps();
        }
        refreshBinds();
        statusProc.running = false;
        statusProc.running = true;
    }

    Connections {
        target: (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) ? DesktopEntries.applications : null
        function onValuesChanged() { if (root.initialised) root.loadApps(); }
    }
}
