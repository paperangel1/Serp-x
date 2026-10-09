#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# vpn_ui_test.sh: offscreen load of the VPN UI (bar face, popup, settings tab inside the REAL GuidePopup) with FAKE state.
# No backend, no network, no VPN: XVPN_FAKE_STATUS makes XVpn skip every process; HOME is a temp dir so nothing real is read or written.
# Usage: vpn_ui_test.sh [OUT_DIR]   (PNGs: F_V1.png F_V2.png F_V3.png). Exit 1 on any QML error in the logs.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$DIR/../../.." && pwd)"
OUT="${1:-$(mktemp -d)}"; mkdir -p "$OUT"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
command -v quickshell >/dev/null 2>&1 || { echo "quickshell not installed: skipped"; exit 0; }

cp -a "$SRC" "$T/src"
cp "$DIR/vpn_ui/harness.qml" "$T/src/quickshell/harness_vpn.qml"
mkdir -p "$T/home/.config/serpantinum" "$T/home/.cache" "$T/home/.local/state" "$T/home/.local/share"
echo '{}' > "$T/fake.json"

run() {   # run <mode>
    local mode="$1" log="$T/$1.log"
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
    QT_QPA_PLATFORM=offscreen SERPANTINUM_DIR="$T/src" QS_DIR="$T/src/quickshell" XVPN_FAKE_STATUS="$T/fake.json" \
    HARNESS_MODE="$mode" HARNESS_OUT="$OUT" timeout 60 quickshell -p "$T/src/quickshell/harness_vpn.qml" >"$log" 2>&1
    sed 's/\x1b\[[0-9;]*m//g' "$log" > "$log.txt"
    if grep -n -i -E "is not a type|failed to load|unavailable|ERROR|ReferenceError|TypeError|Cannot assign|is not defined" "$log.txt" | grep -v -E "ScreenshotOverlay|Cannot call method 'trim'" | head -8 | grep -q .; then
        echo "FAIL [$mode] QML errors:"; grep -n -i -E "is not a type|failed to load|unavailable|ERROR|ReferenceError|TypeError|Cannot assign|is not defined" "$log.txt" | head -8; fail=1
    else echo "ok   [$mode] no QML errors"; fi
}
for m in ${VPN_UI_MODES:-popup tab face ping}; do run "$m"; done
# ping display modes: the popup's own text/glyph functions, one line per mode
if [[ " ${VPN_UI_MODES:-popup tab face ping} " == *" ping "* ]]; then
    chk() { grep -q -F -- "$2" "$T/ping.log.txt" && echo "ok   ping $1" || { echo "FAIL ping $1: expected: $2"; fail=1; }; }
    chk digits "PINGTEXT digits: 21 мс | 250 мс | 900 мс | таймаут | ошибка | н/д | измеряю… ||"
    chk bars "PINGTEXT bars: <font color=\"#"
    chk barsDigits "</font> 21 мс | "
    chk dots "PINGTEXT dots: ● | ● | ● | ● | ● | ● | ● ||"
    chk hint "hint=н/д: выберите HTTP-метод"
    grep -q "PINGTEXT bars:.*▂▄▆█" "$T/ping.log.txt" && echo "ok   ping 4-bar glyph" || { echo "FAIL ping glyph"; fail=1; }
fi
[ -n "${VPN_UI_KEEP_LOGS:-}" ] && cp "$T"/*.log.txt "$OUT/" 2>/dev/null

# double-click guard: state-changing actions are dropped while busy / repeated; toggle has explicit intent
X="$SRC/quickshell/custom/vpn/XVpn.qml"
if grep -q 'ignored (busy or repeated' "$X" && grep -q 'now - lastActionMs < 1500' "$X" \
   && grep -q 'function toggle() { if (connected || transitional) disconnect(); else connect(); }' "$X"; then
    echo "ok   toggle double-fire guard"
else echo "FAIL toggle double-fire guard missing"; fail=1; fi

for f in F_V2 F_V3 face_on face_off face_failed; do [ -s "$OUT/$f.png" ] && echo "ok   $f.png" || { echo "FAIL missing $f.png"; fail=1; }; done
if command -v magick >/dev/null 2>&1 && [ -s "$OUT/face_on.png" ]; then
    magick "$OUT/face_on.png" "$OUT/face_off.png" "$OUT/face_failed.png" -append "$OUT/F_V1.png" && rm -f "$OUT"/face_*.png && echo "ok   F_V1.png"
fi
exit $fail
