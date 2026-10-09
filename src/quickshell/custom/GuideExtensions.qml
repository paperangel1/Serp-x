import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// The only thing guide/GuidePopup.qml knows about. Appends the serpantinum-x
// tabs AFTER the stock ones (stock indices never shift), creates their sidebar
// items at the end of the sidebar column, and keeps stock helpers working for them.
//
// Pages receive the same `rootObj` / `tabIndex` as stock tabs (Loader.setSource).
Item {
    id: ext
    visible: false

    property var guide: null            // GuidePopup root
    property Item sidebarColumn: null   // ColumnLayout `tabsCol`
    property Flickable sidebarFlickable: null

    property int baseCount: -1          // number of stock tabs
    property var sidebarItems: []
    property bool installed: false

    // `module` = installer module id (modules.json); "core" tabs are always shown. Read once at startup.
    readonly property var allTabs: [
        { id: "Hotkeys", key: "hotkeys", module: "hotkeys", name: "Hotkeys", icon: "󰌌", file: "../custom/hotkeys/HotkeysTab.qml", iconOffsetX: 0 },
        { id: "Updates", key: "updates", module: "core", name: "Updates", icon: "󰚰", file: "../custom/update/UpdatesTab.qml", iconOffsetX: 0 },
        { id: "Tools", key: "tools", module: "tools", name: "Tools", icon: "󰖷", file: "../custom/tools/ToolsTab.qml", iconOffsetX: 0 },
        { id: "Servers", key: "servers", module: "servers", name: "Servers", icon: "󰒋", file: "../custom/servers/ServersTab.qml", iconOffsetX: 0 },
        { id: "Vpn", key: "vpn", module: "vpn", name: "VPN", icon: "󰖂", file: "../custom/vpn/VpnTab.qml", iconOffsetX: 0 }
    ]
    property var extTabs: []

    // Runs while the guide's properties are being bound, i.e. BEFORE the content
    // Repeater instantiates its delegates; extending the model later would rebuild
    // (and double-load) every tab page.
    onGuideChanged: extendModel()

    function extendModel() {
        if (baseCount >= 0 || !guide) return;
        baseCount = guide.tabsModel.length;
        extTabs = allTabs.filter(t => XModules.enabled(t.module));
        guide.tabsModel = guide.tabsModel.concat(extTabs);
    }

    function install() {
        if (installed || !guide || !sidebarColumn) return;
        extendModel();
        installed = true;

        let comp = Qt.createComponent("XSidebarTab.qml");
        if (comp.status !== Component.Ready) {
            XLog.error("ui", "sidebar tab failed to load: " + comp.errorString());
            return;
        }
        let items = [];
        for (let i = 0; i < extTabs.length; i++) {
            let t = extTabs[i];
            let item = comp.createObject(sidebarColumn, {
                guide: guide,
                tabIndex: baseCount + i,
                labelKey: "tabs." + t.key,
                labelFallback: t.name,
                icon: t.icon,
                iconOffsetX: t.iconOffsetX
            });
            if (t.key === "updates") item.showDot = Qt.binding(() => XUpdate.updateAvailable);
            items.push(item);
        }
        sidebarItems = items;
        syncStockTranslations();
        restoreLastTab();
        Qt.callLater(reensure);
    }

    function openUpdates() {
        if (guide) guide.gotoTab("updates");
    }

    // Stock ensureTabVisible() only knows the stock tab items. Our items are the last
    // ones in the column, so while one of them is active scroll to the very bottom:
    // that keeps the active tab AND its sibling fully reachable.
    function ensureVisible(idx) {
        if (!sidebarFlickable || !guide) return;
        let maxScroll = Math.max(0, sidebarFlickable.contentHeight - sidebarFlickable.height);
        if (Math.abs(sidebarFlickable.contentY - maxScroll) > 0.5)
            sidebarFlickable.contentY = maxScroll;
    }

    // The sidebar viewport shrinks/grows when the bottom update button shows/hides and
    // when our items are appended, so re-check after the layout has settled.
    function reensure() {
        if (installed && guide && guide.currentTab >= baseCount) ensureVisible(guide.currentTab);
    }

    Connections {
        target: ext.guide
        enabled: ext.installed
        function onCurrentTabChanged() {
            ext.reensure();
            Qt.callLater(ext.reensure);
        }
    }

    Connections {
        target: ext.sidebarFlickable
        enabled: ext.installed
        function onHeightChanged() { Qt.callLater(ext.reensure); }
        function onContentHeightChanged() { Qt.callLater(ext.reensure); }
    }

    // The stock last_tab restore may run before our tabs exist (index >= baseCount
    // is rejected then), so re-apply it once after installing.
    FileView {
        id: lastTabFile
        path: Caching.getCacheDir("guide") + "/last_tab.txt"
        onLoaded: ext.restoreLastTab()
    }

    function restoreLastTab() {
        if (!installed) return;
        try {
            let val = lastTabFile.text().trim();
            if (val === "") return;
            let idx = parseInt(val.split(":")[0]);
            if (!isNaN(idx) && idx >= baseCount && idx < guide.tabsModel.length && guide.currentTab !== idx)
                guide.gotoTab(String(idx));
        } catch (e) {}
    }

    // Stock search titles tabs via I18n.t("guide.tabs.<key>"); make our keys resolvable
    // by injecting them at runtime (no edits to assets/languages/*.json).
    function syncStockTranslations() {
        if (!installed || !I18n.isReady || !XI18n.isReady) return;
        let tr = Object.assign({}, I18n.translations);
        for (let lang in XI18n.translations) {
            let tabs = XI18n.translations[lang].tabs;
            if (!tabs) continue;
            let l = Object.assign({}, tr[lang] || {});
            l.guide = Object.assign({}, l.guide || {});
            l.guide.tabs = Object.assign({}, l.guide.tabs || {}, tabs);
            tr[lang] = l;
        }
        I18n.translations = tr;
    }

    Connections {
        target: I18n
        function onIsReadyChanged() { ext.syncStockTranslations(); }
    }
    Connections {
        target: XI18n
        function onIsReadyChanged() { ext.syncStockTranslations(); }
    }

    Component.onCompleted: install()
}
