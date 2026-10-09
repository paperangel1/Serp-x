#!/usr/bin/env bash
# logs_smoke_test.sh: every custom module must leave a line in its log during a smoke run, and canary secrets pushed through
# every module's inputs must never appear in any log or in `serpantinum-x report`.
# Runs entirely in a throw-away fake HOME: no real files, no network (only 127.0.0.1:9, refused), no VPN/systemd actions.
set -u
export PYTHONDONTWRITEBYTECODE=1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"          # .../src
REPO="$(cd "$SRC/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAKE="$T/home"; LOGS="$T/logs"
mkdir -p "$FAKE/.config/serpantinum/secrets" "$FAKE/.local/state" "$FAKE/.cache" "$FAKE/.local/share" "$T/run"
export HOME="$FAKE" XDG_CONFIG_HOME="$FAKE/.config" XDG_STATE_HOME="$FAKE/.local/state" XDG_CACHE_HOME="$FAKE/.cache" \
       XDG_DATA_HOME="$FAKE/.local/share" XDG_RUNTIME_DIR="$T/run" SERPANTINUM_LOG_DIR="$LOGS" \
       SERPANTINUM_FORK_DIR="$REPO" XLOG_LEVEL=info
unset HYPR_CONFIG_DIR QS_SETTINGS QS_STATE_DIR
S="$SRC/scripts/custom"
fail=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fail=1; }

# canary secrets (long enough to look like tokens)
C1="CANARYTOKENab12cd34ef56ab12cd34ef56ab12"
C2="CANARYPATHxyz9876xyz9876xyz9876xyz9876"
C3="CANARYKEYk1k2k3k4k5k6k7k8k9k0k1k2k3k4k5"

# --- update (changelog translation path: key file holds a canary, endpoint refuses connections)
printf '%s' "$C3" > "$T/gemini_key"
X_CHANGELOG_FILE="$REPO/CHANGELOG.md" X_UPDATE_CACHE_DIR="$T/cache" X_GEMINI_KEY_FILE="$T/gemini_key" X_GEMINI_PROXY="" \
  X_GEMINI_ENDPOINT="http://127.0.0.1:9/v1beta/models" X_GEMINI_MODELS="m1" bash "$S/x_changelog.sh" get latest ru >/dev/null 2>&1

# --- hotkeys (apply on a fake Hyprland config; hyprctl disabled)
mkdir -p "$FAKE/.config"; cp -r "$REPO/compositors/hyprland" "$FAKE/.config/hypr" 2>/dev/null
cat > "$FAKE/.config/serpantinum/settings.json" <<JSON
{"hotkeys":{"custom":[{"id":"hk_c","name":"CanaryName","mods":["SUPER"],"key":"X","type":"command","command":"echo $C1","enabled":true}],"overrides":[]}}
JSON
X_KEYBINDS_NO_HYPRCTL=1 bash "$S/x_keybinds.sh" apply >/dev/null 2>&1

# --- tools: OCR (image text is the canary: only its length may be logged), colours, notes
if command -v magick >/dev/null 2>&1; then magick -size 900x140 xc:white -fill black -pointsize 44 -annotate +10+80 "$C2" "$T/ocr.png" 2>/dev/null; else cp "$REPO/src/assets/icons/serp.png" "$T/ocr.png" 2>/dev/null || : > "$T/ocr.png"; fi
X_OCR_IMAGE="$T/ocr.png" X_COPY_CMD=true X_NOTIFY_CMD=true bash "$S/x_ocr.sh" --json --geometry "0,0 1x1" >/dev/null 2>&1
X_COPY_CMD=true X_COLORS_FILE="$T/colors.json" bash "$S/x_colors.sh" copy "#112233" rgb >/dev/null 2>&1
echo "{\"tools\":{\"notes\":{\"dir\":\"$T/notes\"}}}" > "$T/notes-settings.json"
X_SETTINGS="$T/notes-settings.json" bash "$S/x_notes.sh" new "Canary title $C1" >/dev/null 2>&1

# --- servers: secrets through stdin, then a poll against a refused local port
printf '%s\n' "$C1$C1" | python3 "$S/servers/x_servers.py" secret-set remnawave_token >/dev/null 2>&1
printf '%s\n' "http://127.0.0.1:9/$C2" | python3 "$S/servers/x_servers.py" secret-set remnawave_url >/dev/null 2>&1
python3 "$S/servers/x_servers.py" poll >/dev/null 2>&1

# --- vpn: a canary subscription link goes in through stdin; status/nodes/doctor are read-only
printf '%s\n' "https://canary-panel.example/sub/$C2?token=$C1" | bash "$S/vpn/x_vpn.sh" set-subscription >/dev/null 2>&1
bash "$S/vpn/x_vpn.sh" status >/dev/null 2>&1; bash "$S/vpn/x_vpn.sh" nodes >/dev/null 2>&1

# --- cmd: local engine, dry run with a canary argument
mkdir -p "$T/cmds"; cp "$S/cmd/examples/hello.cmd.json" "$T/cmds/" 2>/dev/null
XCMD_COMMANDS_DIR="$T/cmds" XCMD_STATE_DIR="$T/cmdstate" bash "$S/cmd/x_cmd.sh" --local list >/dev/null 2>&1
XCMD_COMMANDS_DIR="$T/cmds" XCMD_STATE_DIR="$T/cmdstate" bash "$S/cmd/x_cmd.sh" --local run hello --dry-run --arg "$C1" >/dev/null 2>&1

# --- doctor + logs viewer + report
bash "$REPO/bin/serpantinum-x" doctor >/dev/null 2>&1
bash "$REPO/bin/serpantinum-x" logs > "$T/logs-list.txt" 2>&1
REPORT="$(SERPANTINUM_FORK_DIR="$REPO" bash "$REPO/bin/serpantinum-x" report --out "$T/report.txt" 2>&1 | tail -1)"

# --- ui (QML XLog singleton through the real appender, offscreen)
if command -v quickshell >/dev/null 2>&1; then
    cp -a "$SRC" "$T/src"; cp "$DIR/xlog_ui/harness.qml" "$T/src/quickshell/harness_xlog.qml"
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" timeout 40 quickshell -p "$T/src/quickshell/harness_xlog.qml" >"$T/ui.out" 2>&1
fi

# --- assertions
for m in update hotkeys tools servers vpn cmd doctor ui; do
    if [ "$m" = ui ] && ! command -v quickshell >/dev/null 2>&1; then echo "skip ui (no quickshell)"; continue; fi
    if [ -s "$LOGS/$m.log" ]; then ok "module $m wrote $(wc -l < "$LOGS/$m.log") lines"; else bad "module $m wrote nothing"; fi
done
grep -q "debug line must stay hidden" "$LOGS/ui.log" 2>/dev/null && bad "QML debug line leaked at info level" || ok "QML debug stays hidden at info"
grep -q "with a newline" "$LOGS/ui.log" 2>/dev/null && ok "QML multi-line message kept" || { command -v quickshell >/dev/null 2>&1 && bad "QML multi-line message missing"; }
leaks="$(grep -l -E "CANARY|Canary title|CanaryName|canary-panel" "$LOGS"/*.log* "$T/report.txt" "$T/logs-list.txt" 2>/dev/null)"
[ -z "$leaks" ] && ok "no canary secret in any log, report or listing" || bad "canary leaked in: $leaks"
for f in "$LOGS"/*.log; do [ "$(stat -c %a "$f")" = "600" ] || bad "bad permissions on $f"; done
[ "$(stat -c %a "$LOGS")" = "700" ] && ok "log dir is 0700" || bad "log dir permissions"
[ -s "$T/report.txt" ] && grep -q "===== doctor =====" "$T/report.txt" && ok "report bundle written" || bad "report missing/empty ($REPORT)"
grep -q "каталог логов" "$T/logs-list.txt" && ok "serpantinum-x logs lists modules" || bad "logs listing broken"
ls "$FAKE/.local/state/serpantinum/logs" >/dev/null 2>&1 && bad "logs written under the fake HOME default instead of SERPANTINUM_LOG_DIR"
exit $fail
