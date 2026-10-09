import QtQuick
import Quickshell
import "custom"
import "custom/servers"

// Offscreen harness for the Servers tab «Добавить сервер» form (copied into the quickshell tree by servers_ui_test.sh).
// XServers.fake = true: no process is started; the "backend" answers are injected. Results are printed as "SRVUI key: value".
ShellRoot {
    id: shell
    readonly property string outDir: Quickshell.env("HARNESS_OUT") || "/tmp"
    property var tab: null
    property int step: 0

    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        let ch = item.children || [];
        for (let i = 0; i < ch.length; i++) { let r = find(ch[i], name); if (r) return r; }
        return null;
    }
    function findAll(item, name, out) {
        if (!item) return out;
        if (item.objectName === name) out.push(item);
        let ch = item.children || [];
        for (let i = 0; i < ch.length; i++) findAll(ch[i], name, out);
        return out;
    }
    function texts(item, out) {
        if (!item) return out;
        if (item.visible && item.text !== undefined && typeof item.text === "string" && item.text !== "") out.push(item.text);
        let ch = item.children || [];
        for (let i = 0; i < ch.length; i++) texts(ch[i], out);
        return out;
    }
    function say(k, v) { console.log("SRVUI " + k + ": " + v); }
    // objects that repeat per server (delegates): "visible" means any instance is visible
    function vis(name) { let l = findAll(tab, name, []); return l.length ? (l.some(o => o.visible) ? 1 : 0) : "missing"; }
    function visOne(name) { return findAll(tab, name, []).filter(o => o.visible)[0] || null; }
    function txt(name) { let o = find(tab, name); return o ? o.text : "missing"; }
    function setf(name, v) { find(tab, name).text = v; }

    FloatingWindow {
        id: win
        visible: true
        width: 1000; height: 900
        color: "#0f0e14"
        QtObject { id: fakeRoot; property int currentTab: 0; function s(v) { return v; } }
        Rectangle {
            id: box; anchors.fill: parent; color: "#0f0e14"
            ServersTab { id: serversTab; rootObj: fakeRoot; tabIndex: 0 }
        }
    }

    Component.onCompleted: {
        XServers.fake = true;
        XServers.cfgInfo = { urlSet: true, tokenSet: true, host: "panel.example.test", key: { exists: true, fingerprint: "SHA256:abc" }, commands: [
            { id: "diag-net", label: "Сеть", group: "diag" }, { id: "act-reboot", label: "Перезагрузить", group: "action" }], problems: [] };
        XServers.servers = [
            { id: "uuid-1", name: "Germany-1", flag: "", online: true, xrayVersion: "26.1", ssh: { state: "ok" }, address: "de.example.test", port: 22, user: "serp" },
            { id: "m:box", name: "Box", flag: "", manual: true, online: null, ssh: { state: "unknown" }, address: "box.example.test", port: 22, user: "serp" }];
        tab = serversTab;
    }

    Timer {
        interval: 700; repeat: true; running: true
        onTriggered: {
            step++;
            if (step === 1) {
                say("form_closed", vis("addForm"));
                say("manual_badges", texts(tab, []).filter(t => t === "свой").length);
                say("remove_buttons", texts(tab, []).filter(t => t === "Удалить").length);
                tab.addOpen = true;
            } else if (step === 2) {
                say("form_open", vis("addForm"));
                say("fresh_err_name", JSON.stringify(txt("errName")));
                tab.submitAdd();
            } else if (step === 3) {
                say("tried_err_name", txt("errName") !== "" ? "shown" : "none");
                say("tried_err_host", txt("errHost") !== "" ? "shown" : "none");
                say("backend_called", XServers.addState === "" ? "no" : "yes");
                setf("addName", "Мой VPS"); setf("addHost", "bad host;rm"); setf("addPort", "99999");
            } else if (step === 4) {
                say("err_name_after_fix", JSON.stringify(txt("errName")));
                say("err_host_bad", txt("errHost") !== "" ? "shown" : "none");
                say("err_port_bad", txt("errPort") !== "" ? "shown" : "none");
                say("valid_with_bad", tab.addValid());
                setf("addHost", "vps.example.test"); setf("addPort", "2222"); tab.addAdvanced = true; setf("addUser", "Root");
            } else if (step === 5) {
                say("err_user_bad", txt("errUser") !== "" ? "shown" : "none");
                say("valid_with_bad_user", tab.addValid());
                setf("addUser", "");
                say("valid_all", tab.addValid());
                say("ipv6_ok", tab.hostOk("2001:db8::1") + "," + tab.hostOk("10.0.0.1") + "," + tab.hostOk("999.1.1.1") + "," + tab.hostOk("a b"));
                tab.submitAdd();
                say("fake_backend_untouched", XServers.addState === "" ? "yes" : "no");
                XServers.addState = "error:duplicate:";
            } else if (step === 6) {
                say("dup_text", txt("addStatus"));
                XServers.servers = XServers.servers.concat([{ id: "m:vps", name: "Мой VPS", manual: true, online: null, ssh: { state: "unknown" }, address: "vps.example.test", port: 2222, user: "serp" }]);
                XServers.lastAddedId = "m:vps"; XServers.addState = "ok";
            } else if (step === 7) {
                say("added_text", txt("addStatus"));
                say("connect_now_visible", vis("addNow"));
                say("manual_badges_after", texts(tab, []).filter(t => t === "свой").length);
                find(tab, "addNow").clicked();
            } else if (step === 8) {
                say("enroll_for", tab.enrollFor);
                say("form_closed_after", vis("addForm"));
                let all = texts(tab, []);
                say("consent_title", all.filter(t => t === "Что будет установлено на сервере").length);
                say("consent_bullets", all.filter(t => t.indexOf("•  ") === 0).length);
                say("consent_has_serp_run", all.some(t => t.indexOf("serp-run") !== -1 && t.indexOf("diag-net") !== -1));
                say("consent_pw_once", all.some(t => t.indexOf("один раз") !== -1 && t.indexOf("не сохраняется") !== -1));
                tab.removeFor = "m:vps";
            } else if (step === 9) {
                say("remove_panel", vis("removePanel"));
                say("remove_text", texts(visOne("removePanel"), []).some(t => t.indexOf("только из виджета") !== -1));
                say("remove_both_not_enrolled", vis("removeBoth"));
                XServers.servers = XServers.servers.map(s => s.id === "m:vps" ? Object.assign({}, s, { ssh: { state: "ok" } }) : s);
            } else if (step === 10) {
                say("remove_both_enrolled", vis("removeBoth"));
                say("remove_widget_btn", vis("removeWidget"));
                box.grabToImage(function(r) { r.saveToFile(shell.outDir + "/servers_add.png"); Qt.quit(); });
            }
        }
    }
}
