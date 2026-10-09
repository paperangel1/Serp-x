.pragma library

// Module flags: ~/.config/serpantinum-x/modules.json  {"enabled": ["tools", "ocr", ...]}
// A missing, unreadable or malformed file means "everything is enabled" (the live system has no file).
// Module ids are the installer's: hotkeys, tools, ocr, servers, vpn, commands. "core" is always on.

function parse(text) {
    if (text === undefined || text === null) return null;
    try {
        var j = JSON.parse(String(text));
        if (j && Array.isArray(j.enabled)) return j.enabled.map(String);
    } catch (e) {}
    return null;
}

function isEnabled(list, id) {
    if (id === "core") return true;
    if (list === null || list === undefined) return true;
    return list.indexOf(id) >= 0;
}
