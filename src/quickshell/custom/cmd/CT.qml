import QtQuick
import "../../"
import ".."

// Text in the shell font (or the icon font with icon: true).
Text {
    property int size: 12
    property color c: ThemeBackend.text
    property bool icon: false
    color: c
    font.family: icon ? ThemeBackend.iconFont : ThemeBackend.fontFamily
    font.pixelSize: XUi.cmdFont(size)
    elide: Text.ElideRight
    renderType: Text.NativeRendering
}
