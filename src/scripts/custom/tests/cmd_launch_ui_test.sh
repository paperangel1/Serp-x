#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# cmd_launch_ui_test.sh: offscreen test of the Commands launch surfaces (palette, bar button + menu, desktop widget) with FAKE data
# (XCmdLaunch.fake = true: no process, no daemon, no CLI). HOME and every XDG dir are temp. Usage: cmd_launch_ui_test.sh [OUT_DIR]
# PNGs: launch_palette_{default,running,error,blocked} launch_face_{paused,failed} launch_menu launch_widget_{running,ok,error}.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
command -v quickshell >/dev/null 2>&1 || { echo "quickshell not installed: skipped"; exit 0; }
cp -a "$SRC" "$T/src"
find "$T/src" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
cp "$DIR/cmd_launch_ui/harness.qml" "$T/src/quickshell/harness_launch.qml"
mkdir -p "$T/home/.config/serpantinum" "$T/home/.cache" "$T/home/.local/state" "$T/home/.local/share" "$T/run"
log="$T/run.log"
HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
XDG_RUNTIME_DIR="$T/run" XCMD_SOCKET="$T/run/none.sock" QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" \
HARNESS_OUT="$OUT" timeout 90 quickshell -p "$T/src/quickshell/harness_launch.qml" >"$log" 2>&1
sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^.*LCH /LCH /' "$log" > "$log.txt"
pass=0; fail=0
chk() {   # chk <key> <expected exact value>
    if grep -q -x -F -- "LCH $1: $2" "$log.txt"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: expected '$2', got: $(grep -- "^LCH $1: " "$log.txt" | head -1)"; fi
}
if grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|binding loop|Cannot read" "$log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'" | head -8 | grep -q .; then
    fail=$((fail+1)); echo "FAIL QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|binding loop|Cannot read" "$log.txt" | head -8
fi
chk empty_text "Пока нет ручных команд. Создайте их в приложении «Команды»."
chk empty_rows 0
chk menu_nopins true
chk wg_empty_visible true
chk watchers_after_faces 2
chk error_text "Не удалось прочитать список команд"
chk rows_default 5
chk first_pinned "focus,quote"
chk auto_hidden false
chk blocked_rows 2
chk block_text_unapproved "⚠ В команде есть ошибки: откройте её и исправьте|⚠ Права не подтверждены: откройте команду и подтвердите"
chk menu_items 2
chk filter_fok "focus"
chk filter_keyword "focus"
chk filter_fuzzy "focus"
chk filter_auto_hidden "0|Ничего не найдено. Tab: искать и среди автоматизаций"
chk filter_auto_shown "night"
chk auto_badge 1
chk nothing_text "Ничего не найдено"
chk run_calls '[["run","Фокус 25 минут"]]'
chk run_state running
chk closed_after_run 1
chk notice_running "running|Запущено: Фокус 25 минут|"
chk row_status_running "выполняется…"
chk error_state error
chk notice_error "error|Ошибка: Фокус 25 минут|нет доступа к dbus"
chk row_status_error "ошибка"
chk blocked_not_run true
chk blocked_notice "error|Не запущена: Сфотографировать экран|Права не подтверждены: откройте команду и подтвердите"
chk blocked_open_btn 1
chk blocked_row_text "⚠ Права не подтверждены: откройте команду и подтвердите"
chk errors_notice "error|Не запущена: Сломанная|В команде есть ошибки: откройте её и исправьте"
chk pin_calls '[["pin","cache"]]'
chk pinned_ids "focus,quote,cache"
chk pinned_flag true
chk unpin_calls '[["pin","cache"],["unpin","focus"]]'
chk wrap_index true
chk watchers 2
chk dot_none false
chk dot_paused "true,#f9e2af"
chk side_dot_paused true
chk dot_failed "true,#f38ba8"
chk dot_cleared false
chk menu_pause_calls '[["pause"]]'
chk menu_open_app app
chk menu_palette_open true
chk wg_buttons 2
chk wg_rows 2
chk wg_empty_hidden false
chk wg_state_running running
chk wg_state_ok ok
chk wg_state_error error
chk watchers_released 0
chk subscribers 3
# LaunchLogic.js (ranking, block reasons) with plain node: the file is a QML `.pragma library` module without QML types
if command -v node >/dev/null 2>&1; then
    res="$(node - "$SRC/quickshell/custom/cmd/LaunchLogic.js" <<'JS'
const fs = require("fs");
eval(fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma.*$/m, ""));
const C = (id, name, o) => Object.assign({ id, name, description: "", kind: "manual", approved: true, errors: 0, keywords: [], triggers: [] }, o || {});
const cmds = [C("a", "Альфа"), C("b", "Бета", { last_run: { ts: 100 } }), C("c", "Гамма", { last_run: { ts: 200 } }), C("d", "Дельта"),
              C("e", "Эхо", { kind: "auto" }), C("f", "Фокус", { description: "Таймер работы" }), C("g", "Лог", { keywords: ["Уведомление"] }), C("x", "Пример", { example: true })];
const ids = l => l.map(c => c.id).join(",");
const out = [];
out.push("empty_order=" + ids(rank(cmds, ["d"], "", false)));            // pinned, then recent (newest first), then by name
out.push("auto_shown=" + ids(rank(cmds, [], "эхо", true)) + "|" + ids(rank(cmds, [], "эхо", false)));
out.push("desc=" + ids(rank(cmds, [], "таймер", false)));
out.push("keyword=" + ids(rank(cmds, [], "уведомл", false)));
out.push("tokens=" + ids(rank(cmds, [], "фокус таймер", false)) + "|" + ids(rank(cmds, [], "фокус бета", false)));
out.push("fuzzy=" + ids(rank(cmds, [], "фкс", false)) + "|" + ids(rank(cmds, [], "ксф", false)));
out.push("prefix_first=" + ids(rank([C("1", "Запуск таймера"), C("2", "Таймер")], [], "таймер", false)));
out.push("pin_bonus=" + ids(rank([C("1", "Тест один"), C("2", "Тест два")], ["2"], "тест", false)));
out.push("example_hidden=" + (ids(rank(cmds, [], "", true)).indexOf("x") < 0));
out.push("block=" + [blockReason(C("1", "x")), blockReason(C("1", "x", { errors: 1 })), blockReason(C("1", "x", { approved: false })), blockReason(C("1", "x", { example: true }))].join(","));
out.push("pinnedOf=" + ids(pinnedOf(cmds, ["f", "zzz", "a"])));
out.push("ago=" + [ago(1000, 1000 * 1000 + 30000, { now: "n", min: "m", hour: "h", day: "d" }), ago(1000, 1000 * 1000 + 600000, { now: "n", min: "m", hour: "h", day: "d" }), ago(1000, 1000 * 1000 + 7300000, { now: "n", min: "m", hour: "h", day: "d" })].join(","));
console.log(out.join("\n"));
JS
)"
    lchk() { if grep -q -x -F -- "$1=$2" <<<"$res"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL logic $1: expected '$2', got: $(grep -- "^$1=" <<<"$res" | head -1)"; fi; }
    lchk empty_order "d,c,b,a,g,f"
    lchk auto_shown "e|"
    lchk desc "f"
    lchk keyword "g"
    lchk tokens "f|"
    lchk fuzzy "f|"
    lchk prefix_first "2,1"
    lchk pin_bonus "2,1"
    lchk example_hidden true
    lchk block ",errors,unapproved,example"
    lchk pinnedOf "f,a"
    lchk ago "n,10 m,2 h"
fi
for f in palette_default palette_running palette_error palette_blocked face_paused face_failed menu widget_running widget_ok widget_error; do
    [ -s "$OUT/launch_$f.png" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL no screenshot launch_$f.png"; }
done
[ $fail -ne 0 ] && [ -n "${LCH_VERBOSE:-}" ] && tail -25 "$log.txt"
echo "cmd_launch_ui_test: $pass passed, $fail failed"
[ $fail -eq 0 ]
