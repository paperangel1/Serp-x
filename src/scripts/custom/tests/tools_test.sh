#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Unit tests for x_ocr.sh, x_colors.sh, x_notes.sh. Everything runs in a fake HOME; the clipboard and
# notifications are replaced by files, grim is never called (X_OCR_IMAGE).
cd "$(dirname "$0")/.." || exit 1
S="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.config/serpantinum" "$HOME/.local/state/serpantinum"
export X_SETTINGS="$HOME/.config/serpantinum/settings.json"
export QS_STATE_DIR="$HOME/.local/state/serpantinum"
printf '#!/usr/bin/env bash\ncat > "%s/clip"\n' "$T" > "$T/copy"; chmod +x "$T/copy"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$T" > "$T/notify.sh"; chmod +x "$T/notify.sh"
export X_COPY_CMD="$T/copy" X_NOTIFY_CMD="$T/notify.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1 (got '$2', want '$3')"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 (missing '$3' in '$2')" ;; esac; }

# ---------------------------------------------------------------- colors
C="$S/x_colors.sh"
eq "format hex"  "$(bash "$C" format '#ff6734' hex)" '#FF6734'
eq "format rgb"  "$(bash "$C" format 'ff6734' rgb)" 'rgb(255, 103, 52)'
eq "format hsl"  "$(bash "$C" format '#FF6734' hsl)" 'hsl(15, 100%, 60%)'
eq "format hsl gray" "$(bash "$C" format '#808080' hsl)" 'hsl(0, 0%, 50%)'
bash "$C" format 'nothex' hex >/dev/null 2>&1; eq "bad colour rejected" "$?" 1
bash "$C" add '#aaaaaa'; bash "$C" add '#bbbbbb'; bash "$C" add '#AAAAAA'
eq "dedupe moves to front" "$(bash "$C" list | jq -r 'map(.hex) | join(",")')" '#AAAAAA,#BBBBBB'
X_COLORS_MAX=3 bash "$C" add '#111111'; X_COLORS_MAX=3 bash "$C" add '#222222'
eq "max trims" "$(bash "$C" list | jq length)" 3
out="$(bash "$C" copy '#FE6734' rgb)"
eq "copy prints" "$out" 'rgb(254, 103, 52)'
eq "copy clipboard" "$(cat "$T/clip")" 'rgb(254, 103, 52)'
eq "copy adds to history" "$(bash "$C" list | jq -r '.[0].hex')" '#FE6734'
bash "$C" clear; eq "clear" "$(bash "$C" list)" '[]'
echo 'garbage' > "$QS_STATE_DIR/x_colors.json"; eq "corrupt store tolerated" "$(bash "$C" list)" '[]'

# ---------------------------------------------------------------- notes
N="$S/x_notes.sh"
eq "default dir" "$(bash "$N" dir)" "$HOME/Notes"
eq "empty list" "$(bash "$N" list)" '[]'
eq "empty latest" "$(bash "$N" latest)" '{}'
p1="$(bash "$N" new 'Первая')"; sleep 1.1
printf '# Вторая\n\n- пункт\n' > "$HOME/Notes/zzz.md"
case "$p1" in "$HOME/Notes/"*.md) ok ;; *) bad "new path $p1" ;; esac
eq "new with title" "$(head -1 "$p1")" '# Первая'
p2="$(bash "$N" new)"; p3="$(bash "$N" new)"
[ "$p2" != "$p3" ] && ok || bad "new notes must not collide"
eq "list length" "$(bash "$N" list | jq length)" 4
eq "title from heading" "$(bash "$N" list | jq -r '.[] | select(.name=="zzz.md") | .title')" 'Вторая'
touch -d '2030-01-01' "$HOME/Notes/zzz.md"
eq "latest = newest mtime" "$(bash "$N" latest | jq -r .name)" 'zzz.md'
jq -n --arg d "$T/custom-notes" '{tools:{notes:{dir:$d}}}' > "$X_SETTINGS"
eq "dir from settings" "$(bash "$N" dir)" "$T/custom-notes"
printf '{"tools":{"notes":{"dir":"~/Elsewhere"}}}' > "$X_SETTINGS"
eq "tilde expanded" "$(bash "$N" dir)" "$HOME/Elsewhere"
bash "$N" trash "/etc/passwd" 2>/dev/null; eq "trash refuses outside dir" "$?" 1
rm -f "$X_SETTINGS"

# ---------------------------------------------------------------- ocr
O="$S/x_ocr.sh"
if command -v tesseract >/dev/null 2>&1 && command -v magick >/dev/null 2>&1; then
    FONT="$(fc-match -f '%{file}' 'DejaVu Sans' 2>/dev/null)"; [ -f "$FONT" ] || FONT="$(fc-match -f '%{file}' sans)"
    magick -size 900x240 xc:white -font "$FONT" -pointsize 44 -fill black \
        -annotate +20+70 'Договор оказания услуг' -annotate +20+140 'Order ID: AX-2210-77' -annotate +20+210 'Total: 1249 RUB' "$T/ocr.png"
    : > "$T/notify.log"; rm -f "$T/clip"
    out="$(X_OCR_IMAGE="$T/ocr.png" bash "$O")"; rc=$?
    eq "ocr exit" "$rc" 0
    has "ocr russian"  "$out" 'Договор'
    has "ocr russian2" "$out" 'услуг'
    has "ocr english"  "$out" 'Order'
    has "ocr digits"   "$out" '2210'
    has "ocr clipboard" "$(cat "$T/clip" 2>/dev/null)" 'Order'
    has "ocr notify"   "$(cat "$T/notify.log")" 'Текст скопирован'
    has "ocr notify count" "$(cat "$T/notify.log")" 'символ'
    magick -size 400x120 xc:white "$T/blank.png"; : > "$T/notify.log"; rm -f "$T/clip"
    X_OCR_IMAGE="$T/blank.png" bash "$O" >/dev/null; eq "blank exit code" "$?" 3
    has "blank notify" "$(cat "$T/notify.log")" 'Текст не найден'
    [ ! -s "$T/clip" ] && ok || bad "blank must not touch clipboard"
    printf '{"tools":{"ocr":{"langs":"eng"}}}' > "$X_SETTINGS"; : > "$T/notify.log"
    X_OCR_IMAGE="$T/ocr.png" bash "$O" >/dev/null; has "langs setting honoured" "$(cat "$T/notify.log")" 'английский'
    printf '{"tools":{"ocr":{"langs":"xxx"}}}' > "$X_SETTINGS"; : > "$T/notify.log"
    X_OCR_IMAGE="$T/ocr.png" bash "$O" >/dev/null 2>&1; eq "missing language exit" "$?" 2
    has "missing language notify" "$(cat "$T/notify.log")" 'tesseract-data-xxx'
    # --json mode (used by the screenshot toolbar button): no notification, structured result
    rm -f "$X_SETTINGS"
    : > "$T/notify.log"; rm -f "$T/clip"
    J="$(X_OCR_IMAGE="$T/ocr.png" bash "$O" --json)"
    eq "json ok status" "$(jq -r .status <<<"$J")" ok
    has "json text" "$(jq -r .text <<<"$J")" 'Order'
    has "json message" "$(jq -r .message <<<"$J")" 'символов'
    eq "json mode sends no notification" "$(cat "$T/notify.log")" ''
    has "json mode copies" "$(cat "$T/clip")" 'Order'
    J="$(X_OCR_IMAGE="$T/blank.png" bash "$O" --json)"; eq "json empty status" "$(jq -r .status <<<"$J")" empty
    printf '{"tools":{"ocr":{"langs":"xxx"}}}' > "$X_SETTINGS"
    J="$(X_OCR_IMAGE="$T/ocr.png" bash "$O" --json)"; eq "json error status" "$(jq -r .status <<<"$J")" error
    has "json error message" "$(jq -r .message <<<"$J")" 'tesseract-data-xxx'
    rm -f "$X_SETTINGS"
else
    echo "SKIP ocr tests (tesseract/magick missing)"
fi

echo "tools_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
