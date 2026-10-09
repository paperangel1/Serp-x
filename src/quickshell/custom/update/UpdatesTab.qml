import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../../"
import "../../reusables"
import ".."

// «Обновления» tab: version card, safety verdict (dry-run merge), changelog of the latest
// update, backups, previous versions, and the progress / result of a running update.
Item {
    id: updatesTabRoot
    objectName: "updatesTab"
    required property var rootObj
    required property int tabIndex

    anchors.fill: parent
    visible: rootObj.currentTab === tabIndex
    opacity: visible ? 1.0 : 0.0
    property real slideY: visible ? 0 : rootObj.s(10)

    Behavior on slideY { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
    transform: Translate { y: slideY }
    Behavior on opacity { NumberAnimation { duration: 250 } }

    property string view: "main"            // main | versions
    property bool showOriginal: false
    property bool changelogExpanded: false
    property real nowMs: Date.now()

    Timer { interval: 30000; running: updatesTabRoot.visible; repeat: true; onTriggered: updatesTabRoot.nowMs = Date.now() }

    onVisibleChanged: {
        if (!visible) return;
        nowMs = Date.now();
        XUpdate.loadBackups();
        XInstaller.probe();
        XUpdate.loadLatestChangelog();
        if (!XUpdate.checking && !XUpdate.running && Date.now() - XUpdate.lastCheckMs > 10 * 60 * 1000) XUpdate.check();
    }

    // ---- derived texts -------------------------------------------------------------------

    readonly property var info: XUpdate.info || ({})
    readonly property bool busyRun: XUpdate.running || XUpdate.resultPending
    readonly property string installedV: info.installedVersion || info.headVersion || ""
    readonly property bool commitsOnly: info.targetVersion !== undefined && info.targetVersion === info.headVersion
    readonly property string serverText: {
        if (!XUpdate.hasUpdate) return "";
        let label = XUpdate.updateLabel;
        return commitsOnly ? XI18n.t("update.label_fixes", { label: label }, label + " fixes") : label;
    }
    readonly property bool repoProblem: info.status === "ok" && (info.branchOk === false || info.clean === false)
    readonly property bool canUpdate: XUpdate.hasUpdate && !XUpdate.checking && info.status === "ok"
        && info.branchOk !== false && info.clean !== false && (XUpdate.dryClean || XUpdate.dryHookOnly)

    function agoText() {
        if (XUpdate.checking) return XI18n.t("update.checking", undefined, "Checking for updates…");
        if (XUpdate.lastCheckMs <= 0) return XI18n.t("update.never_checked", undefined, "Not checked yet");
        let m = Math.floor((nowMs - XUpdate.lastCheckMs) / 60000);
        let when = m < 1 ? XI18n.t("update.just_now", undefined, "just now") : XI18n.t("update.min_ago", { n: m }, m + " min ago");
        return XI18n.t("update.checked", { when: when, branch: info.branch || "" }, "Checked " + when + " · branch " + (info.branch || ""));
    }

    function backupDate(b) {
        let m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(b.ts || "");
        if (!m) return b.name;
        let d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
        let p2 = (n) => (n < 10 ? "0" : "") + n;
        return p2(d.getDate()) + "." + p2(d.getMonth() + 1) + "  " + p2(d.getHours()) + ":" + p2(d.getMinutes());
    }

    // ---- page ------------------------------------------------------------------------------

    Flickable {
        anchors.fill: parent
        anchors.margins: rootObj.s(8)
        contentHeight: pageCol.implicitHeight + rootObj.s(8)
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: pageCol
            width: parent.width
            spacing: rootObj.s(10)

            // ---------- progress / result ----------
            ProgressView {
                Layout.fillWidth: true
                visible: updatesTabRoot.busyRun
                rootObj: updatesTabRoot.rootObj
                onShowChangelog: { XUpdate.ackResult(); updatesTabRoot.changelogExpanded = false; }
                onDismissed: XUpdate.ackResult()
            }

            // ---------- main view ----------
            ColumnLayout {
                Layout.fillWidth: true
                visible: !updatesTabRoot.busyRun && updatesTabRoot.view === "main"
                spacing: rootObj.s(10)

                // version card
                SettingsRow {
                    rootObj: updatesTabRoot.rootObj
                    icon: XUpdate.checking ? "󰑐" : (XUpdate.checkFailed ? "󰀦" : (XUpdate.hasUpdate ? "󰚰" : "󰄬"))
                    iconSize: 56
                    iconFontSize: XUi.s(24)
                    iconCornerRadius: ThemeBackend.borderRadius + 2
                    iconAccentColor: XUpdate.hasUpdate ? ThemeBackend.mauve : ThemeBackend.surface0
                    iconTextColor: XUpdate.hasUpdate ? ThemeBackend.crust : "#ffffff"
                    verticalPadding: rootObj.s(14)
                    customLeftContent: Component {
                        ColumnLayout {
                            spacing: rootObj.s(3)
                            Text {
                                Layout.fillWidth: true
                                text: XUpdate.checking ? XI18n.t("update.checking", undefined, "Checking for updates…")
                                    : (updatesTabRoot.info.status === "error" && XUpdate.checkFailed
                                        ? XI18n.t("update.check_failed", undefined, "Could not check for updates")
                                        : (XUpdate.hasUpdate ? XI18n.t("update.available", undefined, "Update available")
                                                             : XI18n.t("update.uptodate", undefined, "You have the latest version")))
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fTitle; font.bold: true
                                color: ThemeBackend.text
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: XUpdate.hasUpdate
                                    ? XI18n.t("update.installed_to_server", { v: updatesTabRoot.installedV, s: updatesTabRoot.serverText, c: updatesTabRoot.info.targetCommit || "" }, "Installed " + updatesTabRoot.installedV + "  →  on the server " + updatesTabRoot.serverText + " (" + (updatesTabRoot.info.targetCommit || "") + ")")
                                    : (updatesTabRoot.info.status === "error" && XUpdate.checkFailed
                                        ? XI18n.t("update.err." + (updatesTabRoot.info.error || "fetch_failed"), undefined, updatesTabRoot.info.error || "")
                                        : XI18n.t("update.installed", { v: updatesTabRoot.installedV }, "Installed " + updatesTabRoot.installedV))
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow
                                color: ThemeBackend.subtext0
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: updatesTabRoot.agoText()
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                                color: ThemeBackend.overlay1
                                elide: Text.ElideRight
                            }
                        }
                    }

                    IconButton {
                        size: rootObj.s(44)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰑐"
                        iconFontSize: XUi.fHead
                        accentColor: ThemeBackend.surface0
                        textColor: ThemeBackend.text
                        enabled: !XUpdate.checking
                        Layout.alignment: Qt.AlignVCenter
                        onClicked: XUpdate.check()
                    }
                    FillButton {
                        visible: XUpdate.hasUpdate
                        enabled: updatesTabRoot.canUpdate
                        Layout.preferredWidth: rootObj.s(210)
                        Layout.preferredHeight: rootObj.s(44)
                        Layout.alignment: Qt.AlignVCenter
                        cornerRadius: ThemeBackend.borderRadius
                        buttonText: XI18n.t("update.btn_update", undefined, "Update")
                        subText: XI18n.t("update.btn_hold", undefined, "hold for 1 second")
                        buttonIcon: "󰚰"
                        iconFontSize: XUi.fTitle
                        textFontSize: XUi.fRow
                        horizontalPadding: rootObj.s(16)
                        accentColor: ThemeBackend.mauve
                        baseColor: Qt.alpha(ThemeBackend.surface1, 0.6)
                        hoverColor: Qt.alpha(ThemeBackend.surface2, 0.6)
                        textColor: ThemeBackend.text
                        filledTextColor: ThemeBackend.crust
                        fillDuration: 1000
                        onTriggered: XUpdate.startUpdate(updatesTabRoot.info.drift === true)
                    }
                }

                // safety verdict (dry-run merge)
                SettingsRow {
                    id: safetyRow
                    rootObj: updatesTabRoot.rootObj
                    visible: XUpdate.hasUpdate && !XUpdate.checking
                    readonly property string verdict: updatesTabRoot.repoProblem ? "repo"
                        : (XUpdate.dryClean ? (updatesTabRoot.info.drift === true ? "drift" : "clean")
                        : (XUpdate.dryHookOnly ? "hook" : "conflict"))
                    icon: verdict === "clean" ? "󰒃" : "󰀦"
                    iconAccentColor: verdict === "clean" ? ThemeBackend.surface0
                        : (verdict === "conflict" || verdict === "repo" ? Qt.alpha(ThemeBackend.red, 0.35) : Qt.alpha(ThemeBackend.peach, 0.35))
                    iconTextColor: verdict === "clean" ? "#ffffff" : (verdict === "conflict" || verdict === "repo" ? ThemeBackend.red : ThemeBackend.peach)
                    borderColor: verdict === "conflict" || verdict === "repo" ? Qt.alpha(ThemeBackend.red, 0.4) : "transparent"
                    borderWidth: borderColor.a > 0 ? 1 : 0
                    titleBold: true
                    innerSpacing: (verdict === "clean" || verdict === "drift" || verdict === "hook") ? rootObj.s(12) : 0
                    title: verdict === "clean" ? XI18n.t("update.safe_clean", undefined, "Safe: no conflicts with your changes")
                        : verdict === "drift" ? XI18n.t("update.safe_drift", undefined, "Installed files were edited by hand")
                        : verdict === "hook" ? XI18n.t("update.safe_hook", undefined, "The tab hooks will be re-applied automatically")
                        : verdict === "repo" ? XI18n.t("update.safe_repo", undefined, "The repository is not ready for an update")
                        : XI18n.t("update.safe_conflict", { files: XUpdate.dryFiles.join(", ") }, "Manual fix needed: " + XUpdate.dryFiles.join(", "))
                    description: verdict === "clean" ? XI18n.t("update.safe_clean_desc", undefined, "A backup is made before installing; if the shell fails to start, everything rolls back by itself.")
                        : verdict === "drift" ? XI18n.t("update.safe_drift_desc", undefined, "Installing will overwrite them with the repository version. A backup is made first.")
                        : verdict === "hook" ? XI18n.t("update.safe_hook_desc", undefined, "The conflict is only in the lines that attach the new tabs; they are restored by anchors.")
                        : verdict === "repo" ? XI18n.t("update.safe_repo_desc", { branch: updatesTabRoot.info.branch || "" }, "Switch to branch " + (updatesTabRoot.info.branch || "") + " and commit or stash local changes.")
                        : XI18n.t("update.safe_conflict_desc", undefined, "The update will not be installed until the conflict is resolved. Nothing was changed.")
                    bottomContent: [
                        Flow {
                            id: keepChips
                            Layout.fillWidth: true
                            Layout.maximumHeight: visible ? 100000 : 0
                            spacing: rootObj.s(6)
                            visible: safetyRow.verdict === "clean" || safetyRow.verdict === "drift" || safetyRow.verdict === "hook"
                            Text {
                                text: XI18n.t("update.preserved", undefined, "Will be kept:")
                                height: rootObj.s(24)
                                verticalAlignment: Text.AlignVCenter
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay1
                            }
                            Repeater {
                                model: [
                                    XI18n.t("update.keep_hotkeys_tab", undefined, "«Hotkeys» tab"),
                                    XI18n.t("update.keep_updates_tab", undefined, "«Updates» tab"),
                                    XI18n.t("update.keep_hotkeys_data", undefined, "Your hotkeys (settings.json)"),
                                    "user_keybinds.lua"
                                ]
                                delegate: Rectangle {
                                    required property string modelData
                                    height: rootObj.s(24)
                                    width: chipText.implicitWidth + rootObj.s(16)
                                    radius: rootObj.s(6)
                                    color: Qt.alpha(ThemeBackend.surface1, 0.55)
                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        text: modelData
                                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption
                                        color: ThemeBackend.text
                                    }
                                }
                            }
                        }
                    ]
                }

                // changelog of the latest update
                XCard {
                    id: clCard
                    rootObj: updatesTabRoot.rootObj
                    visible: XUpdate.latestChangelog !== null && XUpdate.latestChangelog.status === "ok"
                    readonly property var d: XUpdate.latestChangelog

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: rootObj.s(10)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: rootObj.s(2)
                            Text {
                                text: XUpdate.hasUpdate ? XI18n.t("update.whats_new_in", { v: updatesTabRoot.serverText }, "What's new in " + updatesTabRoot.serverText)
                                                        : XI18n.t("update.latest_version_changes", { v: (clCard.d ? clCard.d.version : "") }, "Changes in the latest version")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.bold: true
                                color: ThemeBackend.text
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Text {
                                text: XI18n.t("update.only_latest", undefined, "only the latest update")
                                font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.subtext0
                            }
                        }
                        Rectangle {
                            visible: clCard.d && clCard.d.translated === true
                            Layout.alignment: Qt.AlignVCenter
                            height: rootObj.s(22)
                            width: badgeRow.implicitWidth + rootObj.s(16)
                            radius: height / 2
                            color: Qt.alpha(ThemeBackend.mauve, 0.18)
                            RowLayout {
                                id: badgeRow
                                anchors.centerIn: parent
                                spacing: rootObj.s(5)
                                Text { text: "󰗊"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fBody; color: ThemeBackend.mauve }
                                Text { text: XI18n.t("update.badge_gemini", undefined, "Translation: Gemini"); font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.mauve }
                            }
                        }
                        Text {
                            visible: clCard.d && clCard.d.lang !== "en" && clCard.d.translated !== true
                            Layout.alignment: Qt.AlignVCenter
                            text: XI18n.t("update.src_unavailable", undefined, "translation unavailable — original shown")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay1
                        }
                        Text {
                            visible: clCard.d && clCard.d.lang !== "en" && clCard.d.translated === true
                            Layout.alignment: Qt.AlignVCenter
                            text: XI18n.t("update.original", undefined, "Original")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.subtext0
                        }
                        Toggle {
                            visible: clCard.d && clCard.d.lang !== "en" && clCard.d.translated === true
                            Layout.alignment: Qt.AlignVCenter
                            checked: updatesTabRoot.showOriginal
                            accentColor: ThemeBackend.mauve
                            baseColor: ThemeBackend.surface1
                            handleColor: ThemeBackend.crust
                            handleOffColor: ThemeBackend.text
                            onToggled: function(c) { updatesTabRoot.showOriginal = c; }
                        }
                    }

                    ChangelogView {
                        Layout.fillWidth: true
                        rootObj: updatesTabRoot.rootObj
                        changelog: XUpdate.latestChangelog
                        showOriginal: updatesTabRoot.showOriginal
                        maxItems: updatesTabRoot.changelogExpanded ? 0 : 7
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        visible: XUpdate.latestChangelog && XUpdate.latestChangelog.count > 7
                        Text {
                            Layout.fillWidth: true
                            text: updatesTabRoot.changelogExpanded ? "" : XI18n.t("update.more_changes", { n: XUpdate.latestChangelog ? XUpdate.latestChangelog.count - 7 : 0 }, "…and " + (XUpdate.latestChangelog ? XUpdate.latestChangelog.count - 7 : 0) + " more changes")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.overlay1
                        }
                        ClickButton {
                            buttonText: updatesTabRoot.changelogExpanded ? XI18n.t("update.show_less", undefined, "Collapse") : XI18n.t("update.show_all", undefined, "Show all")
                            buttonIcon: updatesTabRoot.changelogExpanded ? "󰅃" : "󰅀"
                            Layout.preferredHeight: rootObj.s(32)
                            cornerRadius: ThemeBackend.borderRadius
                            textFontSize: XUi.fBody
                            onClicked: updatesTabRoot.changelogExpanded = !updatesTabRoot.changelogExpanded
                        }
                    }
                }

                // backups
                XCard {
                    rootObj: updatesTabRoot.rootObj
                    visible: XUpdate.backups.length > 0

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: rootObj.s(8)
                        Text { text: "󰋚"; font.family: ThemeBackend.iconFont; font.pixelSize: XUi.fSub; color: ThemeBackend.text }
                        Text {
                            text: XI18n.t("update.backups_title", undefined, "Backups")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fSub; font.bold: true; color: ThemeBackend.text
                            Layout.fillWidth: true
                        }
                        Text {
                            text: XI18n.t("update.backups_keep", undefined, "the last 5 are kept")
                            font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay1
                        }
                    }
                    Repeater {
                        model: XUpdate.backups
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: rootObj.s(44)
                            radius: ThemeBackend.borderRadius
                            color: Qt.alpha(ThemeBackend.surface0, 0.55)
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: rootObj.s(12)
                                anchors.rightMargin: rootObj.s(8)
                                spacing: rootObj.s(12)
                                Text {
                                    text: updatesTabRoot.backupDate(modelData)
                                    Layout.preferredWidth: rootObj.s(104)
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fRow; font.bold: true; color: ThemeBackend.text
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.from !== "" ? (modelData.from + "  →  " + modelData.to) : ""
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fBody; color: ThemeBackend.subtext0
                                    elide: Text.ElideRight
                                }
                                ClickButton {
                                    buttonText: XI18n.t("update.restore", undefined, "Roll back")
                                    buttonIcon: "󰁯"
                                    Layout.preferredHeight: rootObj.s(30)
                                    cornerRadius: ThemeBackend.borderRadius
                                    textFontSize: XUi.fBody
                                    iconFontSize: XUi.fRow
                                    enabled: XUpdate.restoringName === ""
                                    onClicked: XUpdate.restore(modelData.name)
                                }
                            }
                        }
                    }
                }

                // installer buttons: only when the installer binary exists on this machine
                RowLayout {
                    Layout.fillWidth: true
                    visible: XInstaller.available
                    spacing: rootObj.s(8)
                    ClickButton {
                        buttonText: XI18n.t("update.modules_btn", undefined, "Change modules")
                        buttonIcon: "󰏗"
                        Layout.preferredHeight: rootObj.s(38)
                        cornerRadius: ThemeBackend.borderRadius
                        textFontSize: XUi.fRow
                        enabled: XInstaller.available
                        onClicked: XInstaller.openModules()
                    }
                    ClickButton {
                        buttonText: XI18n.t("update.backup_btn", undefined, "Backup")
                        buttonIcon: "󰁯"
                        Layout.preferredHeight: rootObj.s(38)
                        cornerRadius: ThemeBackend.borderRadius
                        textFontSize: XUi.fRow
                        enabled: XInstaller.available
                        onClicked: XInstaller.exportBackup()
                    }
                    Item { Layout.fillWidth: true }
                }

                // footer
                RowLayout {
                    Layout.fillWidth: true
                    ClickButton {
                        buttonText: XI18n.t("update.older_btn", undefined, "Previous versions")
                        buttonIcon: "󰋚"
                        Layout.preferredHeight: rootObj.s(38)
                        cornerRadius: ThemeBackend.borderRadius
                        textFontSize: XUi.fRow
                        onClicked: updatesTabRoot.view = "versions"
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: XI18n.t("update.autocheck", undefined, "Auto-check: every 6 hours")
                        font.family: ThemeBackend.fontFamily; font.pixelSize: XUi.fCaption; color: ThemeBackend.overlay1
                    }
                }
            }

            // ---------- previous versions ----------
            Loader {
                Layout.fillWidth: true
                active: !updatesTabRoot.busyRun && updatesTabRoot.view === "versions"
                visible: active
                sourceComponent: VersionPicker {
                    rootObj: updatesTabRoot.rootObj
                    onBack: updatesTabRoot.view = "main"
                }
            }
        }
    }
}
