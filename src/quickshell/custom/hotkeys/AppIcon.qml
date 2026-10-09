import QtQuick
import Quickshell
import "../../"
import ".."

// Rounded square holding either an application icon (theme icon name / path) or a glyph.
Rectangle {
    id: root

    property string icon: ""              // theme icon name or absolute path
    property string glyph: "󰀻"            // nerd-font fallback
    property int size: 32
    property color fill: ThemeBackend.surface0
    property color glyphColor: ThemeBackend.text
    property bool selected: false

    implicitWidth: Scaler.s(size)
    implicitHeight: Scaler.s(size)
    width: implicitWidth
    height: implicitHeight
    radius: ThemeBackend.borderRadius
    color: selected ? ThemeBackend.mauve : fill
    Behavior on color { ColorAnimation { duration: 150 } }

    readonly property string resolved: {
        let ic = root.icon || "";
        if (ic === "") return "";
        if (ic.startsWith("file://") || ic.startsWith("image://")) return ic;
        if (ic.startsWith("/")) return "file://" + ic;
        let base = ic.replace(/\.(png|svg|xpm|ico)$/i, "");
        let p = Quickshell.iconPath(ic, true) || Quickshell.iconPath(base, true);
        if (p && p.length > 0) return p.startsWith("/") ? "file://" + p : p;
        return "";
    }

    Image {
        id: img
        anchors.centerIn: parent
        width: parent.width - Scaler.s(10)
        height: parent.height - Scaler.s(10)
        source: root.resolved
        visible: source !== "" && status === Image.Ready
        sourceSize: Qt.size(64, 64)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
    }

    Text {
        anchors.centerIn: parent
        visible: !img.visible
        text: root.glyph
        font.family: ThemeBackend.iconFont
        font.pixelSize: Math.max(XUi.fBody, XUi.s(Math.round(root.size * 0.5)))
        color: root.selected ? ThemeBackend.crust : root.glyphColor
    }
}
