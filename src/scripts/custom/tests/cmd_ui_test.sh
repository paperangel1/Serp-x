#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# cmd_ui_test.sh: offscreen load of the REAL Commands window (list, gallery, graph, node help, 200-node graph) against the
# REAL CLI pointed at FAKE fixtures (tests/cmd_ui/make_fixtures.py: test-only node types + demo commands in temp dirs).
# No daemon, no systemd, no network, no VPN; HOME is a temp dir. Usage: cmd_ui_test.sh [OUT_DIR]
# PNGs: F_C1 F_C_examples F_C2 F_C5 F_C5_fn F_C2_big F_C7_gallery F_C7_open F_C7_docs F_C7_tutorial. Exit 1 on any QML error in the logs. CMD_UI_MODES overrides the mode list.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
command -v quickshell >/dev/null 2>&1 || { echo "quickshell not installed: skipped"; exit 0; }

cp -a "$SRC" "$T/src"
find "$T/src" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
cp "$DIR/cmd_ui/harness.qml" "$T/src/quickshell/harness_cmd.qml"
PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/cmd_ui/make_fixtures.py" "$T/fx" --big 200 >/dev/null
mkdir -p "$T/home/.config/serpantinum" "$T/home/.cache" "$T/home/.local/state" "$T/home/.local/share" "$T/run" "$T/state" "$T/fakebin"
printf '#!/bin/sh\ncase "$2" in is-enabled) echo disabled; exit 1;; is-active) echo inactive; exit 3;; esac\nexit 0\n' > "$T/fakebin/systemctl"
chmod +x "$T/fakebin/systemctl"

run() {   # run <mode>
    local mode="$1" log="$T/$1.log"
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_RUNTIME_DIR="$T/run" XCMD_COMMANDS_DIR="$T/fx/commands" XCMD_EXTRA_NODES="$T/fx/nodes" XCMD_STATE_DIR="$T/state" XCMD_SOCKET="$T/run/none.sock" \
    XCMD_SYSTEMCTL="$T/fakebin/systemctl" PYTHONDONTWRITEBYTECODE=1 \
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" HARNESS_MODE="$mode" HARNESS_OUT="$OUT" \
    timeout 90 quickshell -p "$T/src/quickshell/harness_cmd.qml" >"$log" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$log" > "$log.txt"
    if grep -n -i -E "is not a type|failed to load|unavailable|ERROR|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop" "$log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'|QSettings|Could not load icon" | head -8 | grep -q .; then
        echo "FAIL [$mode] QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ERROR|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop" "$log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'|QSettings|Could not load icon" | head -8; fail=1
    else echo "ok   [$mode] no QML errors"; fi
    grep -h "PERF" "$log.txt"
}
for m in ${CMD_UI_MODES:-list examples graph help fn big perf gallery galleryopen docs tutorial}; do run "$m"; done
[ -n "${CMD_UI_KEEP_LOGS:-}" ] && cp "$T"/*.log.txt "$OUT/" 2>/dev/null
for f in F_C1:list F_C_examples:examples F_C2:graph F_C5:help F_C5_fn:fn F_C2_big:big F_C7_gallery:gallery F_C7_open:galleryopen F_C7_docs:docs F_C7_tutorial:tutorial; do
    case " ${CMD_UI_MODES:-list examples graph help fn big perf gallery galleryopen docs tutorial} " in *" ${f#*:} "*) ;; *) continue ;; esac
    [ -s "$OUT/${f%%:*}.png" ] && echo "ok   ${f%%:*}.png" || { echo "FAIL missing ${f%%:*}.png"; fail=1; }
done
# stage 8 data checks: the gallery browser, a gallery command opened read-only, the docs viewer, the tutorial state machine
ui() { grep -h "UI $1" "$T/$2.log.txt" | sed 's/^.*qml: //'; }
if [ -s "$T/gallery.log.txt" ]; then
    ui gallery gallery | grep -q "gallery n=13 cards=13 pending=[0-9]* withpkg=1 screen=gallery" && echo "ok   [gallery] 13 cards, one needs a package" || { echo "FAIL [gallery] $(ui gallery gallery)"; fail=1; }
    ui galleryopen galleryopen | grep -q "screen=graph example=true comments=4 name=Фокус 25 минут firstcomment=Запуск" && echo "ok   [galleryopen] read-only, annotated" || { echo "FAIL [galleryopen] $(ui galleryopen galleryopen)"; fail=1; }
    ui docs docs | grep -q "screen=docs pages=1[0-9] id=security len=[0-9]\{3,\}" && echo "ok   [docs] page rendered from the CLI" || { echo "FAIL [docs] $(ui docs docs)"; fail=1; }
    ui tutorial tutorial | tr '\n' ' ' | grep -q "offer=true steps=7 .*active=true step=0 .*step=1 .*step=1 .*step=3" && echo "ok   [tutorial] offer, start, advance on events" || { echo "FAIL [tutorial] $(ui tutorial tutorial)"; fail=1; }
    [ -s "$T/state/tutorial.json" ] && grep -q '"step": 3' "$T/state/tutorial.json" && echo "ok   [tutorial] progress persisted" || { echo "FAIL [tutorial] progress file: $(cat "$T/state/tutorial.json" 2>&1)"; fail=1; }
fi
# ask / show-result bridge: the real XCmdBridge + dialogs against a fake daemon socket
if [ -z "${CMD_UI_SKIP_ASK:-}" ]; then
    cp "$DIR/cmd_ui/harness_ask.qml" "$T/src/quickshell/harness_ask.qml"
    python3 "$DIR/cmd_ui/fake_ui_daemon.py" "$T/run/ask.sock" "$T/ask_answers.json" >"$T/fake_daemon.log" 2>&1 &
    dpid=$!
    sleep 0.5
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_RUNTIME_DIR="$T/run" XCMD_SOCKET="$T/run/ask.sock" PYTHONDONTWRITEBYTECODE=1 \
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" \
    timeout 60 quickshell -p "$T/src/quickshell/harness_ask.qml" >"$T/ask.log" 2>&1
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
    sed 's/\x1b\[[0-9;]*m//g' "$T/ask.log" > "$T/ask.log.txt"
    want='[{"id": "ui0", "index": 1}, {"id": "ui1", "value": "привет"}, {"id": "ui2", "value": "2.5"}, {"id": "ui3", "answer": false}, {"id": "ui4", "cancel": true}, {"id": "ui5", "answer": true}, {"id": "ui6", "shown": true}]'
    got="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), ensure_ascii=False))' "$T/ask_answers.json" 2>/dev/null)"
    if [ "$got" != "$want" ]; then echo "FAIL [ask] answers differ:"; echo " got:  $got"; echo " want: $want"; head -5 "$T/fake_daemon.log"; tail -15 "$T/ask.log.txt"; fail=1
    elif grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop|ERROR" "$T/ask.log.txt" | grep -v -E "QSettings|Could not load icon|quickshell.io.socket" | head -5 | grep -q .; then
        echo "FAIL [ask] QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop|ERROR" "$T/ask.log.txt" | grep -v "quickshell.io.socket" | head -5; fail=1
    else echo "ok   [ask] dialogs answered through the daemon socket"; fi
fi
# debug overlay: the real window + XCmdDebug against a FAKE daemon that pushes a recorded trace (also a 2000-event burst)
if [ -z "${CMD_UI_SKIP_DEBUG:-}" ]; then
    cp "$DIR/cmd_ui/harness_debug.qml" "$T/src/quickshell/harness_debug.qml"
    python3 "$DIR/cmd_ui/fake_trace_daemon.py" "$T/run/dbg.sock" "$T/dbg_requests.json" --burst 2000 >"$T/fake_trace.log" 2>&1 &
    dpid=$!
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_RUNTIME_DIR="$T/run" XCMD_COMMANDS_DIR="$T/fx/commands" XCMD_EXTRA_NODES="$T/fx/nodes" XCMD_STATE_DIR="$T/state" XCMD_SOCKET="$T/run/none.sock" XCMD_DEBUG_SOCKET="$T/run/dbg.sock" \
    XCMD_SYSTEMCTL="$T/fakebin/systemctl" PYTHONDONTWRITEBYTECODE=1 HARNESS_OUT="$OUT" \
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" \
    timeout 80 quickshell -p "$T/src/quickshell/harness_debug.qml" >"$T/debug.log" 2>&1
    kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
    sed 's/\x1b\[[0-9;]*m//g' "$T/debug.log" > "$T/debug.log.txt"
    dbg() { grep -h "DEBUG $1" "$T/debug.log.txt" | tail -1 | sed 's/^.*qml: //'; }
    want_states="DEBUG states n1=ok n2=ok n3=bad n4=-"
    if [ "$(dbg states)" != "$want_states" ]; then echo "FAIL [debug] node states: $(dbg states)"; tail -12 "$T/debug.log.txt"; fail=1
    elif ! dbg "run=" | grep -q "status=err live=false rehearse=true"; then echo "FAIL [debug] run state: $(dbg 'run=')"; fail=1
    elif ! dbg "failure=" | grep -q "n3:Цель «xcmd» оболочки не отвечает busy=\$"; then echo "FAIL [debug] error panel data: $(dbg 'failure=')"; fail=1
    elif [ "$(dbg wires=)" != "DEBUG wires=n1:device>n2:device,n1:exec>n2:exec_in,n2:exec_out>n3:exec_in" ]; then echo "FAIL [debug] wires: $(dbg wires=)"; fail=1
    elif ! dbg "panel=" | grep -q "panel=true errbox=true badge=true"; then echo "FAIL [debug] panel: $(dbg 'panel=')"; fail=1
    elif ! dbg "tooltip=" | grep -q "sel=n3"; then echo "FAIL [debug] hover / focus: $(dbg 'tooltip=')"; fail=1
    elif ! python3 -c 'import json,sys; r=[m for m in json.load(open(sys.argv[1])) if m.get("method")=="run"]; p=r[0]["params"]; assert p["rehearse"] is True and p["debug"] is True and p["breakpoints"]==["n4"] and p["step"] is False, p' "$T/dbg_requests.json" 2>/dev/null; then
        echo "FAIL [debug] the run request lost rehearse / breakpoints:"; cat "$T/dbg_requests.json" 2>/dev/null | head -c 600; fail=1
    elif grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop|ERROR" "$T/debug.log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'|QSettings|Could not load icon|quickshell.io.socket" | head -5 | grep -q .; then
        echo "FAIL [debug] QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop|ERROR" "$T/debug.log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'|QSettings|Could not load icon|quickshell.io.socket" | head -5; fail=1
    else echo "ok   [debug] overlay: states, wires, steps, error panel, breakpoints, hover (recorded trace + 2000-event burst)"; fi
    [ -s "$OUT/F_C3.png" ] && echo "ok   F_C3.png" || { echo "FAIL missing F_C3.png"; fail=1; }
fi
exit $fail
