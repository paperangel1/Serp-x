import QtQuick
import QtQuick.Shapes
import "../../"
import ".."
import "EditorLogic.js" as EL

// Canvas of one command graph. Viewer (editable: false): pan, zoom, hover, select. Editor (editable: true): selection set,
// drag nodes / comments (offset while dragging, one document change on release), drag from pins to wire (compatible pins
// light up, the rest dim), rubber-band selection, node palette on double click / right click / dropped wire.
// Content lives in `world` (translated + scaled), so pan/zoom never re-layouts nodes. Wires are vector Shapes (curve
// renderer); only the dot grid (screen space) is repainted while panning.
Item {
    id: root
    property var graph: null
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    property string selNode: ""
    property int selWire: -1
    property string hoverNode: ""
    property int hoverWire: -1
    property bool editable: false
    readonly property var sel: XEdit.sel
    readonly property real minZoom: 0.15
    readonly property real maxZoom: 2.5
    readonly property var nodes: graph ? graph.nodes : []
    readonly property var comments: graph ? graph.comments : []
    property real dragDx: 0
    property real dragDy: 0
    property var wireDrag: null              // {node, pin, out, t, full, x0, y0, cx, cy, picked}
    property var pinModes: ({})
    property var rejected: null              // {text, fix, from, to, wx, wy} - a wire that was refused
    property point cursor: Qt.point(0, 0)    // last pointer position in world units
    property var band: null                  // {x0, y0, x1, y1}
    signal nodeActivated(string id)
    signal emptyActivated()
    signal paletteRequested(real wx, real wy, var fromPin)
    signal editValue(string nodeId, string pinId, var item)
    signal editComment(string id, string field, var item)
    signal breakpointToggled(string id)

    // debug overlay (XCmdDebug): applied in batches by the singleton, so these bindings re-run at most every ~40 ms
    readonly property var dbgNodes: XCmdDebug.ov.nodes
    readonly property var dbgWires: XCmdDebug.ov.wires
    readonly property bool dbgOn: XCmdDebug.ov.run !== ""
    readonly property var dbgBps: XCmdDebug.bpFor(XCmd.selectedRef)

    clip: true

    // ---- geometry model (rebuilt only when the graph changes) -------------------------------------------------
    readonly property var byId: { var m = ({}); for (var i = 0; i < nodes.length; i++) m[nodes[i].id] = nodes[i]; return m; }
    function pinIndex(list, id) { for (var i = 0; i < list.length; i++) if (list[i].id === id) return i; return -1; }
    function movedBy(id) { return editable && sel.nodes[id] ? 1 : 0; }
    function nodeAt(n) { var m = movedBy(n.id); return { x: n.x + m * dragDx, y: n.y + m * dragDy, w: n.w }; }
    function curve(a, b) {
        var dx = Math.max(40, Math.min(240, Math.abs(b.x - a.x) * 0.5)), pts = [];
        for (var k = 0; k <= 16; k++) {
            var t = k / 16, u = 1 - t, c1x = a.x + dx, c2x = b.x - dx;
            pts.push({ x: u*u*u*a.x + 3*u*u*t*c1x + 3*u*t*t*c2x + t*t*t*b.x, y: u*u*u*a.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*b.y });
        }
        return { dx: dx, pts: pts };
    }
    readonly property var wireGeo: {
        var out = [], ws = graph ? graph.wires : [], bad = editable ? XEdit.issues.pins : ({});
        for (var i = 0; i < ws.length; i++) {
            var w = ws[i], A = byId[w.from[0]], B = byId[w.to[0]];
            if (!A || !B) continue;
            var ai = pinIndex(A.outs, w.from[1]), bi = pinIndex(B.ins, w.to[1]);
            if (ai < 0 || bi < 0) continue;
            var a = CK.outP(nodeAt(A), ai), b = CK.inP(nodeAt(B), bi), c = curve(a, b);
            out.push({ ax: a.x, ay: a.y, bx: b.x, by: b.y, dx: c.dx, t: w.t, from: w.from[0], to: w.to[0], pts: c.pts,
                       key: w.from[0] + ":" + w.from[1] + ">" + w.to[0] + ":" + w.to[1], bad: !!bad[w.to[0] + ":" + w.to[1]] });
        }
        return out;
    }
    function wireColor(i) {
        var w = wireGeo[i];
        return w.bad ? Qt.rgba(0.95, 0.55, 0.66, 1) : (w.t === "exec" ? Qt.rgba(0.80, 0.84, 0.96, 1) : CK.tc(w.t));
    }
    function wireHot(i) {
        var w = wireGeo[i];
        return i === selWire || i === hoverWire || (editable && !!sel.wires[w.key]) || (hoverNode !== "" && (w.from === hoverNode || w.to === hoverNode))
            || (selNode !== "" && (w.from === selNode || w.to === selNode));
    }
    function wireAt(wx, wy) {
        var best = -1, bd = 9 / zoom;
        for (var i = 0; i < wireGeo.length; i++) {
            var p = wireGeo[i].pts;
            for (var k = 0; k < p.length - 1; k++) {
                var vx = p[k+1].x - p[k].x, vy = p[k+1].y - p[k].y, l2 = vx*vx + vy*vy;
                var t = l2 === 0 ? 0 : Math.max(0, Math.min(1, ((wx - p[k].x)*vx + (wy - p[k].y)*vy) / l2));
                var d = Math.hypot(wx - (p[k].x + t*vx), wy - (p[k].y + t*vy));
                if (d < bd) { bd = d; best = i; }
            }
        }
        return best;
    }
    function inView(n) {
        var x0 = -panX / zoom - 40, y0 = -panY / zoom - 40, x1 = (width - panX) / zoom + 40, y1 = (height - panY) / zoom + 40;
        return n.x < x1 && n.x + n.w > x0 && n.y < y1 && n.y + n.h > y0;
    }
    function toWorld(sx, sy) { var p = root.mapFromItem(null, sx, sy); return Qt.point((p.x - panX) / zoom, (p.y - panY) / zoom); }
    function pinPoint(nodeId, pinId, out) {      // world position of a pin
        var n = byId[nodeId];
        if (!n) return null;
        var i = pinIndex(out ? n.outs : n.ins, pinId);
        return i < 0 ? null : (out ? CK.outP(n, i) : CK.inP(n, i));
    }
    function pinAt(wx, wy) {
        var best = null, bd = 1e9;
        for (var k = 0; k < nodes.length; k++) {
            var n = nodes[k];
            if (wy < n.y + CK.hdr || wy > n.y + n.h || wx < n.x - 22 || wx > n.x + n.w + 22) continue;
            var side = [[n.ins, false, n.x], [n.outs, true, n.x + n.w]];
            for (var s = 0; s < 2; s++) {
                var list = side[s][0];
                for (var i = 0; i < list.length; i++) {
                    var py = n.y + CK.hdr + CK.padTop + i * CK.row + CK.row / 2, d = Math.hypot(wx - side[s][2], wy - py);
                    if (d < 18 && d < bd) { bd = d; best = { node: n.id, pin: list[i].id, out: side[s][1], t: list[i].t, full: list[i].full }; }
                }
            }
        }
        return best;
    }

    // ---- view control -----------------------------------------------------------------------------------------
    function clampZoom(z) { return Math.max(minZoom, Math.min(maxZoom, z)); }
    function zoomAt(factor, cx, cy) {
        var nz = clampZoom(zoom * factor);
        panX = cx - (cx - panX) * (nz / zoom);
        panY = cy - (cy - panY) * (nz / zoom);
        zoom = nz;
    }
    function fit(margin) {
        var b = graph ? graph.bounds : null;
        if (!b || b.w <= 0 || width <= 0 || height <= 0) { zoom = 1; panX = 40; panY = 40; return; }
        var m = margin === undefined ? 40 : margin;
        var z = clampZoom(Math.min(1, Math.min((width - 2 * m) / b.w, (height - 2 * m) / b.h)));
        zoom = z;
        panX = (width - b.w * z) / 2 - b.x * z;
        panY = (height - b.h * z) / 2 - b.y * z;
    }
    function centerOn(wx, wy) { panX = width / 2 - wx * zoom; panY = height / 2 - wy * zoom; }
    function revealNode(id) {
        var n = byId[id];
        if (!n) return;
        var sx = panX + n.x * zoom, sy = panY + n.y * zoom;
        if (sx < 20 || sy < 20 || sx + n.w * zoom > width - 20 || sy + n.h * zoom > height - 20) centerOn(n.x + n.w / 2, n.y + n.h / 2);
    }
    // the editor replaces `graph` on every edit: keep the view still, refit only when another command is opened
    property string _graphId: ""
    onGraphChanged: {
        hoverNode = ""; hoverWire = -1;
        var id = graph && graph.id ? graph.id : "";
        if (!editable) { selNode = ""; selWire = -1; }
        if (id !== _graphId || !editable) { _graphId = id; Qt.callLater(fit); }
    }
    onWidthChanged: if (graph && !_userMoved && !editable) Qt.callLater(fit)
    property bool _userMoved: false
    onSelChanged: if (editable) {
        var ks = Object.keys(sel.nodes);
        selNode = ks.length === 1 && Object.keys(sel.wires).length === 0 && Object.keys(sel.comments).length === 0 ? ks[0] : "";
    }

    // ---- editing: drag of the selection ------------------------------------------------------------------------
    property bool _dragMoved: false
    function dragBegin(kind, id, shift) {
        _dragMoved = false;
        if (kind === "node") { if (!sel.nodes[id]) XEdit.selectNode(id, shift); }
        else if (!sel.comments[id]) XEdit.selectComment(id, shift);
    }
    function dragUpdate(sx, sy) { _dragMoved = true; dragDx = EL.snap(sx / zoom); dragDy = EL.snap(sy / zoom); }
    function dragEnd(kind, id, moved, shift) {
        if (moved && _dragMoved) { var dx = dragDx, dy = dragDy; dragDx = 0; dragDy = 0; XEdit.moveSelection(dx, dy); }
        else {
            dragDx = 0; dragDy = 0;
            if (!shift) { if (kind === "node") XEdit.selectNode(id, false); else XEdit.selectComment(id, false); }
            else if (kind === "node") XEdit.selectNode(id, true);     // shift-click toggles
        }
        _dragMoved = false;
    }

    // ---- editing: wires ----------------------------------------------------------------------------------------
    function computeModes(node, pin, isOut) {
        var cmd = XEdit.command, cat = XCmd.catalog, modes = ({});
        for (var k = 0; k < nodes.length; k++) {
            var n = nodes[k], m = ({}), i;
            if (n.id !== node) {
                for (i = 0; i < n.ins.length; i++)
                    m["i:" + n.ins[i].id] = isOut && EL.canConnect(cmd, cat, [node, pin], [n.id, n.ins[i].id]).ok ? 1 : -1;
                for (i = 0; i < n.outs.length; i++)
                    m["o:" + n.outs[i].id] = !isOut && EL.canConnect(cmd, cat, [n.id, n.outs[i].id], [node, pin]).ok ? 1 : -1;
            } else {
                for (i = 0; i < n.ins.length; i++) m["i:" + n.ins[i].id] = (!isOut && n.ins[i].id === pin) ? 1 : -1;
                for (i = 0; i < n.outs.length; i++) m["o:" + n.outs[i].id] = (isOut && n.outs[i].id === pin) ? 1 : -1;
            }
            modes[n.id] = m;
        }
        return modes;
    }
    function wireStart(id, pin, isOut, t) {
        rejected = null;
        var picked = "", from = null;
        if (!isOut) {                       // a wired input picks its wire up and carries the source end
            var ws = graph ? graph.wires : [];
            for (var i = 0; i < ws.length; i++) if (ws[i].to[0] === id && ws[i].to[1] === pin) { from = ws[i].from; picked = EL.wireKey(ws[i]); }
        }
        var nid = from ? from[0] : id, npin = from ? from[1] : pin, out = from ? true : isOut;
        var p = pinPoint(nid, npin, out);
        if (!p) return;
        var n = byId[nid], pi = pinIndex(out ? n.outs : n.ins, npin);
        var pr = out ? n.outs[pi] : n.ins[pi];
        wireDrag = { node: nid, pin: npin, out: out, t: pr.t, full: pr.full, x0: p.x, y0: p.y, cx: p.x, cy: p.y, picked: picked, origin: [id, pin] };
        pinModes = computeModes(nid, npin, out);
    }
    function wireMove(sx, sy) {
        if (!wireDrag) return;
        var w = toWorld(sx, sy), d = Object.assign({}, wireDrag);
        d.cx = w.x; d.cy = w.y;
        wireDrag = d;
        cursor = w;
    }
    function wireEnd(sx, sy) {
        if (!wireDrag) return;
        var w = toWorld(sx, sy), d = wireDrag, target = pinAt(w.x, w.y);
        wireDrag = null; pinModes = ({});
        if (target && target.node !== d.node && target.out !== d.out) {
            var from = d.out ? [d.node, d.pin] : [target.node, target.pin], to = d.out ? [target.node, target.pin] : [d.node, d.pin];
            if (d.picked !== "" && to[0] === d.origin[0] && to[1] === d.origin[1]) return;      // dropped on its own input: nothing changes
            var chk = EL.canConnect(XEdit.command, XCmd.catalog, from, to);
            if (chk.ok) { if (d.picked !== "") XEdit.rewire(d.picked, from, to); else XEdit.connectPins(from, to); }
            else rejected = { text: chk.reason, fix: chk.fix || null, from: from, to: to, tx: w.x, ty: w.y };
        } else if (target === null) {
            if (d.picked !== "") XEdit.disconnectKey(d.picked);                                   // dragged off an input and dropped on nothing
            else paletteRequested(w.x, w.y, { node: d.node, pin: d.pin, out: d.out, t: d.t, full: d.full });
        }
    }
    function wireCancel() { wireDrag = null; pinModes = ({}); }

    GridBg { anchors.fill: parent; zoom: root.zoom; panX: root.panX; panY: root.panY }

    // background of the editor: band selection, pan (middle / right button), wire pick, palette
    MouseArea {
        id: bg
        enabled: root.editable
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        property real px: 0
        property real py: 0
        property real spx: 0
        property real spy: 0
        property bool moved: false
        property int btn: 0
        onPressed: (m) => {
            root.forceActiveFocus();
            var p = mapToItem(null, m.x, m.y);
            px = p.x; py = p.y; spx = root.panX; spy = root.panY; moved = false; btn = m.button;
            var w = root.toWorld(p.x, p.y);
            if (m.button === Qt.LeftButton) root.band = { x0: w.x, y0: w.y, x1: w.x, y1: w.y, add: (m.modifiers & Qt.ShiftModifier) !== 0 };
        }
        onPositionChanged: (m) => {
            var p = mapToItem(null, m.x, m.y), w = root.toWorld(p.x, p.y);
            root.cursor = w;
            if (!pressed) {
                if (root.hoverNode === "") root.hoverWire = root.wireAt(w.x, w.y);
                return;
            }
            var dx = p.x - px, dy = p.y - py;
            if (!moved && Math.abs(dx) + Math.abs(dy) < 4) return;
            moved = true;
            if (btn === Qt.LeftButton) root.band = { x0: root.band.x0, y0: root.band.y0, x1: w.x, y1: w.y, add: root.band.add };
            else { root._userMoved = true; root.panX = spx + dx; root.panY = spy + dy; }
        }
        onReleased: (m) => {
            var p = mapToItem(null, m.x, m.y), w = root.toWorld(p.x, p.y);
            if (btn === Qt.LeftButton && root.band) {
                var b = root.band;
                root.band = null;
                if (moved) XEdit.selectRect(Math.min(b.x0, b.x1), Math.min(b.y0, b.y1), Math.max(b.x0, b.x1), Math.max(b.y0, b.y1), b.add);
                else {
                    var i = root.wireAt(w.x, w.y);
                    if (i >= 0) XEdit.selectWire(root.wireGeo[i].key); else if (!b.add) XEdit.clearSel();
                    root.rejected = null;
                    root.emptyActivated();
                }
            } else if (btn === Qt.RightButton && !moved) root.paletteRequested(w.x, w.y, null);
            btn = 0;
        }
        onDoubleClicked: (m) => { if (m.button === Qt.LeftButton) { var p = mapToItem(null, m.x, m.y), w = root.toWorld(p.x, p.y); root.paletteRequested(w.x, w.y, null); } }
        onExited: root.hoverWire = -1
    }

    Item {
        id: world
        x: root.panX; y: root.panY
        width: 1; height: 1
        scale: root.zoom
        transformOrigin: Item.TopLeft

        Repeater {
            model: root.comments
            delegate: Rectangle {
                id: cm
                readonly property bool isSel: root.editable && !!root.sel.comments[modelData.id]
                readonly property real mv: root.editable && root.sel.comments[modelData.id] ? 1 : 0
                x: modelData.x + mv * root.dragDx; y: modelData.y + mv * root.dragDy; width: modelData.w + rw; height: modelData.h + rh; radius: 12
                property real rw: 0
                property real rh: 0
                readonly property color tone: modelData.color !== "" ? modelData.color : "#f9e2af"
                color: Qt.alpha(tone, 0.08)
                border.width: isSel ? 2 : 1
                border.color: isSel ? ThemeBackend.mauve : Qt.alpha(tone, 0.45)
                CT { x: 14; y: 10; icon: true; text: "\u{f06e8}"; size: 14; c: parent.tone }
                CT { x: 36; y: 10; width: parent.width - (root.editable ? 78 : 50); text: modelData.title !== "" ? modelData.title : XI18n.t("cmd.graph.comment", undefined, "Комментарий"); size: 12; font.bold: true; c: parent.tone }
                CT { x: 14; y: 36; width: parent.width - 28; height: parent.height - 44; text: modelData.text; size: 11; c: ThemeBackend.subtext1; wrapMode: Text.WordWrap; elide: Text.ElideNone }
                MouseArea {      // move / select / edit (double click: title in the header strip, text below)
                    enabled: root.editable
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    property real px: 0
                    property real py: 0
                    property bool moved: false
                    onPressed: (m) => { var p = mapToItem(null, m.x, m.y); px = p.x; py = p.y; moved = false; root.dragBegin("comment", modelData.id, (m.modifiers & Qt.ShiftModifier) !== 0); }
                    onPositionChanged: (m) => {
                        if (!pressed) return;
                        var p = mapToItem(null, m.x, m.y), dx = p.x - px, dy = p.y - py;
                        if (!moved && Math.abs(dx) + Math.abs(dy) < 4) return;
                        moved = true; root.dragUpdate(dx, dy);
                    }
                    onReleased: (m) => root.dragEnd("comment", modelData.id, moved, (m.modifiers & Qt.ShiftModifier) !== 0)
                    onDoubleClicked: (m) => root.editComment(modelData.id, m.y < 34 ? "title" : "text", cm)
                }
                Rectangle {      // colour swatch: cycles the colour
                    visible: root.editable
                    x: parent.width - 34; y: 8; width: 20; height: 20; radius: 10; color: Qt.alpha(cm.tone, 0.9); border.width: 1; border.color: Qt.alpha(ThemeBackend.text, 0.3)
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: XEdit.editComment(modelData.id, { color: EL.nextCommentColor(modelData.color) }) }
                }
                Rectangle {      // resize handle
                    visible: root.editable
                    x: parent.width - 16; y: parent.height - 16; width: 14; height: 14; radius: 4; color: Qt.alpha(cm.tone, 0.35)
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -4
                        cursorShape: Qt.SizeFDiagCursor
                        property real px: 0
                        property real py: 0
                        onPressed: (m) => { var p = mapToItem(null, m.x, m.y); px = p.x; py = p.y; }
                        onPositionChanged: (m) => {
                            if (!pressed) return;
                            var p = mapToItem(null, m.x, m.y);
                            cm.rw = Math.max(160 - modelData.w, EL.snap((p.x - px) / root.zoom)); cm.rh = Math.max(70 - modelData.h, EL.snap((p.y - py) / root.zoom));
                        }
                        onReleased: { var w = modelData.w + cm.rw, h = modelData.h + cm.rh; cm.rw = 0; cm.rh = 0; XEdit.editComment(modelData.id, { w: w, h: h }); }
                    }
                }
            }
        }

        Repeater {
            model: root.wireGeo
            delegate: Shape {
                id: ws
                readonly property var dw: root.dbgOn ? root.dbgWires[modelData.key] : undefined
                readonly property int dwSeq: dw ? dw.seq : 0
                property bool pulsing: false
                property real pulse: 0
                onDwSeqChanged: if (dwSeq > 0 && root.dbgOn) { pulsing = true; pulse = 1; pulseAnim.restart(); }
                NumberAnimation { id: pulseAnim; target: ws; property: "pulse"; from: 1; to: 0; duration: 700; onFinished: ws.pulsing = false }
                readonly property bool hot: root.wireHot(index) || (ws.dw !== undefined && ws.dw.exec)
                readonly property color col: root.wireColor(index)
                preferredRendererType: Shape.CurveRenderer
                z: hot ? 2 : 0
                ShapePath {   // pulse while execution passes along the wire (debug overlay)
                    strokeColor: ws.pulsing ? Qt.rgba(1, 1, 1, 0.75 * ws.pulse) : "transparent"
                    strokeWidth: ws.pulsing ? 6 : 0
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: modelData.ax; startY: modelData.ay
                    PathCubic { x: modelData.bx; y: modelData.by; control1X: modelData.ax + modelData.dx; control1Y: modelData.ay; control2X: modelData.bx - modelData.dx; control2Y: modelData.by }
                }
                ShapePath {
                    strokeColor: ws.hot ? Qt.alpha(ws.col, 0.22) : "transparent"
                    strokeWidth: 10
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: modelData.ax; startY: modelData.ay
                    PathCubic { x: modelData.bx; y: modelData.by; control1X: modelData.ax + modelData.dx; control1Y: modelData.ay; control2X: modelData.bx - modelData.dx; control2Y: modelData.by }
                }
                ShapePath {
                    strokeColor: ws.hot ? ws.col : Qt.alpha(ws.col, modelData.t === "exec" ? 0.9 : 0.75)
                    strokeWidth: modelData.t === "exec" ? 3 : 2
                    strokeStyle: modelData.bad ? ShapePath.DashLine : ShapePath.SolidLine
                    dashPattern: [4, 3]
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: modelData.ax; startY: modelData.ay
                    PathCubic { x: modelData.bx; y: modelData.by; control1X: modelData.ax + modelData.dx; control1Y: modelData.ay; control2X: modelData.bx - modelData.dx; control2Y: modelData.by }
                }
            }
        }

        // data wires that carried a value in the shown run: last value chip (hover / small graphs only, so 200 nodes stay cheap)
        Repeater {
            model: root.dbgOn && root.zoom > 0.4 ? root.wireGeo : []
            delegate: Loader {
                id: chipLd
                readonly property var dw: root.dbgWires[modelData.key]
                active: dw !== undefined && !dw.exec && dw.value !== undefined && (root.nodes.length <= 40 || root.hoverWire === index || root.hoverNode === modelData.from || root.hoverNode === modelData.to)
                x: (modelData.ax + modelData.bx) / 2 - width / 2; y: (modelData.ay + modelData.by) / 2 - height / 2 - 12
                z: 6
                sourceComponent: Rectangle {
                    width: Math.min(160, vt.implicitWidth + 14); height: 20; radius: 6
                    color: ThemeBackend.surface0; border.width: 1; border.color: Qt.alpha(CK.tc(modelData.t), 0.6)
                    CT { id: vt; anchors.centerIn: parent; width: parent.width - 10; horizontalAlignment: Text.AlignHCenter; size: 10; c: CK.tc(modelData.t)
                         text: chipLd.dw ? String(chipLd.dw.value) : "" }
                }
            }
        }

        // the wire being dragged
        Shape {
            visible: root.wireDrag !== null
            z: 4
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                id: dragPath
                readonly property var d: root.wireDrag
                readonly property real dir: d && d.out ? 1 : -1
                readonly property real hx: d ? Math.max(40, Math.min(240, Math.abs(d.cx - d.x0) * 0.5)) : 40
                strokeColor: d ? (d.t === "exec" ? Qt.rgba(0.80, 0.84, 0.96, 1) : CK.tc(d.t)) : "transparent"
                strokeWidth: d && d.t === "exec" ? 3 : 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: d ? d.x0 : 0; startY: d ? d.y0 : 0
                PathCubic { x: dragPath.d ? dragPath.d.cx : 0; y: dragPath.d ? dragPath.d.cy : 0
                            control1X: (dragPath.d ? dragPath.d.x0 : 0) + dragPath.dir * dragPath.hx; control1Y: dragPath.d ? dragPath.d.y0 : 0
                            control2X: (dragPath.d ? dragPath.d.cx : 0) - dragPath.dir * dragPath.hx; control2Y: dragPath.d ? dragPath.d.cy : 0 }
            }
        }

        Repeater {
            model: root.nodes
            delegate: NodeCard {
                node: modelData
                z: 3
                visible: root.inView(modelData)
                editable: root.editable
                selected: root.editable ? !!root.sel.nodes[modelData.id] : root.selNode === modelData.id
                hovered: root.hoverNode === modelData.id
                dbg: root.dbgOn && root.dbgNodes[modelData.id] ? root.dbgNodes[modelData.id].state : ""
                hasBp: !!root.dbgBps[modelData.id]
                bpOk: XEdit.mode !== "function"
                onBpToggled: (id) => root.breakpointToggled(id)
                dx: root.movedBy(modelData.id) * root.dragDx
                dy: root.movedBy(modelData.id) * root.dragDy
                pinMode: root.wireDrag ? (root.pinModes[modelData.id] || ({})) : ({})
                onTapped: (id) => { root._nodeTapped = true; root.selNode = id; root.selWire = -1; root.nodeActivated(id); }
                onHoverChanged: (id, on) => { if (on) root.hoverNode = id; else if (root.hoverNode === id) root.hoverNode = ""; }
                onPressedAt: (id, shift) => { root.rejected = null; root.dragBegin("node", id, shift); }
                onDragBy: (sx, sy) => root.dragUpdate(sx, sy)
                onDragEnded: (moved) => root.dragEnd("node", modelData.id, moved, false)
                onPinPressed: (id, pin, isOut, kind) => root.wireStart(id, pin, isOut, kind)
                onPinMoved: (sx, sy) => root.wireMove(sx, sy)
                onPinReleased: (sx, sy) => root.wireEnd(sx, sy)
                onValueClicked: (id, pin, item) => root.editValue(id, pin, item)
            }
        }

        Rectangle {   // rubber band
            visible: root.band !== null
            x: root.band ? Math.min(root.band.x0, root.band.x1) : 0; y: root.band ? Math.min(root.band.y0, root.band.y1) : 0
            width: root.band ? Math.abs(root.band.x1 - root.band.x0) : 0; height: root.band ? Math.abs(root.band.y1 - root.band.y0) : 0
            color: Qt.alpha(ThemeBackend.mauve, 0.10); border.width: 1; border.color: Qt.alpha(ThemeBackend.mauve, 0.7)
            z: 5
        }
    }

    property bool _nodeTapped: false

    // viewer interactions (the editor uses the MouseArea above)
    DragHandler {
        id: drag
        enabled: !root.editable
        target: null
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        property real sx: 0
        property real sy: 0
        onActiveChanged: if (active) { sx = root.panX; sy = root.panY; root._userMoved = true; }
        onTranslationChanged: if (active) { root.panX = sx + translation.x; root.panY = sy + translation.y; }
    }
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (e) => { root._userMoved = true; root.zoomAt(Math.pow(1.0015, e.angleDelta.y), point.position.x, point.position.y); }
    }
    HoverHandler {
        id: bgHover
        enabled: !root.editable
        onPointChanged: {
            if (root.hoverNode !== "") { root.hoverWire = -1; return; }
            root.hoverWire = root.wireAt((point.position.x - root.panX) / root.zoom, (point.position.y - root.panY) / root.zoom);
        }
        onHoveredChanged: if (!hovered) { root.hoverWire = -1; }
    }
    TapHandler {
        enabled: !root.editable
        onTapped: (ev, button) => {
            if (root._nodeTapped) { root._nodeTapped = false; return; }
            var i = root.wireAt((ev.position.x - root.panX) / root.zoom, (ev.position.y - root.panY) / root.zoom);
            root.selNode = ""; root.selWire = i;
            root.emptyActivated();
        }
    }
}
