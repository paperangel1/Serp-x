pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Own translations for serpantinum-x, kept out of assets/languages/ so that
// upstream language files are never touched. Files in assets/custom-i18n/:
//   <lang>.json          common keys
//   <lang>.hotkeys.json  owned by the hotkeys feature
//   <lang>.update.json   owned by the update feature
// All files of one language are deep-merged. Language follows the stock I18n.
Item {
    id: root

    readonly property string i18nDir: Caching.serpantinumDir + "/assets/custom-i18n"
    readonly property string currentLang: I18n.currentLang
    property var translations: ({})
    property bool isReady: false

    Process {
        id: loader
        running: Caching.serpantinumDir !== ""
        command: [
            "bash",
            "-c",
            `d="$1"; ls "$d"/*.json >/dev/null 2>&1 && jq -n 'reduce inputs as $i ({}; ($i | input_filename | split("/") | last | split(".")[0]) as $l | .[$l] = ((.[$l] // {}) * $i))' "$d"/*.json || echo "{}"`,
            "xi18n",
            root.i18nDir
        ]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let txt = this.text.trim();
                    root.translations = txt.length > 0 ? JSON.parse(txt) : {};
                } catch (e) { XLog.warn("ui", "XI18n.qml: could not parse JSON output (line 36)");
                    root.translations = {};
                }
                root.isReady = true;
            }
        }
    }

    function resolveKey(lang, key) {
        let node = root.translations ? root.translations[lang] : null;
        if (!node) return null;
        let parts = key.split(".");
        for (let i = 0; i < parts.length; i++) {
            if (node === null || node === undefined || node[parts[i]] === undefined) return null;
            node = node[parts[i]];
        }
        return typeof node === "string" ? node : null;
    }

    // t(key, args, fallback): args is an I18n-style object ({name: value} replaces {name}),
    // fallback is returned when the key is missing in the current language and in English.
    function t(key, args, fallback) {
        let text = root.isReady ? resolveKey(root.currentLang, key) : null;
        if (text === null && root.isReady && root.currentLang !== "en") text = resolveKey("en", key);
        if (text === null) {
            if (fallback === undefined || fallback === null) return key;
            text = String(fallback);
        }
        if (args && typeof args === "object") {
            for (let k in args) text = text.replace(new RegExp("\\{" + k + "\\}", "g"), args[k]);
        }
        return text;
    }
}
