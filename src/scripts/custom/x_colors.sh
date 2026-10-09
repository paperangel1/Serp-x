#!/usr/bin/env bash
# x_colors.sh: colour history + format helpers for the colour picker.
#
#   x_colors.sh add <#RRGGBB>            push to history (dedupe, newest first, trimmed)
#   x_colors.sh list                     JSON: [{"hex":"#RRGGBB","ts":<unix>}, ...]
#   x_colors.sh clear
#   x_colors.sh format <#RRGGBB> <hex|rgb|hsl>
#   x_colors.sh copy <#RRGGBB> [hex|rgb|hsl]   format + put into the clipboard + add to history
#
# Store: $X_COLORS_FILE or ~/.local/state/serpantinum/x_colors.json (max $X_COLORS_MAX, default 30).
# Test hook: X_COPY_CMD replaces wl-copy.

STATE_DIR="${QS_STATE_DIR:-$HOME/.local/state/serpantinum}"
FILE="${X_COLORS_FILE:-$STATE_DIR/x_colors.json}"
MAX="${X_COLORS_MAX:-30}"
COPY_CMD="${X_COPY_CMD:-wl-copy}"

# shellcheck disable=SC1090
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

norm_hex() {   # -> upper-case #RRGGBB or fail
    local h="${1#\#}"
    [[ "$h" =~ ^[0-9a-fA-F]{6}$ ]] || return 1
    printf '#%s' "${h^^}"
}

read_store() {
    [ -s "$FILE" ] && jq -c 'if type == "array" then . else [] end' "$FILE" 2>/dev/null || echo '[]'
}

write_store() {   # stdin -> atomic write
    mkdir -p "$(dirname "$FILE")" || return 1
    local tmp="$FILE.tmp.$$"
    cat > "$tmp" && mv -f "$tmp" "$FILE"
}

fmt() {   # fmt <#RRGGBB> <kind>
    local h="${1#\#}" r g b
    r=$((16#${h:0:2})); g=$((16#${h:2:2})); b=$((16#${h:4:2}))
    case "$2" in
        rgb) printf 'rgb(%d, %d, %d)' "$r" "$g" "$b" ;;
        hsl)
            awk -v r="$r" -v g="$g" -v b="$b" 'BEGIN {
                r/=255; g/=255; b/=255
                mx=(r>g?r:g); mx=(mx>b?mx:b); mn=(r<g?r:g); mn=(mn<b?mn:b)
                l=(mx+mn)/2; d=mx-mn; h=0; s=0
                if (d>0) {
                    s=(l>0.5)?d/(2-mx-mn):d/(mx+mn)
                    if (mx==r) h=(g-b)/d+(g<b?6:0)
                    else if (mx==g) h=(b-r)/d+2
                    else h=(r-g)/d+4
                    h*=60
                }
                printf "hsl(%d, %d%%, %d%%)", h+0.5, s*100+0.5, l*100+0.5
            }' ;;
        *) printf '#%s' "${h^^}" ;;
    esac
}

case "${1:-}" in
    add)
        hex="$(norm_hex "$2")" || { xlog tools warn "colors add: bad colour value"; echo "x_colors: bad colour '$2'" >&2; exit 1; }
        read_store | jq -c --arg h "$hex" --argjson ts "$(date +%s)" --argjson max "$MAX" \
            '[{hex:$h, ts:$ts}] + map(select(.hex != $h)) | .[:$max]' | write_store
        xlog tools info "colors added hex=$hex store_rc=${PIPESTATUS[2]} items=$(read_store | jq 'length' 2>/dev/null)"
        ;;
    list) read_store ;;
    clear) echo '[]' | write_store; xlog tools info "colors history cleared" ;;
    format)
        hex="$(norm_hex "$2")" || { echo "x_colors: bad colour '$2'" >&2; exit 1; }
        fmt "$hex" "${3:-hex}"; echo
        ;;
    copy)
        hex="$(norm_hex "$2")" || { echo "x_colors: bad colour '$2'" >&2; exit 1; }
        out="$(fmt "$hex" "${3:-hex}")"
        printf '%s' "$out" | "$COPY_CMD"
        xlog tools "$([ "${PIPESTATUS[1]}" -eq 0 ] && echo info || echo warn)" "colors copy format=${3:-hex} copy_rc=${PIPESTATUS[1]}"
        "$0" add "$hex"
        printf '%s\n' "$out"
        ;;
    *) echo "usage: x_colors.sh {add|list|clear|format|copy} ..." >&2; exit 1 ;;
esac
