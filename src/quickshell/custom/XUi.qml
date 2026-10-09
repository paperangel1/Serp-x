pragma Singleton
import QtQuick
import "../"

// ONE sizing source for every custom module (hotkeys, update, tools, servers, vpn, cmd, sidebar tab).
// Values are the STOCK ones (measured in guide/SettingsRow, ClickButton, Toggle, Input, IconButton, AboutTab,
// NetworkPopup, Osd), passed through the stock scaler, so our UI looks like the shell's own.
//
// Usage (file needs `import ".."` so custom/qmldir is visible; files in custom/ itself see it directly):
//     font.pixelSize: XUi.fRow            // never a bare number / s(N) for text
//     Layout.preferredHeight: XUi.rowH
//     font.pixelSize: XUi.iconMd          // icon-font glyph inside a XUi.iconBox square
//     radius: XUi.radius
// Fonts:  fCaption 11 (stock description)  fBody 12 (controls, Input/Toggle/ClickButton)  fRow 13 (stock row title)
//         fSub 14  fTitle 16 (section/popup title)  fHead 18  fHero 22 (page title, AboutTab)
// Icons:  iconSm 14  iconMd 16 (glyph in a 32 box, SettingsRow)  iconLg 20  iconXl 28
// Boxes:  iconBox 32 (SettingsRow icon)  iconBoxSm 26  rowH 32 (Input/Dropdown/Toggle/NumberSelector)
//         btnH 30 (ClickButton)  tabH 44 (sidebar tab)  rowPadX 14 / rowPadY 12 (SettingsRow)
// Gaps:   gap 12  gapSm 8  gapXs 6  gapXxs 2     Radii: radius = ThemeBackend.borderRadius, radiusBtn 10, radiusCtl 12
// Legacy: XUi.font(n) maps an old design-time literal to the nearest token; XUi.s(n) is the plain stock scaler
//         for geometry that has no token (decor, fixed popup widths).
// Commands window (cmd/): its content is designed on a 1600x860 canvas and shown with scale = cmdK; cmdZoom is
//         the unit zoom that brings its 10-13 px design type to the stock 11-14 px (see CmdWindow).
QtObject {
    function s(n) { return Scaler.s(n); }

    readonly property real fCaption: s(11)
    readonly property real fBody: s(12)
    readonly property real fRow: s(13)
    readonly property real fSub: s(14)
    readonly property real fTitle: s(16)
    readonly property real fHead: s(18)
    readonly property real fHero: s(22)

    readonly property real iconSm: s(14)
    readonly property real iconMd: s(16)
    readonly property real iconLg: s(20)
    readonly property real iconXl: s(28)

    readonly property real iconBox: s(32)
    readonly property real iconBoxSm: s(26)
    readonly property real rowH: s(32)
    readonly property real btnH: s(30)
    readonly property real tabH: s(44)
    readonly property real rowPadX: s(14)
    readonly property real rowPadY: s(12)

    readonly property real gap: s(12)
    readonly property real gapSm: s(8)
    readonly property real gapXs: s(6)
    readonly property real gapXxs: s(2)

    readonly property real radius: ThemeBackend.borderRadius
    readonly property real radiusBtn: s(10)
    readonly property real radiusCtl: s(12)

    // Old literal (what the code used to say) -> stock type step.
    function font(n) {
        if (n <= 10) return fCaption;
        if (n <= 11) return fBody;
        if (n <= 13) return fRow;
        if (n <= 14) return fSub;
        if (n <= 16) return fTitle;
        if (n <= 19) return fHead;
        return n <= 24 ? fHero : s(n);
    }

    // Commands window
    readonly property real cmdZoom: 1.1
    readonly property int cmdMinFont: 10
    function cmdFont(n) { return Math.max(cmdMinFont, n); }
}
