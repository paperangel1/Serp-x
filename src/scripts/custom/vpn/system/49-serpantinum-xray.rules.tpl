// Managed by Serpantinum (x_vpn.sh install).
// Lets exactly one local, active user start/stop/restart exactly the two Serpantinum VPN units.
polkit.addRule(function(action, subject) {
    if (action.id != "org.freedesktop.systemd1.manage-units") return;
    if (subject.user != "@USER@" || !subject.active || !subject.local) return;
    var unit = action.lookup("unit");
    var verb = action.lookup("verb");
    if ((unit == "serp-xray.service" || unit == "serp-xray-unblock.service") &&
        (verb == "start" || verb == "stop" || verb == "restart")) {
        return polkit.Result.YES;
    }
});
