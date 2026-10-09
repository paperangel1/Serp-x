pragma Singleton
import QtQuick
import "../../"

// Tokens of the Commands window: pin-type colours, node-category colours and the node geometry shared with
// src/scripts/custom/cmd/xcmd/uiview.py (HDR/ROW/PAD_TOP/FOOT/NOTE_H must stay in sync).
QtObject {
    readonly property int hdr: 32
    readonly property int row: 26
    readonly property int padTop: 6
    readonly property int foot: 12
    readonly property int noteH: 20

    readonly property var typeColor: ({
        "exec": "#cdd6f4", "bool": "#f38ba8", "int": "#94e2d5", "float": "#a6e3a1", "text": "#f5c2e7",
        "color": "#fab387", "list": "#89b4fa", "path": "#f9e2af", "device": "#b4befe", "time": "#74c7ec",
        "duration": "#74c7ec", "url": "#89dceb", "any": "#9399b2", "json": "#cba6f7" })
    readonly property var catColor: ({
        "event": "#f38ba8", "action": "#89b4fa", "logic": "#f9e2af", "data": "#a6e3a1",
        "ui": "#cba6f7", "func": "#94e2d5", "function": "#94e2d5", "undo": "#fab387", "unknown": "#9399b2" })
    // schema icon name -> Material Design Icons code point (Nerd Font)
    readonly property var iconMap: ({
        "play": 0xF040A, "bell": 0xF009A, "branch": 0xF062C, "loop": 0xF0456, "timer": 0xF13AB,
        "store": 0xF0193, "load": 0xF01DA, "convert": 0xF04E1, "clipboard": 0xF0147, "terminal": 0xF018D,
        "moon": 0xF0594, "palette": 0xF03D8, "window": 0xF0293, "unknown": 0xF0A39,
        "headphones": 0xF02CB, "volume": 0xF057E, "sunset": 0xF0595, "filter": 0xF0599, "brightness": 0xF00E0,
        "revert": 0xF0709, "unplug": 0xF0156,
        "clock": 0xF0150, "appclose": 0xF05AD, "workspace": 0xF056E, "monitor": 0xF0379, "lock": 0xF033E, "unlock": 0xF033F,
        "login": 0xF0342, "sleep": 0xF04B2, "function": 0xF0295, "hand": 0xF02B7, "calculator": 0xF00EC })

    function tc(t) { return typeColor[t] || typeColor["any"]; }
    function cc(c) { return catColor[c] || catColor["action"]; }
    function glyph(name) { return String.fromCodePoint(iconMap[name] !== undefined ? iconMap[name] : 0xF0AE7); }
    function pinY(n, i) { return n.y + hdr + padTop + i * row + row / 2; }
    function inP(n, i) { return Qt.point(n.x, pinY(n, i)); }
    function outP(n, i) { return Qt.point(n.x + n.w, pinY(n, i)); }
}
