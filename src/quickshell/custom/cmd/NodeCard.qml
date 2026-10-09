import QtQuick
import "../../"
import ".."

// One Blueprint-style node. `node` is an entry of ui-get / EditorLogic.buildView:
// {id,title,icon,cat,x,y,w,h,ins,outs,note,err?,warn?,...}. Read-only viewer: tap / hover. Editor (editable): drag the
// node, drag from a pin to wire, click a value to edit it. Positions of dragged nodes are offset by (dx, dy) so the
// document is only touched when the drag ends.
Rectangle {
    id: nc
    property var node
    property bool selected: false
    property bool hovered: false
    property bool editable: false
    property real dx: 0
    property real dy: 0
    property var pinMode: ({})                 // while a wire is dragged: "i:<pin>" / "o:<pin>" -> 1 fits, -1 does not
    property string focusPin: ""               // pin whose problem bubble is open
    signal tapped(string id)
    signal hoverChanged(string id, bool on)
    signal pressedAt(string id, bool shift)
    signal dragBy(real sx, real sy)
    signal dragEnded(bool moved)
    signal pinPressed(string id, string pin, bool isOut, string kind)
    signal pinMoved(real sx, real sy)
    signal pinReleased(real sx, real sy)
    signal valueClicked(string id, string pin, var item)
    signal pinHovered(string id, string pin, bool on)
    signal bpToggled(string id)
    property string dbg: ""                    // debug overlay state: running | ok | error | skipped | paused
    property bool hasBp: false                 // breakpoint (editor session, never saved in the command)
    property bool bpOk: true
    readonly property color dbgColor: dbg === "ok" ? "#a6e3a1" : dbg === "error" ? "#f38ba8" : dbg === "running" ? ThemeBackend.mauve : dbg === "paused" ? "#f9e2af" : "transparent"
    readonly property bool dbgLit: dbg === "ok" || dbg === "error" || dbg === "running" || dbg === "paused"

    readonly property bool bad: !!node.unknown || (node.err || 0) > 0
    readonly property bool warn: !bad && (node.warn || 0) > 0
    x: node.x + dx; y: node.y + dy; width: node.w; height: node.h
    radius: 10
    color: Qt.alpha(ThemeBackend.mantle, 0.97)
    opacity: dbg === "skipped" ? 0.55 : 1
    border.width: selected || bad || dbgLit ? 2 : 1
    border.color: bad ? "#f38ba8" : dbgLit && !selected ? Qt.alpha(dbgColor, 0.9) : selected ? ThemeBackend.mauve : warn ? Qt.alpha("#f9e2af", 0.7) : hovered ? Qt.alpha(ThemeBackend.text, 0.34) : Qt.alpha(ThemeBackend.text, 0.16)

    Rectangle {   // selection / error glow
        z: -1
        visible: nc.selected || nc.bad || nc.dbg === "running" || nc.dbg === "paused" || nc.dbg === "error"
        anchors.fill: parent; anchors.margins: -5
        radius: 14
        color: "transparent"
        border.width: 4
        border.color: Qt.alpha(nc.bad ? "#f38ba8" : nc.dbgLit ? nc.dbgColor : ThemeBackend.mauve, 0.22)
    }

    // whole card: select, drag (editor) / tap, hover (viewer)
    MouseArea {
        id: cardMa
        enabled: nc.editable
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        property real px: 0
        property real py: 0
        property bool moved: false
        onPressed: (m) => { const p = mapToItem(null, m.x, m.y); px = p.x; py = p.y; moved = false; nc.pressedAt(nc.node.id, (m.modifiers & Qt.ShiftModifier) !== 0); }
        onPositionChanged: (m) => {
            if (!pressed) return;
            const p = mapToItem(null, m.x, m.y), ddx = p.x - px, ddy = p.y - py;
            if (!moved && Math.abs(ddx) + Math.abs(ddy) < 4) return;
            moved = true;
            nc.dragBy(ddx, ddy);
        }
        onReleased: nc.dragEnded(moved)
        onContainsMouseChanged: nc.hoverChanged(nc.node.id, containsMouse)
        cursorShape: pressed && moved ? Qt.ClosedHandCursor : Qt.ArrowCursor
    }

    Item {
        id: head
        x: 0; y: 0; width: parent.width; height: CK.hdr
        readonly property color cat: CK.cc(nc.node.cat)
        readonly property color hc: Qt.tint(ThemeBackend.mantle, Qt.alpha(cat, 0.22))
        Rectangle { anchors.fill: parent; radius: 10; color: head.hc }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 10; color: head.hc }
        Rectangle { x: 0; y: 0; width: 4; height: parent.height; radius: 2; color: head.cat }
        CT { x: 14; y: 8; icon: true; text: CK.glyph(nc.node.icon); size: 15; c: head.cat }
        CT { x: 36; y: 8; width: parent.width - (nc.node.deferred ? 96 : 70); text: nc.node.title; size: 12; font.bold: true }
        CmdChip { visible: !!nc.node.deferred; x: parent.width - width - 10; y: 7; text: XI18n.t("cmd.node.deferred", undefined, "позже"); tone: "#f9e2af" }
        Rectangle {
            visible: nc.bad
            x: parent.width - 26; y: 8; width: 16; height: 16; radius: 8; color: "#f38ba8"
            CT { anchors.centerIn: parent; icon: true; size: 11; c: ThemeBackend.crust; text: "\u{f0026}" }
        }
        Rectangle {   // run state badge (debug overlay): running / ok / error / paused / skipped
            id: dbgBadge
            visible: nc.dbg !== "" && !nc.bad
            x: parent.width - 28; y: 6; width: 20; height: 20; radius: 10
            color: nc.dbg === "skipped" ? ThemeBackend.surface1 : nc.dbgColor
            CT { anchors.centerIn: parent; icon: true; size: 12; c: ThemeBackend.crust
                 text: nc.dbg === "ok" ? "\u{f012c}" : nc.dbg === "error" ? "\u{f0026}" : nc.dbg === "running" ? "\u{f040a}" : nc.dbg === "paused" ? "\u{f03e4}" : "\u{f0374}" }
        }
        Rectangle {   // breakpoint dot in the gutter left of the header (click toggles; faint hint on hover)
            visible: nc.bpOk && (nc.hasBp || nc.hovered)
            x: -16; y: 11; width: 10; height: 10; radius: 5
            color: nc.hasBp ? "#f38ba8" : Qt.alpha("#f38ba8", 0.3)
        }
        MouseArea {
            enabled: nc.bpOk
            x: -22; y: 0; width: 22; height: parent.height
            cursorShape: Qt.PointingHandCursor
            onClicked: nc.bpToggled(nc.node.id)
        }
    }

    Repeater {
        model: nc.node.ins
        delegate: Item {
            id: inRow
            y: CK.hdr + CK.padTop + index * CK.row; height: CK.row; width: nc.width
            readonly property int mode: nc.pinMode["i:" + modelData.id] || 0
            readonly property bool editableValue: nc.editable && modelData.linked !== true && modelData.full !== "exec"
            PinDot { x: -6; y: 7; kind: modelData.t; filled: modelData.linked === true; bad: modelData.missing === true || modelData.bad === true
                     lit: inRow.mode > 0; dim: inRow.mode < 0 }
            CT { id: lbl; x: 14; y: 5; text: modelData.n; size: 11; c: modelData.missing || modelData.bad ? "#f38ba8" : ThemeBackend.subtext1 }
            Rectangle {
                id: chip
                visible: modelData.v !== undefined && modelData.linked !== true
                x: 14 + lbl.implicitWidth + 8; y: 3; height: 20
                width: Math.min(nc.width - x - 14, Math.max(34, vt.implicitWidth + 14)); radius: 6
                color: ThemeBackend.surface0
                border.width: 1
                border.color: Qt.alpha(CK.tc(modelData.t), 0.45)
                CT { id: vt; anchors.centerIn: parent; width: parent.width - 10; horizontalAlignment: Text.AlignHCenter
                     text: modelData.v === undefined ? "" : modelData.v; size: 11; c: CK.tc(modelData.t) }
            }
            MouseArea {   // click the label / value to edit the literal
                enabled: inRow.editableValue
                x: 14; y: 0; height: CK.row; width: Math.max(0, (chip.visible ? chip.x + chip.width : lbl.x + lbl.implicitWidth) - 14)
                cursorShape: Qt.PointingHandCursor
                onClicked: nc.valueClicked(nc.node.id, modelData.id, chip.visible ? chip : lbl)
            }
            MouseArea {   // start a wire from this input (a wired input picks its wire up)
                enabled: nc.editable
                x: -16; y: 0; width: 30; height: CK.row
                hoverEnabled: true
                cursorShape: Qt.CrossCursor
                onPressed: (m) => { nc.pinPressed(nc.node.id, modelData.id, false, modelData.t); }
                onPositionChanged: (m) => { if (pressed) { const p = mapToItem(null, m.x, m.y); nc.pinMoved(p.x, p.y); } }
                onReleased: (m) => { const p = mapToItem(null, m.x, m.y); nc.pinReleased(p.x, p.y); }
                onContainsMouseChanged: nc.pinHovered(nc.node.id, modelData.id, containsMouse)
            }
        }
    }
    Repeater {
        model: nc.node.outs
        delegate: Item {
            id: outRow
            y: CK.hdr + CK.padTop + index * CK.row; height: CK.row; width: nc.width
            readonly property int mode: nc.pinMode["o:" + modelData.id] || 0
            CT { x: 0; y: 5; width: parent.width - 16; horizontalAlignment: Text.AlignRight; text: modelData.n; size: 11; c: ThemeBackend.subtext1 }
            PinDot { x: parent.width - 6; y: 7; kind: modelData.t; filled: modelData.linked === true; lit: outRow.mode > 0; dim: outRow.mode < 0 }
            MouseArea {
                enabled: nc.editable
                x: parent.width - 14; y: 0; width: 30; height: CK.row
                hoverEnabled: true
                cursorShape: Qt.CrossCursor
                onPressed: (m) => { nc.pinPressed(nc.node.id, modelData.id, true, modelData.t); }
                onPositionChanged: (m) => { if (pressed) { const p = mapToItem(null, m.x, m.y); nc.pinMoved(p.x, p.y); } }
                onReleased: (m) => { const p = mapToItem(null, m.x, m.y); nc.pinReleased(p.x, p.y); }
                onContainsMouseChanged: nc.pinHovered(nc.node.id, modelData.id, containsMouse)
            }
        }
    }
    CT {
        id: noteText
        visible: nc.node.note !== undefined && nc.node.note !== ""
        x: 14; y: parent.height - 22; width: parent.width - 28
        text: (nc.node.cat === "function" ? "" : "\u{f0709}  ") + (nc.node.note || ""); size: 10
        c: nc.node.cat === "function" ? CK.cc("function") : ThemeBackend.subtext0
    }
    MouseArea {   // «функция · N узлов · открыть ↗»: open the function graph in the same canvas
        enabled: nc.node.cat === "function"
        x: 0; y: parent.height - 26; width: parent.width; height: 26
        cursorShape: Qt.PointingHandCursor
        onClicked: XCmd.openFunctionOfType(nc.node.type)
    }

    HoverHandler { id: hh; enabled: !nc.editable; onHoveredChanged: nc.hoverChanged(nc.node.id, hovered) }
    TapHandler { enabled: !nc.editable; onTapped: nc.tapped(nc.node.id) }
}
