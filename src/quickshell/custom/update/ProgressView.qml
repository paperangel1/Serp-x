import QtQuick
import QtQuick.Layouts
import "../../"
import "../../reusables"
import ".."

// Progress of a running update and its result (success / rolled back).
ColumnLayout {
    id: pv
    required property var rootObj
    signal showChangelog()
    signal dismissed()

    spacing: rootObj.s(10)

    // backend phase -> index of the visible step
    readonly property var steps: [
        { phases: ["preflight"], key: "step_preflight", fb: "Repository check", hintKey: "hint_preflight", hint: "clean working tree, correct branch" },
        { phases: ["fetching"], key: "step_fetch", fb: "Downloading changes", hintKey: "hint_fetch", hint: "git fetch" },
        { phases: ["dryrun", "merging"], key: "step_merge", fb: "Merging with your changes", hintKey: "hint_merge", hint: "merge, never rebase" },
        { phases: ["validating", "hookcheck"], key: "step_validate", fb: "Checking files", hintKey: "hint_validate", hint: "qmllint · JSON · shell" },
        { phases: ["backup"], key: "step_backup", fb: "Backup", hintKey: "hint_backup", hint: "serpantinum-backups" },
        { phases: ["syncing", "state"], key: "step_sync", fb: "Installing files", hintKey: "hint_sync", hint: "copying to the install directory" },
        { phases: ["restarting"], key: "step_restart", fb: "Restarting the shell", hintKey: "hint_restart", hint: "the panel disappears for 2-3 seconds" },
        { phases: ["healthcheck", "rolling_back"], key: "step_health", fb: "Health check", hintKey: "hint_health", hint: "rolls back automatically if it fails" }
    ]
    readonly property int currentStep: {
        let ph = XUpdate.phase;
        for (let i = 0; i < steps.length; i++) if (steps[i].phases.indexOf(ph) >= 0) return i;
        return XUpdate.resultOk ? steps.length : 0;
    }
    readonly property int failedStep: XUpdate.resultError ? currentStep : -1

    function errorText() {
        let code = XUpdate.status.code || "";
        let detail = XUpdate.status.detail || "";
        if (code === "merge_conflict") {
            let files = "";
            try { files = JSON.parse(detail).join(", "); } catch (e) { XLog.warn("update", "ProgressView.qml: could not parse JSON output (files)"); files = detail; }
            return XI18n.t("update.err.merge_conflict", { files: files }, "Conflict with your changes in: " + files + ". Nothing was changed.");
        }
        return XI18n.t("update.err." + code, { detail: detail }, code + (detail !== "" ? ": " + detail : ""));
    }

    // ---- progress card ----
    XCard {
        rootObj: pv.rootObj
        visible: XUpdate.running || XUpdate.resultPending
        contentSpacing: pv.rootObj.s(10)

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: XI18n.t("update.progress_title", undefined, "Installing update")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fTitle; font.bold: true
                color: ThemeBackend.text
                Layout.fillWidth: true
            }
            Text {
                text: (XUpdate.status.from || XUpdate.info.installedVersion || "") + "  →  " + XUpdate.targetLabel
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody
                color: ThemeBackend.subtext0
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: pv.rootObj.s(8)
            radius: height / 2
            color: ThemeBackend.surface1
            Rectangle {
                height: parent.height
                radius: height / 2
                width: parent.width * Math.max(0, Math.min(100, XUpdate.resultOk ? 100 : XUpdate.pct)) / 100
                color: pv.failedStep >= 0 ? ThemeBackend.red : ThemeBackend.mauve
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutQuint } }
                Behavior on color { ColorAnimation { duration: 200 } }
            }
        }

        Repeater {
            model: pv.steps
            delegate: RowLayout {
                required property int index
                required property var modelData
                readonly property bool done: index < pv.currentStep || XUpdate.resultOk
                readonly property bool active: index === pv.currentStep && XUpdate.running
                readonly property bool failed: index === pv.failedStep
                Layout.fillWidth: true
                Layout.preferredHeight: pv.rootObj.s(30)
                spacing: pv.rootObj.s(12)

                Rectangle {
                    Layout.preferredWidth: pv.rootObj.s(24)
                    Layout.preferredHeight: pv.rootObj.s(24)
                    Layout.alignment: Qt.AlignVCenter
                    radius: width / 2
                    color: failed ? ThemeBackend.red : (active ? ThemeBackend.mauve : (done ? ThemeBackend.surface1 : "transparent"))
                    border.width: (!done && !active && !failed) ? 1 : 0
                    border.color: ThemeBackend.surface1
                    Text {
                        anchors.centerIn: parent
                        visible: !active
                        text: failed ? "󰅖" : (done ? "󰄬" : "")
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: XUi.fRow
                        color: failed ? ThemeBackend.crust : ThemeBackend.text
                    }
                    Text {
                        id: spinner
                        anchors.centerIn: parent
                        visible: active
                        text: "󰑐"
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: XUi.fRow
                        color: ThemeBackend.crust
                        RotationAnimator on rotation {
                            running: active
                            from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                        }
                    }
                }
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: pv.rootObj.s(250)
                    elide: Text.ElideRight
                    text: XI18n.t("update." + modelData.key, undefined, modelData.fb)
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow
                    font.bold: active
                    color: (done || active || failed) ? ThemeBackend.text : ThemeBackend.overlay1
                }
                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: XI18n.t("update." + modelData.hintKey, undefined, modelData.hint)
                    elide: Text.ElideRight
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                    color: ThemeBackend.overlay1
                }
            }
        }

        RowLayout {
            visible: XUpdate.running
            spacing: pv.rootObj.s(8)
            Text { text: "󰀦"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fRow; color: ThemeBackend.peach }
            Text {
                text: XI18n.t("update.dont_poweroff", undefined, "Do not turn off the computer until it finishes")
                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.peach
            }
        }
    }

    // ---- result: success ----
    XCard {
        rootObj: pv.rootObj
        visible: XUpdate.resultOk
        borderColor: Qt.alpha(ThemeBackend.mauve, 0.5)
        RowLayout {
            Layout.fillWidth: true
            spacing: pv.rootObj.s(14)
            Rectangle {
                Layout.preferredWidth: pv.rootObj.s(40); Layout.preferredHeight: pv.rootObj.s(40)
                radius: width / 2; color: ThemeBackend.mauve
                Text { anchors.centerIn: parent; text: "󰄬"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.crust }
            }
            ColumnLayout {
                spacing: pv.rootObj.s(2)
                Text {
                    text: XI18n.t("update.done_title", { label: XUpdate.targetLabel }, "Done: updated to " + XUpdate.targetLabel)
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.bold: true; color: ThemeBackend.text
                }
                Text {
                    text: XI18n.t("update.done_desc", undefined, "The shell was restarted · your changes are in place")
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.subtext0
                }
            }
            Item { Layout.fillWidth: true }
            ClickButton {
                buttonText: XI18n.t("update.whats_new", undefined, "What's new")
                Layout.preferredHeight: pv.rootObj.s(34)
                cornerRadius: ThemeBackend.borderRadius
                textFontSize: XUi.fRow
                onClicked: pv.showChangelog()
            }
            ClickButton {
                buttonText: XI18n.t("update.close", undefined, "Close")
                Layout.preferredHeight: pv.rootObj.s(34)
                cornerRadius: ThemeBackend.borderRadius
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.crust
                textFontSize: XUi.fRow
                onClicked: pv.dismissed()
            }
        }
    }

    // ---- result: error / rollback ----
    XCard {
        rootObj: pv.rootObj
        visible: XUpdate.resultError
        borderColor: Qt.alpha(ThemeBackend.red, 0.5)
        RowLayout {
            Layout.fillWidth: true
            spacing: pv.rootObj.s(14)
            Rectangle {
                Layout.preferredWidth: pv.rootObj.s(40); Layout.preferredHeight: pv.rootObj.s(40)
                radius: width / 2; color: ThemeBackend.red
                Text { anchors.centerIn: parent; text: "󰕍"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fHead; color: ThemeBackend.crust }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: pv.rootObj.s(2)
                Text {
                    Layout.fillWidth: true
                    text: XUpdate.status.code === "health_failed"
                        ? XI18n.t("update.err_title_rollback", undefined, "The shell did not start — automatic rollback done")
                        : XI18n.t("update.err_title", undefined, "Update was not installed")
                    wrapMode: Text.WordWrap
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.bold: true; color: ThemeBackend.text
                }
                Text {
                    Layout.fillWidth: true
                    text: (XUpdate.status.code === "health_failed"
                        ? XI18n.t("update.err_rollback_desc", { v: XUpdate.status.from || "" }, "You are on the previous version. Nothing was lost.")
                        : pv.errorText())
                    wrapMode: Text.WordWrap
                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.subtext0
                }
            }
            ClickButton {
                buttonText: XI18n.t("update.close", undefined, "Close")
                Layout.preferredHeight: pv.rootObj.s(34)
                cornerRadius: ThemeBackend.borderRadius
                textFontSize: XUi.fRow
                onClicked: pv.dismissed()
            }
            ClickButton {
                buttonText: XI18n.t("update.retry", undefined, "Retry")
                buttonIcon: "󰑐"
                Layout.preferredHeight: pv.rootObj.s(34)
                cornerRadius: ThemeBackend.borderRadius
                accentColor: ThemeBackend.red
                textColor: ThemeBackend.crust
                textFontSize: XUi.fRow
                onClicked: { pv.dismissed(); XUpdate.startUpdate(); }
            }
        }
    }
}
