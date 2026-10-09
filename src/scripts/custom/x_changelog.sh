#!/usr/bin/env bash
# serpantinum-x changelog helper: parses CHANGELOG.md into per-version sections and
# translates a section through the Gemini API (cached, degrades to the original text).
#
# usage: x_changelog.sh versions
#        x_changelog.sh get <version|latest|unreleased> [lang]
#
# env (all optional, mostly for tests):
#   SERPANTINUM_FORK_DIR / SERPANTINUM_FORK_REMOTE   repo to read CHANGELOG.md from
#   X_CHANGELOG_FILE        read this file instead of git
#   X_UPDATE_CACHE_DIR      translation cache dir
#   X_GEMINI_KEY_FILE, X_GEMINI_ENDPOINT, X_GEMINI_PROXY ("" = no proxy; default: settings.json ai.proxy, else none), X_GEMINI_MODELS ("a b")
#   X_UPDATE_SETTINGS       settings.json to read ai.proxy from
set -u

# Dev checkout only when SERPANTINUM_FORK_DIR is set or update.toml has channel=dev + fork_dir; otherwise
# the changelog comes from the install (FORK_DIR stays empty).
X_UPDATE_CONF="${X_UPDATE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/serpantinum-x/update.toml}"
x_conf_get() {   # x_conf_get <key>
    [ -f "$X_UPDATE_CONF" ] || return 0
    awk -F= -v k="$1" '{ key=$1; gsub(/[ \t]/, "", key) } key == k { v=$0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v); gsub(/^"|"$/, "", v); print v; exit }' "$X_UPDATE_CONF"
}
FORK_DIR="${SERPANTINUM_FORK_DIR:-}"
if [ -z "$FORK_DIR" ]; then
    case "${SERPANTINUM_UPDATE_CHANNEL:-$(x_conf_get channel)}" in
        dev|git) FORK_DIR="$(x_conf_get fork_dir)"; FORK_DIR="${FORK_DIR/#\~/$HOME}"; FORK_DIR="${FORK_DIR/#\$HOME/$HOME}" ;;
    esac
fi
INSTALL_DIR="${SERPANTINUM_INSTALL_DIR:-$HOME/.local/share/serpantinum}"
REMOTE="${SERPANTINUM_FORK_REMOTE:-origin}"
CACHE_DIR="${X_UPDATE_CACHE_DIR:-$HOME/.cache/serpantinum/x_update}"
GEMINI_KEY_FILE="${X_GEMINI_KEY_FILE:-$HOME/.config/serpantinum/secrets/gemini_key}"
GEMINI_ENDPOINT="${X_GEMINI_ENDPOINT:-https://generativelanguage.googleapis.com/v1beta/models}"
# Proxy is optional: X_GEMINI_PROXY ("" = none), else settings.json ai.proxy, else none.
SETTINGS_FILE="${X_UPDATE_SETTINGS:-${XDG_CONFIG_HOME:-$HOME/.config}/serpantinum/settings.json}"
GEMINI_PROXY="${X_GEMINI_PROXY-$(jq -r '.ai.proxy // empty' "$SETTINGS_FILE" 2>/dev/null)}"
read -r -a GEMINI_MODELS <<< "${X_GEMINI_MODELS:-gemini-flash-lite-latest gemini-3.6-flash}"

# shellcheck disable=SC1090
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

# --- source text ---------------------------------------------------------------------

changelog_text() {
    if [ -n "${X_CHANGELOG_FILE:-}" ]; then cat "$X_CHANGELOG_FILE" 2>/dev/null; return; fi
    [ -n "$FORK_DIR" ] || { cat "$INSTALL_DIR/CHANGELOG.md" 2>/dev/null; return; }
    git -C "$FORK_DIR" show "$REMOTE/master:CHANGELOG.md" 2>/dev/null \
        || git -C "$FORK_DIR" show "HEAD:CHANGELOG.md" 2>/dev/null
}

head_version() {
    if [ -z "$FORK_DIR" ]; then tr -d '[:space:]' < "$INSTALL_DIR/version.txt" 2>/dev/null; return; fi
    git -C "$FORK_DIR" show "HEAD:version.txt" 2>/dev/null | tr -d '[:space:]'
}
remote_version() { [ -n "$FORK_DIR" ] && git -C "$FORK_DIR" show "$REMOTE/master:version.txt" 2>/dev/null | tr -d '[:space:]'; }

commits_ahead() {
    [ -n "$FORK_DIR" ] || { echo 0; return; }
    git -C "$FORK_DIR" rev-list --count "HEAD..$REMOTE/master" 2>/dev/null || echo 0
}

# Raw "<version>\x1f<item>" lines from the markdown.
raw_items() {
    awk '
        /^### /        { v = substr($0, 5); sub(/[[:space:]]+$/, "", v); next }
        /^- /          { if (v != "") print v "\037" substr($0, 3); last = 1; next }
        /^[[:space:]]+[^[:space:]]/ { next }
    '
}

# JSON helpers (jq programs shared by the commands) ---------------------------------------

# items: array of strings -> array of {type, scope, text}
JQ_PARSE_ITEM='
def parse_item:
    . as $s
    | ([$s | capture("^(?<type>[A-Za-z]+(?:/[A-Za-z]+)*)(?:\\((?<scope>[^)]*)\\))?!?: (?<text>.*)$")] | .[0]) as $m
    | if $m then {type: ($m.type | ascii_downcase), scope: ($m.scope // ""), text: $m.text}
      else {type: "", scope: "", text: $s} end;
'

cmd_versions() {
    changelog_text | raw_items | jq -Rn "$JQ_PARSE_ITEM"'
        [inputs | split("\u001f") | {version: .[0], item: .[1]}]
        | reduce .[] as $r ([]; if (length > 0 and .[-1].version == $r.version)
              then .[-1].count += 1 else . + [{version: $r.version, count: 1}] end)'
}

section_items_json() {   # section_items_json <version> -> array of {type,scope,text}
    changelog_text | raw_items | jq -Rn --arg v "$1" "$JQ_PARSE_ITEM"'
        [inputs | split("\u001f") | select(.[0] == $v) | .[1] | parse_item]'
}

unreleased_items_json() {
    git -C "$FORK_DIR" log --format=%s "HEAD..$REMOTE/master" 2>/dev/null \
        | jq -Rn "$JQ_PARSE_ITEM"'[inputs | select(length > 0) | parse_item]'
}

resolve_target() {   # latest | unreleased | <version> -> prints key
    case "$1" in
        latest)
            local ahead hv rv
            ahead="$(commits_ahead)"; hv="$(head_version)"; rv="$(remote_version)"
            if [ "${ahead:-0}" -gt 0 ] && [ "$hv" = "$rv" ]; then echo unreleased
            else echo "${rv:-$hv}"; fi ;;
        *) echo "$1" ;;
    esac
}

# --- translation ---------------------------------------------------------------------

lang_name() {
    case "$1" in
        ru) echo Russian ;; uk) echo Ukrainian ;; de) echo German ;; fr) echo French ;;
        es) echo Spanish ;; it) echo Italian ;; pl) echo Polish ;; pt|pt_BR) echo Portuguese ;;
        zh*) echo Chinese ;; ja) echo Japanese ;; ko) echo Korean ;; tr) echo Turkish ;;
        *) echo "$1" ;;
    esac
}

# translate_texts <lang> <json array of strings> -> prints JSON array of strings or fails
# with a reason on fd 3 (written to $TRANSLATE_REASON_FILE).
TRANSLATE_REASON=""
translate_texts() {
    local lang="$1" texts="$2" key payload model resp out n
    if [ ! -s "$GEMINI_KEY_FILE" ]; then TRANSLATE_REASON=no_key; return 1; fi
    key="$(cat "$GEMINI_KEY_FILE")"
    if [ -n "$GEMINI_PROXY" ]; then
        local hostport="${GEMINI_PROXY#*://}"
        local host="${hostport%%:*}" port="${hostport##*:}"
        if ! timeout 1 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then TRANSLATE_REASON=proxy_down; return 1; fi
    fi
    n="$(jq 'length' <<< "$texts")"
    payload="$(jq -n --arg lang "$(lang_name "$lang")" --argjson texts "$texts" '
        {
            systemInstruction: {parts: [{text: (
                "You translate software changelog entries into " + $lang + ". " +
                "The user message is a JSON array of strings. Return a JSON array of exactly the same length " +
                "with each string translated, in the same order. Keep code spans, identifiers, file names, " +
                "version numbers and issue references like (#123) exactly as written. Use a natural, concise " +
                "technical style. Output only the JSON array."
            )}]},
            contents: [{parts: [{text: ($texts | tojson)}]}],
            generationConfig: {responseMimeType: "application/json", temperature: 0.2}
        }')"
    TRANSLATE_REASON=network
    for model in "${GEMINI_MODELS[@]}"; do
        local -a proxy_args=()
        [ -n "$GEMINI_PROXY" ] && proxy_args=(--proxy "$GEMINI_PROXY")
        resp="$(timeout 60 curl -sS -X POST "${proxy_args[@]}" -H "Content-Type: application/json" \
            --data "$payload" "$GEMINI_ENDPOINT/${model}:generateContent?key=${key}" 2>/dev/null)"
        xlog update debug "changelog gemini call model=$model response_bytes=${#resp}"
        [ -n "$resp" ] || { TRANSLATE_REASON=network; xlog update warn "changelog gemini: empty response (tunnel down?) model=$model"; continue; }
        out="$(jq -c '.candidates[0].content.parts[0].text // empty | fromjson' <<< "$resp" 2>/dev/null)"
        if [ -n "$out" ] && jq -e --argjson n "$n" 'type == "array" and length == $n and all(.[]; type == "string")' <<< "$out" >/dev/null 2>&1; then
            TRANSLATE_MODEL="$model"
            printf '%s' "$out"
            return 0
        fi
        local st; st="$(jq -r '.error.status // empty' <<< "$resp" 2>/dev/null)"
        xlog update warn "changelog gemini: unusable response model=$model api_status=${st:-none} bytes=${#resp}"
        if [ "$st" = "UNAVAILABLE" ]; then TRANSLATE_REASON=api_error; continue; fi
        if [ -n "$st" ]; then TRANSLATE_REASON=api_error; return 1; fi
        TRANSLATE_REASON=bad_response
    done
    return 1
}

TRANSLATE_MODEL=""

cmd_get() {
    local target lang key items texts sha cache cached out reason="" source="original" translated=false
    target="$(resolve_target "${1:-latest}")"
    lang="${2:-en}"
    if [ "$target" = "unreleased" ]; then items="$(unreleased_items_json)"; else items="$(section_items_json "$target")"; fi
    if [ -z "$items" ] || [ "$(jq 'length' <<< "$items")" = "0" ]; then
        xlog update warn "changelog get: no such version version=$target lang=$lang"
        jq -cn --arg v "$target" --arg l "$lang" \
            '{status:"error", code:"no_such_version", version:$v, lang:$l, source:"original", translated:false, count:0, items:[]}'
        return 1
    fi
    texts="$(jq -c '[.[].text]' <<< "$items")"
    out="$items"

    if [ "$lang" != "en" ]; then
        sha="$(printf '%s' "$texts" | sha256sum | cut -d' ' -f1)"
        mkdir -p "$CACHE_DIR" 2>/dev/null
        cache="$CACHE_DIR/changelog_${target}_${lang}.json"
        if [ -s "$cache" ] && [ "$(jq -r '.sha // empty' "$cache" 2>/dev/null)" = "$sha" ]; then
            cached="$(jq -c '.items' "$cache")"
            out="$(jq -c --argjson tr "$cached" 'to_entries | map(.value + {original: .value.text, text: $tr[.key]})' <<< "$items")"
            source=cache; translated=true
        elif tmp_tr="$(mktemp)"; translate_texts "$lang" "$texts" > "$tmp_tr"; trans="$(cat "$tmp_tr")"; rm -f "$tmp_tr"; [ -n "$trans" ]; then
            jq -cn --arg sha "$sha" --arg model "$TRANSLATE_MODEL" --argjson items "$trans" \
                '{sha:$sha, model:$model, items:$items}' > "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"
            out="$(jq -c --argjson tr "$trans" 'to_entries | map(.value + {original: .value.text, text: $tr[.key]})' <<< "$items")"
            source=gemini; translated=true
        else
            reason="$TRANSLATE_REASON"
            xlog update warn "changelog translation unavailable version=$target lang=$lang reason=$reason"
        fi
    fi
    if [ "$translated" != true ]; then
        out="$(jq -c 'map(. + {original: .text})' <<< "$items")"
    fi
    xlog update info "changelog get version=$target lang=$lang source=$source translated=$translated${reason:+ reason=$reason}"
    jq -cn --arg v "$target" --arg l "$lang" --arg src "$source" --arg reason "$reason" \
        --argjson tr "$translated" --argjson items "$out" \
        '{status:"ok", version:$v, lang:$l, source:$src, translated:$tr, reason:$reason, count:($items|length), items:$items}'
}

case "${1:-}" in
    versions) cmd_versions ;;
    get)      shift; cmd_get "$@" ;;
    *) echo "usage: x_changelog.sh {versions|get <version|latest|unreleased> [lang]}" >&2; exit 1 ;;
esac
