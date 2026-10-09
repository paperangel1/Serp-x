.pragma library

// Pure logic of the launch surfaces (palette, bar menu, widget): search/ranking and «why can this not run».
// No QML types here, so it is testable with plain `qml6` (tests/cmd_ui/launch_logic_test.qml).

// 0 = no match; higher is better. Substring beats a gap-tolerant subsequence; start of a word / of the text beats the middle.
function fieldScore(text, tok, fuzzy) {
    var t = (text || "").toLowerCase();
    if (tok === "" || t === "") return 0;
    var i = t.indexOf(tok);
    if (i === 0) return 100;
    if (i > 0) return /[\s\-_.,:;()«»"']/.test(t.charAt(i - 1)) ? 80 : 60;
    if (!fuzzy || tok.length < 3) return 0;
    var pos = 0, gaps = 0, last = -1, first = -1;
    for (var k = 0; k < tok.length; k++) {
        var f = t.indexOf(tok.charAt(k), pos);
        if (f < 0) return 0;
        if (first < 0) first = f;
        if (last >= 0 && f !== last + 1) gaps++;
        last = f; pos = f + 1;
    }
    if (last - first + 1 > tok.length * 2) return 0;      // letters scattered over a long text are not a match
    return Math.max(8, 40 - gaps * 6);
}

// Score of one command for a (lower-cased, trimmed) query. Every whitespace-separated token must match somewhere.
function score(c, q) {
    var toks = q.split(/\s+/).filter(function (x) { return x !== ""; });
    if (toks.length === 0) return 1;
    var total = 0;
    for (var i = 0; i < toks.length; i++) {
        var best = fieldScore(c.name, toks[i], true) * 3;
        best = Math.max(best, fieldScore(c.description, toks[i], false) * 1.2);
        var kw = c.keywords || [], trg = c.triggers || [];
        for (var j = 0; j < kw.length; j++) best = Math.max(best, fieldScore(kw[j], toks[i], true) * 0.9);
        for (var j2 = 0; j2 < trg.length; j2++) best = Math.max(best, fieldScore(trg[j2], toks[i], true) * 0.9);
        if (best <= 0) return 0;
        total += best;
    }
    return total;
}

// null when the command can be run, else a reason key (translated by the view): errors | unapproved | example
function blockReason(c) {
    if (c.example) return "example";
    if ((c.errors || 0) > 0) return "errors";
    if (c.approved === false) return "unapproved";
    return null;
}

// Palette list. cmds: ui-launch commands; pinnedIds: ordered ids. Without a query: pinned (in pin order), then recently
// run (newest first), then by name. With a query: by score, pinned and recent get a small bonus.
// Automations are listed only with showAuto.
function rank(cmds, pinnedIds, query, showAuto) {
    var q = (query || "").trim().toLowerCase();
    var out = [];
    for (var i = 0; i < cmds.length; i++) {
        var c = cmds[i];
        if (c.example) continue;
        if (c.kind === "auto" && !showAuto) continue;
        var pi = pinnedIds.indexOf(c.id);
        var s = score(c, q);
        if (s <= 0) continue;
        var ts = c.last_run ? (c.last_run.ts || 0) : 0;
        out.push({ cmd: c, score: s, pin: pi, ts: ts });
    }
    out.sort(function (a, b) {
        if (q === "") {
            if ((a.pin >= 0) !== (b.pin >= 0)) return a.pin >= 0 ? -1 : 1;
            if (a.pin >= 0 && b.pin >= 0 && a.pin !== b.pin) return a.pin - b.pin;
            if (a.ts !== b.ts) return b.ts - a.ts;
        } else {
            var sa = a.score + (a.pin >= 0 ? 15 : 0) + (a.ts > 0 ? 5 : 0), sb = b.score + (b.pin >= 0 ? 15 : 0) + (b.ts > 0 ? 5 : 0);
            if (sa !== sb) return sb - sa;
        }
        return a.cmd.name.toLowerCase() < b.cmd.name.toLowerCase() ? -1 : (a.cmd.name.toLowerCase() > b.cmd.name.toLowerCase() ? 1 : 0);
    });
    return out.map(function (x) { return x.cmd; });
}

// Pinned commands in pin order (ids that no longer exist are skipped).
function pinnedOf(cmds, pinnedIds) {
    var out = [];
    for (var i = 0; i < pinnedIds.length; i++)
        for (var j = 0; j < cmds.length; j++) if (cmds[j].id === pinnedIds[i] && !cmds[j].example) { out.push(cmds[j]); break; }
    return out;
}

// «5 мин назад» without translation tables: the view passes the unit labels.
function ago(ts, nowMs, units) {
    if (!ts) return "";
    var d = Math.max(0, Math.floor(nowMs / 1000 - ts));
    if (d < 60) return units.now;
    if (d < 3600) return Math.floor(d / 60) + " " + units.min;
    if (d < 86400) return Math.floor(d / 3600) + " " + units.hour;
    return Math.floor(d / 86400) + " " + units.day;
}
