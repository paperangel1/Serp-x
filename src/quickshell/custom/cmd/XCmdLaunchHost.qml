import QtQuick
import Quickshell
import "../../"
import "../../bar"
import "../../widgets"
import "../tools"
import ".."

// Launch surfaces of the Commands app, hosted from XCmdHost: the palette and bar-menu windows, the result toast, and the
// runtime registration of the «commands» bar module and the «commands» desktop widget (no upstream edit; like VPN / servers).
//
//   serpantinum ipc call xcmd palette | paletteClose | paletteToggle     (see XCmdHost.qml)
Item {
    id: root
    visible: false

    function t(key, args, fb) { return XI18n.t(key, args, fb); }

    function registerBar() {
        if (typeof BarModuleRegistry === "undefined" || !BarModuleRegistry.registerModule) return;
        BarModuleRegistry.registerModule("commands", {
            name: root.t("cmd.module.name", undefined, "Команды"),
            icon: CK.glyph("play"),
            defaultVariant: "default",
            horizontalFace: Qt.resolvedUrl("CmdFace.qml"),
            verticalFace: Qt.resolvedUrl("SideCmdFace.qml")
        });
    }
    function registerWidget() {
        if (typeof WidgetRegistry === "undefined") return;
        if (WidgetRegistry.types && WidgetRegistry.types["commands"]) return;
        let types = Object.assign({}, WidgetRegistry.types);
        types["commands"] = {
            name: root.t("cmd.widget.name", undefined, "Команды"),
            icon: CK.glyph("play"),
            iconOffsetX: 0,
            defaultWidth: 320,
            defaultHeight: 220,
            defaultVariant: "compact",
            variants: {
                "compact":  { file: "../custom/cmd/CmdWidgetCompact.qml",  icon: "1", label: root.t("cmd.widget.variant_compact", undefined, "Кнопки") },
                "detailed": { file: "../custom/cmd/CmdWidgetDetailed.qml", icon: "2", label: root.t("cmd.widget.variant_detailed", undefined, "Подробно") }
            }
        };
        WidgetRegistry.types = types;
    }
    Component.onCompleted: { registerBar(); registerWidget(); }
    Connections {
        target: XI18n
        function onTranslationsChanged() { root.registerBar(); }
    }

    // run results as a toast in the style of the tools (top centre, under the bar)
    ToolToast { id: toast }
    Connections {
        target: XCmdLaunch
        function onNotice(kind, title, sub) {
            toast.show(title, sub, kind === "error" ? ThemeBackend.red : kind === "ok" ? ThemeBackend.green : ThemeBackend.mauve, "top", kind === "running" ? 1800 : (kind === "error" ? 5000 : 2400));
        }
    }

    CmdPalette {}
    CmdMenu {}
}
