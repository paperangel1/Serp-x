import QtQuick
import "../../"

// Dot grid that follows pan/zoom (screen space). Redrawn on change only; skipped when the dots would be too dense.
Canvas {
    id: g
    property real step: 24
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onZoomChanged: requestPaint()
    onPanXChanged: requestPaint()
    onPanYChanged: requestPaint()
    onPaint: {
        var c = getContext("2d");
        c.clearRect(0, 0, width, height);
        var s = step * zoom;
        if (s < 7) return;
        var ox = ((panX % s) + s) % s, oy = ((panY % s) + s) % s;
        c.fillStyle = Qt.alpha(ThemeBackend.text, 0.07);
        for (var x = ox; x < width; x += s) for (var y = oy; y < height; y += s) c.fillRect(Math.round(x), Math.round(y), 2, 2);
        var big = s * 5;
        var bx = ((panX % big) + big) % big, by = ((panY % big) + big) % big;
        c.strokeStyle = Qt.alpha(ThemeBackend.text, 0.045);
        c.lineWidth = 1;
        for (var x2 = bx; x2 < width; x2 += big) { c.beginPath(); c.moveTo(Math.round(x2) + .5, 0); c.lineTo(Math.round(x2) + .5, height); c.stroke(); }
        for (var y2 = by; y2 < height; y2 += big) { c.beginPath(); c.moveTo(0, Math.round(y2) + .5); c.lineTo(width, Math.round(y2) + .5); c.stroke(); }
    }
}
