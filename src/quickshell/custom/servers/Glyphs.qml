pragma Singleton
import QtQuick

// Nerd Font (Material Design) code points used by the Servers views.
QtObject {
    readonly property string server: String.fromCodePoint(0xF048B)
    readonly property string refresh: String.fromCodePoint(0xF0450)
    readonly property string back: String.fromCodePoint(0xF0141)
    readonly property string network: String.fromCodePoint(0xF06F3)
    readonly property string load: String.fromCodePoint(0xF035B)
    readonly property string disk: String.fromCodePoint(0xF02CA)
    readonly property string logs: String.fromCodePoint(0xF0219)
    readonly property string ports: String.fromCodePoint(0xF048D)
    readonly property string security: String.fromCodePoint(0xF0483)
    readonly property string restart: String.fromCodePoint(0xF0450)
    readonly property string update: String.fromCodePoint(0xF0868)
    readonly property string trash: String.fromCodePoint(0xF01B4)
    readonly property string power: String.fromCodePoint(0xF0425)
    readonly property string terminal: String.fromCodePoint(0xF018D)
    readonly property string plus: String.fromCodePoint(0xF0415)
    readonly property string file: String.fromCodePoint(0xF0219)
    readonly property string check: String.fromCodePoint(0xF012C)
    readonly property string copy: String.fromCodePoint(0xF018F)
    readonly property string close: String.fromCodePoint(0xF0156)
    readonly property string key: String.fromCodePoint(0xF0306)
    readonly property string link: String.fromCodePoint(0xF0337)
    readonly property string clock: String.fromCodePoint(0xF0954)
    readonly property string repeat: String.fromCodePoint(0xF0456)
    readonly property string warn: String.fromCodePoint(0xF0026)
    readonly property string link2: String.fromCodePoint(0xF0339)
    readonly property string edit: String.fromCodePoint(0xF03EB)

    function forCommand(id) {
        switch (id) {
        case "diag-net": return network;
        case "diag-load": return load;
        case "diag-disk": return disk;
        case "diag-logs": return logs;
        case "diag-ports": return ports;
        case "diag-security": return security;
        case "act-restart-node": return restart;
        case "act-update-container": return update;
        case "act-docker-prune": return trash;
        case "act-reboot": return power;
        }
        return file;
    }
}
