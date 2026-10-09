pragma Singleton
import QtQuick
import Quickshell
import "../"

// Settings of the tools (settings.json -> "tools"): quick notes corner, colour picker, OCR.
// Every read is merged over the defaults below; every write goes through the stock Config
// singleton (refuses until the settings file has been read, so defaults never overwrite user data).
Item {
    id: root

    readonly property var defaults: ({
        notes:  { enabled: true, corner: "bottom-right", showDelay: 350, expandDelay: 900,
                  noFullscreen: true, noDrag: true, dir: "", monitor: "all" },
        picker: { format: "hex", history: true, max: 30 },
        ocr:    { langs: "rus+eng", joinLines: false }
    })

    readonly property var cfg: {
        let raw = Config.rawSettings ? Config.rawSettings["tools"] : null;
        let t = (raw && typeof raw === "object") ? raw : {};
        let out = {};
        for (let sec in defaults) out[sec] = Object.assign({}, defaults[sec], (t[sec] && typeof t[sec] === "object") ? t[sec] : {});
        return out;
    }

    readonly property var notes: cfg.notes
    readonly property var picker: cfg.picker
    readonly property var ocr: cfg.ocr

    function set(section, key, value) {
        if (!Config.dataReady) return false;
        Config.setSetting("tools." + section + "." + key, value);
        return true;
    }

    readonly property string scriptsDir: Caching.serpantinumDir + "/scripts/custom"
}
