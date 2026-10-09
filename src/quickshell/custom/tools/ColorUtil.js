.pragma library

function pad2(n) { return (n < 16 ? "0" : "") + n.toString(16).toUpperCase(); }

function rgbToHex(r, g, b) { return "#" + pad2(r) + pad2(g) + pad2(b); }

function hexToRgb(hex) {
    let h = String(hex).replace("#", "");
    return { r: parseInt(h.substr(0, 2), 16), g: parseInt(h.substr(2, 2), 16), b: parseInt(h.substr(4, 2), 16) };
}

function rgbString(hex) { let c = hexToRgb(hex); return "rgb(" + c.r + ", " + c.g + ", " + c.b + ")"; }

function hslString(hex) {
    let c = hexToRgb(hex);
    let r = c.r / 255, g = c.g / 255, b = c.b / 255;
    let mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    let l = (mx + mn) / 2, d = mx - mn, h = 0, s = 0;
    if (d > 0) {
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        if (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
        else if (mx === g) h = (b - r) / d + 2;
        else h = (r - g) / d + 4;
        h *= 60;
    }
    return "hsl(" + Math.round(h) + ", " + Math.round(s * 100) + "%, " + Math.round(l * 100) + "%)";
}

function format(hex, kind) {
    if (kind === "rgb") return rgbString(hex);
    if (kind === "hsl") return hslString(hex);
    return String(hex).toUpperCase();
}

// The format a Shift-click yields: the other one of hex / rgb.
function altKind(kind) { return kind === "hex" ? "rgb" : "hex"; }

// Black or white, whichever reads better on the colour.
function contrastText(hex) {
    let c = hexToRgb(hex);
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 150 ? "#11111b" : "#ffffff";
}
