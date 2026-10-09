#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# servers_ui_test.sh: offscreen test of the «Добавить сервер» form and the delete/consent panels in the REAL ServersTab with
# FAKE state (XServers.fake = true: no process, no network, no config). HOME and all XDG dirs are temp.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
command -v quickshell >/dev/null 2>&1 || { echo "quickshell not installed: skipped"; exit 0; }
cp -a "$SRC" "$T/src"
cp "$DIR/servers_ui/harness.qml" "$T/src/quickshell/harness_servers.qml"
mkdir -p "$T/home/.config/serpantinum" "$T/home/.cache" "$T/home/.local/state" "$T/home/.local/share"
log="$T/run.log"
HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" \
HARNESS_OUT="$OUT" timeout 60 quickshell -p "$T/src/quickshell/harness_servers.qml" >"$log" 2>&1
sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^.*SRVUI /SRVUI /' "$log" > "$log.txt"
pass=0; fail=0
chk() {   # chk <key> <expected exact value>
    if grep -q -F -- "SRVUI $1: $2" "$log.txt" && [ "$(grep -c -- "^SRVUI $1: " "$log.txt")" -ge 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: expected '$2', got: $(grep -- "SRVUI $1: " "$log.txt" | head -1)"; fi
}
if grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|binding loop" "$log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'" | head -8 | grep -q .; then
    fail=$((fail+1)); echo "FAIL QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|binding loop" "$log.txt" | head -8
fi
chk form_closed 0
chk manual_badges 1
chk remove_buttons 1
chk form_open 1
chk fresh_err_name '""'
chk tried_err_name shown
chk tried_err_host shown
chk backend_called no
chk err_name_after_fix '""'
chk err_host_bad shown
chk err_port_bad shown
chk valid_with_bad false
chk err_user_bad shown
chk valid_with_bad_user false
chk valid_all true
chk ipv6_ok "true,true,false,false"
chk fake_backend_untouched yes
chk dup_text "Сервер с таким адресом и портом уже добавлен"
chk added_text "Сервер добавлен. Доступ ещё не установлен."
chk connect_now_visible 1
chk manual_badges_after 2
chk enroll_for "m:vps"
chk form_closed_after 0
chk consent_title 1
chk consent_bullets 5
chk consent_has_serp_run true
chk consent_pw_once true
chk remove_panel 1
chk remove_text true
chk remove_both_not_enrolled 0
chk remove_both_enrolled 1
chk remove_widget_btn 1
[ -s "$OUT/servers_add.png" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no screenshot"; }
echo "servers_ui_test: $pass passed, $fail failed"
[ $fail -eq 0 ]
