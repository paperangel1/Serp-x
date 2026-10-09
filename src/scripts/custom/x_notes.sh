#!/usr/bin/env bash
# x_notes.sh: markdown notes folder helper for the quick-notes corner.
#
#   x_notes.sh dir                    print the notes directory (created if missing)
#   x_notes.sh list                   JSON: [{"path","name","title","preview","mtime"}], newest first
#   x_notes.sh latest                 JSON of the newest note or {}
#   x_notes.sh new [title]            create an empty note, print its path
#   x_notes.sh trash <path>           move a note to the freedesktop trash (only inside the notes dir)
#
# Notes dir: settings.json tools.notes.dir, default ~/Notes. Plain *.md files, no database.

SETTINGS="${X_SETTINGS:-$HOME/.config/serpantinum/settings.json}"

# shellcheck disable=SC1090
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

notes_dir() {
    local d
    d="$(jq -r '.tools.notes.dir // empty' "$SETTINGS" 2>/dev/null)"
    [ -n "$d" ] || d="$HOME/Notes"
    d="${d/#\~/$HOME}"
    mkdir -p "$d" 2>/dev/null || xlog tools error "notes: cannot create notes dir"
    [ -w "$d" ] || xlog tools warn "notes: notes dir is not writable"
    printf '%s' "$d"
}

DIR="$(notes_dir)"

title_of() {   # first markdown heading or first non-empty line, else file name without extension
    local f="$1" t
    t="$(grep -m1 -E '^#+[[:space:]]+' "$f" 2>/dev/null | sed -E 's/^#+[[:space:]]+//')"
    [ -n "$t" ] || t="$(grep -m1 -E '[^[:space:]]' "$f" 2>/dev/null)"
    [ -n "$t" ] || t="$(basename "${f%.md}")"
    printf '%s' "${t:0:80}"
}

list_json() {
    local f
    while IFS= read -r -d '' f; do
        jq -n --arg path "$f" --arg name "$(basename "$f")" --arg title "$(title_of "$f")" \
              --arg preview "$(head -c 400 "$f" 2>/dev/null)" --argjson mtime "$(stat -c %Y "$f")" \
              '{path:$path, name:$name, title:$title, preview:$preview, mtime:$mtime}'
    done < <(find "$DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null) | jq -s -c 'sort_by(-.mtime)'
}

case "${1:-}" in
    dir) printf '%s\n' "$DIR" ;;
    list) list_json ;;
    latest) list_json | jq -c '.[0] // {}' ;;
    new)
        base="$(date '+%Y-%m-%d %H-%M')"
        f="$DIR/$base.md"; n=2
        while [ -e "$f" ]; do f="$DIR/$base ($n).md"; n=$((n + 1)); done
        if [ -n "$2" ]; then printf '# %s\n\n' "$2" > "$f"; else : > "$f"; fi
        xlog tools info "notes new file=$(basename "$f") titled=$([ -n "$2" ] && echo yes || echo no) rc=$([ -f "$f" ] && echo 0 || echo 1)"
        printf '%s\n' "$f"
        ;;
    trash)
        p="$(realpath -m -- "$2")"
        case "$p" in "$DIR"/*.md) ;; *) xlog tools warn "notes trash refused: path outside the notes dir"; echo "x_notes: refusing to touch '$2' (outside notes dir)" >&2; exit 1 ;; esac
        [ -f "$p" ] || { xlog tools warn "notes trash: file not found"; exit 1; }
        if command -v gio >/dev/null 2>&1; then gio trash "$p"; else rm -f -- "$p"; fi
        xlog tools "$([ ! -e "$p" ] && echo info || echo error)" "notes trash file=$(basename "$p") gone=$([ ! -e "$p" ] && echo yes || echo no)"
        ;;
    *) echo "usage: x_notes.sh {dir|list|latest|new [title]|trash <path>}" >&2; exit 1 ;;
esac
