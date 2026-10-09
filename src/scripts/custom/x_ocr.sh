#!/usr/bin/env bash
# x_ocr.sh: recognise text in a screen region and put it into the clipboard.
#
#   x_ocr.sh [--geometry "x,y WxH"] [--json]   no geometry -> pick a region with slurp
#   --json: no notification, print {"status":"ok|empty|error", ...} (used by the screenshot-toolbar button)
#
# Settings (settings.json -> tools.ocr): langs ("rus+eng"), joinLines (false).
# Test hooks: X_OCR_IMAGE=<png> skips grim; X_COPY_CMD / X_NOTIFY_CMD replace wl-copy / notify-send.

SETTINGS="${X_SETTINGS:-$HOME/.config/serpantinum/settings.json}"
COPY_CMD="${X_COPY_CMD:-wl-copy}"
NOTIFY_CMD="${X_NOTIFY_CMD:-notify-send}"

# shellcheck disable=SC1090
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

JSON=0
notify() {   # notify <title> <body> [icon]; in --json mode errors are reported on stdout instead
    if [ "$JSON" = 1 ]; then
        jq -cn --arg t "$1" --arg b "$2" '{status:"error", title:$t, message:$b}'
    else
        "$NOTIFY_CMD" -a "Serpantinum" -i "${3:-edit-copy}" "$1" "$2" 2>/dev/null
    fi
}

setting() {   # setting <jq path> <default>
    local v
    v="$(jq -r "$1 // empty" "$SETTINGS" 2>/dev/null)"
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

GEOM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --geometry) GEOM="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        *) shift ;;
    esac
done

xlog tools info "ocr start geometry=$([ -n "$GEOM" ] && echo given || echo slurp) json=$JSON"
command -v tesseract >/dev/null 2>&1 || { xlog tools error "ocr: tesseract is not installed"; notify "Не установлен tesseract" "Установите пакеты: tesseract tesseract-data-rus tesseract-data-eng" dialog-warning; exit 2; }

LANGS="$(setting '.tools.ocr.langs' 'rus+eng')"
JOIN="$(setting '.tools.ocr.joinLines' 'false')"

for l in ${LANGS//+/ }; do
    tesseract --list-langs 2>/dev/null | grep -qx "$l" || { xlog tools error "ocr: language data missing lang=$l"; notify "Нет языка распознавания: $l" "Установите пакет tesseract-data-$l" dialog-warning; exit 2; }
done

TMP="$(mktemp --suffix=.png)"
trap 'rm -f "$TMP"' EXIT

if [ -n "${X_OCR_IMAGE:-}" ]; then
    cp "$X_OCR_IMAGE" "$TMP"
else
    if [ -z "$GEOM" ]; then
        command -v slurp >/dev/null 2>&1 || { xlog tools error "ocr: slurp is not installed"; notify "Не установлен slurp" "Нужен для выбора области" dialog-warning; exit 2; }
        GEOM="$(slurp -d 2>/dev/null)" || { xlog tools info "ocr: selection cancelled"; exit 1; }
        [ -n "$GEOM" ] || { xlog tools info "ocr: empty selection"; exit 1; }
    fi
    grim -g "$GEOM" "$TMP" 2>/dev/null || { xlog tools error "ocr: grim capture failed geometry=$GEOM"; notify "Не удалось сделать снимок" "grim завершился с ошибкой" dialog-error; exit 1; }
fi

# Upscaling + grayscale noticeably improves recognition of small UI text.
if command -v magick >/dev/null 2>&1; then
    magick "$TMP" -colorspace Gray -resize 200% "$TMP" 2>/dev/null
fi

T0=$(date +%s%3N)
TEXT="$(tesseract "$TMP" stdout -l "$LANGS" --psm 6 2>/dev/null)"
TRC=$?
xlog tools "$([ "$TRC" -eq 0 ] && echo info || echo warn)" "ocr tesseract rc=$TRC langs=$LANGS raw_chars=${#TEXT} ms=$(( $(date +%s%3N) - T0 ))"
TEXT="$(printf '%s' "$TEXT" | sed -e 's/[[:space:]]*$//' | cat -s)"
TEXT="$(printf '%s' "$TEXT" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [ "$JOIN" = "true" ]; then
    TEXT="$(printf '%s\n' "$TEXT" | awk 'BEGIN{RS="";ORS="\n\n"}{gsub(/[ \t]*\n[ \t]*/," ");print}' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
fi

if [ -z "${TEXT//[[:space:]]/}" ]; then
    xlog tools warn "ocr: empty result (no recognisable text in the region)"
    if [ "$JSON" = 1 ]; then jq -cn '{status:"empty", title:"Текст не найден", message:"В выбранной области нет распознаваемого текста"}'
    else notify "Текст не найден" "В выбранной области нет распознаваемого текста" dialog-information; fi
    exit 3
fi

printf '%s' "$TEXT" | "$COPY_CMD"
N="$(printf '%s' "$TEXT" | wc -m)"
xlog tools info "ocr copied chars=$N langs=$LANGS join=$JOIN"
case "$LANGS" in
    rus+eng|eng+rus) LABEL="русский + английский" ;;
    rus) LABEL="русский" ;;
    eng) LABEL="английский" ;;
    *) LABEL="$LANGS" ;;
esac
if [ "$JSON" = 1 ]; then
    jq -cn --arg t "$TEXT" --argjson n "$N" --arg l "$LABEL" '{status:"ok", title:"Текст скопирован в буфер", message:"\($n) символов · \($l)", chars:$n, text:$t}'
else
    notify "Текст скопирован в буфер" "$N символов · $LABEL"
    printf '%s\n' "$TEXT"
fi
