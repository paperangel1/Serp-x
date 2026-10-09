import QtQuick
import QtQuick.Layouts
import Quickshell
import "../../"
import ".."
import "ColorUtil.js" as ColorUtil

// View of the eyedropper (see PickerOverlay.qml for the layer-shell window / screen capture around it).
// Shows the frozen frame with a 13x13 pixel loupe at the cursor; the pixel is read from the frozen
// frame, so it is exact regardless of overlays, scaling or what is under the loupe.
Item {
    id: root

    property string frozenUrl: ""
    property bool imageReady: false
    property real mx: 0
    property real my: 0
    property string hex: "#000000"
    property bool shiftDown: false
    property string kind: "hex"

    signal closeRequested()
    signal copyRequested(bool alt)
    signal historyRequested()

    readonly property int grid: 13
    readonly property string shownKind: shiftDown ? ColorUtil.altKind(kind) : kind

    function s(v) { return Scaler.s(v); }

    // drawImage of the grid x grid neighbourhood of (sx, sy), clipped to the image bounds
    // (drawImage() throws when the source rectangle leaves the image).
    function drawNeighbourhood(ctx, sx, sy, scale) {
        let imgW = frozen.sourceSize.width, imgH = frozen.sourceSize.height, half = Math.floor(grid / 2);
        let x0 = sx - half, y0 = sy - half;
        let cx0 = Math.max(0, x0), cy0 = Math.max(0, y0), cx1 = Math.min(imgW, x0 + grid), cy1 = Math.min(imgH, y0 + grid);
        if (cx1 > cx0 && cy1 > cy0)
            ctx.drawImage(frozenUrl, cx0, cy0, cx1 - cx0, cy1 - cy0, (cx0 - x0) * scale, (cy0 - y0) * scale, (cx1 - cx0) * scale, (cy1 - cy0) * scale);
    }

    function moveTo(x, y) { mx = x; my = y; sampler.requestPaint(); }

    Item {
        id: stage
        anchors.fill: parent
        focus: true

        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_Escape) { root.closeRequested(); e.accepted = true; }
            else if (e.key === Qt.Key_H) { root.closeRequested(); root.historyRequested(); e.accepted = true; }
            else if (e.key === Qt.Key_Shift) { root.shiftDown = true; e.accepted = true; }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.copyRequested(false); e.accepted = true; }
        }
        Keys.onReleased: (e) => { if (e.key === Qt.Key_Shift) root.shiftDown = false; }

        Image {
            id: frozen
            anchors.fill: parent
            source: root.frozenUrl
            cache: false
            asynchronous: false
            fillMode: Image.Stretch
            onStatusChanged: if (status === Image.Ready) { sampler.loadImage(root.frozenUrl); }
        }

        // Sampling surface: the 13x13 neighbourhood of the cursor, drawn from the frozen frame.
        // Also shown scaled up (nearest neighbour) as the loupe.
        Canvas {
            id: sampler
            width: root.grid; height: root.grid
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            smooth: false
            x: -width - 10; y: -height - 10        // never visible, but kept "visible" so it paints
            onImageLoaded: { root.imageReady = true; requestPaint(); loupeCanvas.loadImage(root.frozenUrl); }
            onPaint: {
                if (!isImageLoaded(root.frozenUrl)) return;
                let ctx = getContext("2d");
                ctx.imageSmoothingEnabled = false;
                ctx.clearRect(0, 0, width, height);
                let kx = frozen.sourceSize.width / Math.max(1, root.width);
                let ky = frozen.sourceSize.height / Math.max(1, root.height);
                let sx = Math.max(0, Math.min(frozen.sourceSize.width - 1, Math.floor(root.mx * kx))), sy = Math.max(0, Math.min(frozen.sourceSize.height - 1, Math.floor(root.my * ky)));
                let half = Math.floor(root.grid / 2);
                root.drawNeighbourhood(ctx, sx, sy, 1);
                let d = ctx.getImageData(half, half, 1, 1).data;
                root.hex = ColorUtil.rgbToHex(d[0], d[1], d[2]);
                loupeCanvas.sx = sx; loupeCanvas.sy = sy;
                loupeCanvas.requestPaint();
            }
        }

        // Cluster that follows the cursor: loupe, value chip, hint.
        Item {
            id: cluster
            readonly property real loupeSize: root.s(168)
            width: Math.max(loupeSize, chip.width, hint.width)
            height: loupeSize + root.s(12) + chip.height + root.s(10) + hint.height
            visible: root.imageReady
            x: {
                let want = root.mx + root.s(28);
                return want + width > root.width - root.s(8) ? root.mx - root.s(28) - width : want;
            }
            y: {
                let want = root.my + root.s(28);
                return want + height > root.height - root.s(8) ? root.my - root.s(28) - height : want;
            }

            Item {
                id: loupe
                width: cluster.loupeSize; height: cluster.loupeSize
                anchors.horizontalCenter: parent.horizontalCenter

                Canvas {
                    id: loupeCanvas
                    anchors.fill: parent
                    renderTarget: Canvas.Image
                    renderStrategy: Canvas.Immediate
                    property int sx: 0
                    property int sy: 0
                    onImageLoaded: requestPaint()
                    onPaint: {
                        let ctx = getContext("2d");
                        let w = width, r = w / 2, half = Math.floor(root.grid / 2), cell = w / root.grid;
                        ctx.clearRect(0, 0, w, w);
                        ctx.save();
                        ctx.beginPath(); ctx.arc(r, r, r, 0, 2 * Math.PI); ctx.clip();
                        ctx.fillStyle = "#11111b"; ctx.fillRect(0, 0, w, w);
                        if (isImageLoaded(root.frozenUrl)) {
                            ctx.imageSmoothingEnabled = false;
                            root.drawNeighbourhood(ctx, sx, sy, cell);
                        }
                        ctx.strokeStyle = "rgba(0,0,0,0.18)"; ctx.lineWidth = 1;
                        for (let i = 1; i < root.grid; i++) {
                            ctx.beginPath(); ctx.moveTo(i * cell, 0); ctx.lineTo(i * cell, w); ctx.stroke();
                            ctx.beginPath(); ctx.moveTo(0, i * cell); ctx.lineTo(w, i * cell); ctx.stroke();
                        }
                        ctx.strokeStyle = ColorUtil.contrastText(root.hex); ctx.lineWidth = 2;
                        ctx.strokeRect(half * cell + 1, half * cell + 1, cell - 2, cell - 2);
                        ctx.restore();
                    }
                }
                Rectangle {
                    anchors.fill: parent; radius: width / 2; color: "transparent"
                    border.width: 3; border.color: ThemeBackend.mauve
                }
            }

            Rectangle {
                id: chip
                anchors.horizontalCenter: parent.horizontalCenter
                y: cluster.loupeSize + root.s(12)
                width: chipRow.implicitWidth + root.s(24)
                height: root.s(56)
                radius: ThemeBackend.borderRadius + root.s(2)
                color: ThemeBackend.crust
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.surface2, 0.7)

                RowLayout {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: root.s(12)
                    Rectangle {
                        implicitWidth: root.s(38); implicitHeight: root.s(38)
                        radius: root.s(8)
                        color: root.hex
                        border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.25)
                    }
                    ColumnLayout {
                        spacing: root.s(2)
                        Text {
                            text: ColorUtil.format(root.hex, root.shownKind)
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fHead; font.weight: Font.DemiBold
                            color: ThemeBackend.text
                        }
                        Text {
                            text: ColorUtil.rgbString(root.hex) + "  ·  " + ColorUtil.hslString(root.hex)
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                            color: ThemeBackend.subtext0
                        }
                    }
                }
            }

            Rectangle {
                id: hint
                anchors.horizontalCenter: parent.horizontalCenter
                y: chip.y + chip.height + root.s(10)
                width: hintText.implicitWidth + root.s(28)
                height: root.s(30)
                radius: root.s(8)
                color: ThemeBackend.crust
                border.width: 1; border.color: Qt.alpha(ThemeBackend.surface2, 0.5)
                Text {
                    id: hintText
                    anchors.centerIn: parent
                    text: XI18n.t("tools.picker.hint", { kind: root.kind.toUpperCase(), alt: ColorUtil.altKind(root.kind).toUpperCase() },
                                  "ЛКМ — копировать " + root.kind.toUpperCase() + "  ·  Shift — " + ColorUtil.altKind(root.kind).toUpperCase() + "  ·  Esc — отмена")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.subtext0
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.CrossCursor
            onPositionChanged: (m) => { root.shiftDown = (m.modifiers & Qt.ShiftModifier) !== 0; root.moveTo(m.x, m.y); }
            onClicked: (m) => {
                if (m.button === Qt.RightButton) root.closeRequested();
                else root.copyRequested((m.modifiers & Qt.ShiftModifier) !== 0);
            }
        }
    }
}
