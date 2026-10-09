#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# cmd_edit_test.sh: offscreen test of the Commands EDITOR with REAL mouse / keyboard events (QtTest helpers) on the REAL window,
# the REAL CLI and temp command files (tests/cmd_ui/harness_edit.qml). No daemon, no systemd, no network, no VPN; HOME is a temp dir.
# Usage: cmd_edit_test.sh [OUT_DIR]   PNGs: E1_palette E2_wire_drag E3_type_error E4_permission E5_list_actions. Exit 1 on any T-FAIL / QML error.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
command -v quickshell >/dev/null 2>&1 || { echo "quickshell not installed: skipped"; exit 0; }

cp -a "$SRC" "$T/src"
find "$T/src" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
cp "$DIR/cmd_ui/harness_edit.qml" "$T/src/quickshell/harness_edit.qml"
PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/cmd_ui/make_fixtures.py" "$T/fx" >/dev/null
mkdir -p "$T/home/.config/serpantinum" "$T/home/.cache" "$T/home/.local/state" "$T/home/.local/share" "$T/run" "$T/state" "$T/fakebin" "$T/scratch"
printf '#!/bin/sh\ncase "$2" in is-enabled) echo disabled; exit 1;; is-active) echo inactive; exit 3;; esac\nexit 0\n' > "$T/fakebin/systemctl"
chmod +x "$T/fakebin/systemctl"

run_mode() {   # run_mode <mode> <commands-dir> <log>
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
    XDG_RUNTIME_DIR="$T/run" XCMD_COMMANDS_DIR="$2" XCMD_EXTRA_NODES="$T/fx/nodes" XCMD_STATE_DIR="$T/state_$1" XCMD_SOCKET="$T/run/none.sock" \
    XCMD_SYSTEMCTL="$T/fakebin/systemctl" PYTHONDONTWRITEBYTECODE=1 \
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" HARNESS_OUT="$OUT" HARNESS_TMP="$T/scratch" HARNESS_MODE="$1" \
    timeout 240 quickshell -p "$T/src/quickshell/harness_edit.qml" >"$3" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$3" > "$3.txt"
}
log="$T/edit.log"
PYTHONDONTWRITEBYTECODE=1 python3 "$DIR/cmd_ui/make_fixtures.py" "$T/fxbig" --big 200 >/dev/null
mkdir -p "$T/bigonly"; cp "$T/fxbig/commands/big.cmd.json" "$T/bigonly/"
run_mode perf "$T/bigonly" "$T/perf.log"
[ -n "${CMD_EDIT_KEEP_LOG:-}" ] && cp "$T/perf.log.txt" "$OUT/perf.log.txt"
grep -h -E "PERF-EDIT" "$T/perf.log.txt" | sed 's/^ *DEBUG qml: //'
grep -h -E "^ *DEBUG qml: T-(PASS|FAIL)" "$T/perf.log.txt" | sed 's/^ *DEBUG qml: //' | grep "^T-FAIL" && fail=1
grep -q "T-RESULT" "$T/perf.log.txt" || { echo "FAIL: the perf run did not finish"; fail=1; }
run_mode main "$T/fx/commands" "$log"
[ -n "${CMD_EDIT_KEEP_LOG:-}" ] && cp "$log.txt" "$OUT/edit.log.txt"

# functions: collapse / expand / edit the function / breadcrumbs / library on a copy of the fixtures
cp -a "$T/fx/commands" "$T/fxfn"
run_mode fn "$T/fxfn" "$T/fn.log"
[ -n "${CMD_EDIT_KEEP_LOG:-}" ] && cp "$T/fn.log.txt" "$OUT/fn.log.txt"
grep -q "T-RESULT" "$T/fn.log.txt" || { echo "FAIL: the functions run did not finish"; fail=1; }
grep -h -E "^ *DEBUG qml: T-(PASS|FAIL|RESULT)" "$log.txt" "$T/fn.log.txt" | sed 's/^ *DEBUG qml: //' > "$T/results.txt"
cat "$T/fn.log.txt" >> "$log.txt"
grep -c "^T-PASS" "$T/results.txt" | sed 's/^/passed: /'
if grep -q "^T-FAIL" "$T/results.txt"; then echo "FAILED checks:"; grep "^T-FAIL" "$T/results.txt"; fail=1; fi
grep -h "^T-RESULT" "$T/results.txt" || { echo "FAIL: the harness did not finish (no T-RESULT)"; fail=1; }
errs="$(grep -n -i -E "is not a type|failed to load|unavailable|ERROR|ReferenceError|TypeError|Cannot assign|is not defined|Binding loop|Unable to assign" "$log.txt" | grep -v -E "T-PASS|T-FAIL|ScreenshotOverlay|Cannot call method 'trim'|QSettings|Could not load icon|Unable to assign \[undefined\]" | head -12)"
if [ -n "$errs" ]; then echo "FAIL QML errors:"; echo "$errs"; fail=1; else echo "ok   no QML errors"; fi
for f in E1_palette E2_wire_drag E3_type_error E4_permission E5_list_actions E6_collapse_bar E7_call_node E8_function_graph E9_function_library; do
    [ -s "$OUT/$f.png" ] && echo "ok   $f.png" || { echo "FAIL missing $f.png"; fail=1; }
done
exit $fail
