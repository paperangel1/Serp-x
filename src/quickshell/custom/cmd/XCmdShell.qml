import QtQuick
import "../../"
import ".."

// Shell-side half of the Commands actions that have no IPC of their own upstream (see scripts/custom/cmd/xcmd-ipc.md).
// Only wraps existing upstream singletons (Config, Matugen, ThemeBackend, BlueLight, Wallpaper): no upstream file is edited.
//   do-not-disturb  = the same Config flag `notifications.dnd` the notification panel button writes; NotificationPopups
//                     and Notification.qml already honour it (popups + sound muted, critical urgency still shown,
//                     everything stays in the notification centre). No popup is killed by us.
//   theme           = Config `theme.mode` (+ `theme.schemeType`) and a Matugen regeneration from the current wallpaper.
//   bar             = Config `bar.autohide` (the same switch as `main` IPC «autohide»): "hidden" = the bar slides away and
//                     comes back when the pointer touches its edge; "shown" = always visible.
//   night filter    = BlueLight.setEnabled / setTemperature (persisted by BlueLight itself).
// Every function returns a string; "err:<ru text>" is an error the engine shows to the user.
Item {
    id: shell
    visible: false

    function _cfg(key) {
        let v = Config.getSetting(key, {});
        return (v && typeof v === "object") ? v : {};
    }

    // ---- do not disturb
    function getDnd() {
        return Boolean(_cfg("notifications").dnd);
    }

    function setDnd(on) {
        let n = _cfg("notifications");
        n.dnd = Boolean(on);
        Config.setSetting("notifications", n);
        XLog.info("cmd", "xcmd: do-not-disturb " + (n.dnd ? "on" : "off"));
    }

    // ---- theme: "dark" | "light" | "toggle", optionally ":scheme-<name>"
    function getTheme() {
        let t = _cfg("theme");
        return (t.mode === "light" ? "light" : "dark") + (t.schemeType ? ":" + t.schemeType : "");
    }

    function setTheme(spec) {
        let parts = String(spec).split(":");
        let mode = parts[0];
        let scheme = parts.length > 1 ? parts.slice(1).join(":") : "";
        let t = _cfg("theme");
        if (mode === "toggle") mode = (t.mode === "light") ? "dark" : "light";
        if (mode !== "dark" && mode !== "light") return "err:Неизвестная тема «" + mode + "»";
        if (scheme !== "" && !/^scheme-[a-z-]+$/.test(scheme)) return "err:Неизвестная схема цветов «" + scheme + "»";
        t.mode = mode;
        if (scheme !== "") t.schemeType = scheme;
        Config.setSetting("theme", t);
        let regenerated = false;
        if (Matugen.isMatugenTheme()) {
            let wp = Wallpaper.getWallpaperPath("") || t.wallpaper || Config.getSetting("wallpaper", "");
            if (wp) regenerated = Matugen.generate(wp, mode, t.schemeType || "");
            else ThemeBackend.reloadColors();
        }
        XLog.info("cmd", "xcmd: theme " + mode + (scheme ? " " + scheme : "") + (regenerated ? " (matugen regenerated)" : " (mode saved only)"));
        return "ok";
    }

    // ---- night filter: "on" | "on:<temp>" | "off" | "off:<temp>"
    function getNightFilter() {
        return (BlueLight.isAnyEnabled() ? "on" : "off") + ":" + BlueLight.getSavedTemperature("");
    }

    function setNightFilter(spec) {
        let parts = String(spec).split(":");
        if (parts[0] !== "on" && parts[0] !== "off") return "err:Ночной фильтр: ожидалось on или off";
        if (parts.length > 1 && parts[1] !== "" && !isNaN(Number(parts[1]))) BlueLight.setTemperature(Number(parts[1]));
        BlueLight.setEnabled(parts[0] === "on");
        XLog.info("cmd", "xcmd: night filter " + spec);
        return "ok";
    }

    // ---- bar: "show" | "hide" | "toggle" (state strings: "shown" | "hidden")
    function getBar() {
        return _cfg("bar").autohide ? "hidden" : "shown";
    }

    function setBar(spec) {
        let s = String(spec);
        if (s === "shown") s = "show";
        if (s === "hidden") s = "hide";
        if (s !== "show" && s !== "hide" && s !== "toggle") return "err:Панель: ожидалось show, hide или toggle";
        let b = _cfg("bar");
        b.autohide = (s === "toggle") ? !b.autohide : (s === "hide");
        Config.setSetting("bar", b);
        XLog.info("cmd", "xcmd: bar " + (b.autohide ? "hidden" : "shown"));
        return "ok";
    }
}
