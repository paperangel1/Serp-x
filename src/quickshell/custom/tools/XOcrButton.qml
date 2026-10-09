import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import "../../reusables"
import ".."

// OCR button for the stock screenshot toolbar (hooked in with a single line after the QR button).
// Mirrors the toolbar's own AnimWrap sizing, then: hide the overlay, wait for the compositor to
// repaint, recognise the selected region (x_ocr.sh --json) and report with a toast.
Item {
    id: wrap

    required property var overlay           // ScreenshotOverlay root

    function s(v) { return Scaler.s(v); }

    readonly property bool isShown: !overlay.isVideoMode && XModules.enabled("ocr")   // modules.json
    readonly property real contentWidth: s(36)
    readonly property real rightPadding: s(6)

    width: isShown ? contentWidth + rightPadding : 0
    height: parent ? parent.height : s(36)
    opacity: isShown ? 1.0 : 0.0
    clip: true
    visible: width > 0

    Behavior on width { enabled: overlay.animateChanges && !overlay.isRefreezing; NumberAnimation { duration: 600; easing.type: Easing.OutExpo } }
    Behavior on opacity { enabled: overlay.animateChanges && !overlay.isRefreezing; NumberAnimation { duration: 500; easing.type: Easing.OutExpo } }

    IconButton {
        size: s(36)
        width: s(36); height: s(36)
        cornerRadius: ThemeBackend.borderRadius
        buttonIcon: "󱄽"
        iconFont: "Iosevka Nerd Font"     // the bundled symbols font predates this glyph
        iconFontSize: XUi.fHead
        accentColor: ThemeBackend.surface0
        textColor: ThemeBackend.text
        onClicked: wrap.run()
    }

    property string pendingGeometry: ""

    function run() { XLog.info("tools", "UI: OCR button pressed");
        pendingGeometry = overlay.geometryString;
        overlay.deactivate();
        startTimer.start();
    }

    Timer {
        id: startTimer
        interval: 280
        onTriggered: {
            toast.show(XI18n.t("tools.ocr.working", undefined, "Распознаю текст…"), "", "transparent", "bottom", 1500);
            ocrProc.running = true;
        }
    }

    Process {
        id: ocrProc
        command: ["bash", XToolsConf.scriptsDir + "/x_ocr.sh", "--json", "--geometry", wrap.pendingGeometry]
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try { r = JSON.parse(this.text.trim().split("\n").pop()); } catch (e) { XLog.warn("tools", "XOcrButton.qml: could not parse JSON output (r)");}
                XLog.info("tools", "UI: OCR result status=" + (r ? r.status : "none") + (r && r.chars ? " chars=" + r.chars : ""));
                if (!r) { toast.show(XI18n.t("tools.ocr.failed", undefined, "Не удалось распознать текст"), "", "transparent", "bottom", 3500); return; }
                if (r.status === "ok") toast.show(XI18n.t("tools.ocr.copied", undefined, r.title), XI18n.t("tools.ocr.copied_sub", { n: r.chars }, r.message), "transparent", "bottom", 2800);
                else if (r.status === "empty") toast.show(XI18n.t("tools.ocr.empty", undefined, r.title), XI18n.t("tools.ocr.empty_sub", undefined, r.message), "transparent", "bottom", 3000);
                else toast.show(r.title || XI18n.t("tools.ocr.failed", undefined, "Ошибка"), r.message || "", "transparent", "bottom", 5000);
            }
        }
    }

    ToolToast { id: toast; icon: "󰄬" }
}
