#!/usr/bin/env bash
#
# serpantinum-x: user-defined Hyprland keybinds on top of the shipped Lua config.
#
# Source of truth is the "hotkeys" section of settings.json (hotkeys.custom[] and
# hotkeys.overrides[]). This script never touches the shell-managed
# config/keybinds.lua; it only generates config/user_keybinds.lua and (on explicit
# request) makes sure hyprland.lua requires it.
#
# Subcommands (all machine output is JSON on stdout):
#   list                      parsed Lua binds (with `src`) cross-referenced with hyprctl
#   generate [--dry-run]      write config/user_keybinds.lua (or print it with --dry-run)
#   apply [--ensure-require]  generate + reload + configerrors  -> {ok, ...}
#   status                    health report for the UI / doctor
#   orphans                   generated binds that settings.json does not know about,
#                             as ready-to-store hotkeys.custom[] entries (read-only)
#   ensure-require            add `pcall(require, "config/user_keybinds")` to hyprland.lua
#   reload | errors           hyprctl reload config-only / hyprctl configerrors
#
# Environment (tests): run with a fake HOME (settings live at $HOME/.config/serpantinum/
# settings.json -- caching.sh forces QS_SETTINGS from HOME), HYPR_CONFIG_DIR for the hypr
# tree, and X_KEYBINDS_NO_HYPRCTL=1 (never calls hyprctl: reload/errors/binds skipped).
#

# config.sh -> caching.sh reassigns SCRIPT_DIR, so keep our own directory variable.
XK_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
source "$XK_DIR/../config.sh"
# shellcheck disable=SC1090
. "$XK_DIR/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

HYPR_DIR="${HYPR_CONFIG_DIR:-$HOME/.config/hypr}"
HYPR_ENTRY="$HYPR_DIR/hyprland.lua"
GEN_FILE="$HYPR_DIR/config/user_keybinds.lua"
REQUIRE_MARKER='config/user_keybinds'
REQUIRE_LINE='pcall(require, "config/user_keybinds")'
NO_HYPRCTL="${X_KEYBINDS_NO_HYPRCTL:-0}"

# ---------------------------------------------------------------------------
# jq building blocks
# ---------------------------------------------------------------------------
# Escaping contract: value travels  QML string -> JSON -> jq -> Lua string literal ->
# Hyprland -> /bin/sh.  Only "jq -> Lua literal" needs work here (lua_str).
# Combos are validated against a whitelist and REJECTED (never sanitised); dispatcher
# kinds against the exact set of real hl.dsp leaves (enumerated from a live Hyprland).

read -r -d '' JQ_COMMON <<'JQ'
def lua_str:
  tostring
  | gsub("\\\\"; "\\\\")
  | gsub("\""; "\\\"")
  | gsub("\n"; "\\n")
  | gsub("\r"; "\\r")
  | gsub("\t"; "\\t")
  | "\"" + . + "\"";

def lua_key($k):
  if ($k | test("^[A-Za-z_][A-Za-z0-9_]*$")) then $k
  else "[" + ($k | lua_str) + "]"
  end;

def json_to_lua:
  if type == "string" then lua_str
  elif type == "number" or type == "boolean" then tostring
  elif type == "null" then "nil"
  elif type == "array" then "{ " + (map(json_to_lua) | join(", ")) + " }"
  elif type == "object" then
    "{ " + (to_entries | map(lua_key(.key) + " = " + (.value | json_to_lua)) | join(", ")) + " }"
  else "nil"
  end;

def valid_kind:
  . as $k
  | ["cursor.move","cursor.move_to_corner","dpms","event","exec_cmd","exec_raw",
     "exit","focus","force_idle","force_renderer_reload","global",
     "group.active","group.lock","group.lock_active","group.move_window",
     "group.next","group.prev","group.toggle","layout","no_op","pass",
     "release_input_capture","send_key_state","send_shortcut","submap",
     "window.alter_zorder","window.bring_to_top","window.center",
     "window.clear_tags","window.close","window.cycle_next",
     "window.deny_from_group","window.drag","window.float","window.fullscreen",
     "window.fullscreen_state","window.kill","window.move","window.pin",
     "window.pseudo","window.resize","window.set_prop","window.signal",
     "window.swap","window.tag","window.toggle_swallow",
     "workspace.change_id","workspace.move","workspace.rename",
     "workspace.swap_monitors","workspace.toggle_special"]
  | index($k) != null;

def modbit: { "SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64 };
def maskof($mods): ($mods // []) | map(modbit[.] // 0) | add // 0;
def mods_from_mask($m): ["SUPER","CTRL","ALT","SHIFT"] | map(select(($m / (modbit[.]) | floor) % 2 == 1));
def combo_of($mods; $key): (($mods // []) + [($key // "")]) | map(select(. != "")) | join(" + ");
def ident($mask; $key): "\($mask)|\($key | ascii_downcase)";

def opts_of: [ (if .locked then "locked = true" else empty end),
               (if .repeating then "repeating = true" else empty end),
               ("description = " + ((.name // "") | lua_str)) ]
             | "{ " + join(", ") + " }";

def action_lua:
  if ((.kind // "") | length) > 0 and (.kind | valid_kind)
  then "hl.dsp." + .kind + "(" + ((.args // []) | map(json_to_lua) | join(", ")) + ")"
  else "hl.dsp.exec_cmd(" + ((.command // "") | lua_str) + ")"
  end;
JQ

# hotkeys.overrides[]: always unbind the original key ...
read -r -d '' JQ_UNBIND <<'JQ'
(.hotkeys.overrides // [])
| map(select((.originalKeys // "") | length > 0))
| .[]
| "hl.unbind(" + (.originalKeys | lua_str) + ")"
JQ

# ... hotkeys.custom[]: user-added binds (exec_cmd, or a vetted dispatcher kind+args)
read -r -d '' JQ_CUSTOM <<'JQ'
(.hotkeys.custom // [])
| map(select(
      (.enabled != false)
      and ((.key // "") | length > 0)
      and (combo_of(.mods; .key) | test("^[A-Za-z0-9_+: ]+$"))
      and ( (((.kind // "") | length) > 0 and (.kind | valid_kind))
            or ((.command // "") | length > 0) )
  ))
| .[]
| "hl.bind(" + (combo_of(.mods; .key) | lua_str) + ", " + action_lua + ", " + opts_of + ")"
JQ

# ... and moved/changed overrides replay the original (or edited) dispatcher on the new key.
read -r -d '' JQ_OVERRIDE_BIND <<'JQ'
(.hotkeys.overrides // [])
| map(select(
      (.disabled != true)
      and ((.newKey // "") | length > 0)
      and (combo_of(.newMods; .newKey) | test("^[A-Za-z0-9_+: ]+$"))
      and ((.kind // "") | valid_kind)
  ))
| .[]
| "hl.bind(" + (combo_of(.newMods; .newKey) | lua_str) + ", " + action_lua + ", " + opts_of + ")"
JQ

jq_run() {   # jq_run RAW_FLAG PROGRAM [files...]
    local raw="$1" prog="$2"; shift 2
    jq $raw "$JQ_COMMON"$'\n'"$prog" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

emit_lua() {
    printf '%s\n' \
        '-- AUTOGENERATED BY SERPANTINUM -- DO NOT EDIT' \
        '-- Source of truth: ~/.config/serpantinum/settings.json ("hotkeys" section)' \
        '-- Regenerate from the Hotkeys tab of the settings, or: x_keybinds.sh apply' \
        ''
    # Unbinds first: a moved override must never race the shipped bind it replaces.
    jq_run -r "$JQ_UNBIND" "$CONFIG_SETTINGS_JSON"
    jq_run -r "$JQ_CUSTOM" "$CONFIG_SETTINGS_JSON"
    jq_run -r "$JQ_OVERRIDE_BIND" "$CONFIG_SETTINGS_JSON"
}

cmd_generate() {
    local dry=0
    [[ "${1:-}" == "--dry-run" ]] && dry=1
    _config_ensure_settings

    if (( dry )); then
        emit_lua
        return 0
    fi

    [[ -d "$HYPR_DIR/config" ]] || { echo "no hyprland config dir at $HYPR_DIR/config" >&2; return 1; }

    local tmp="${GEN_FILE}.tmp.$$"
    emit_lua > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        echo "generate: empty output, aborting" >&2
        return 1
    fi
    if ! lua -e "assert(loadfile('$tmp'))" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "generate: generated file failed Lua syntax check, aborting" >&2
        return 1
    fi
    mv "$tmp" "$GEN_FILE"
}

# ---------------------------------------------------------------------------
# require line / reload / errors
# ---------------------------------------------------------------------------

require_present() {
    [[ -f "$HYPR_ENTRY" ]] && grep -qF "$REQUIRE_MARKER" "$HYPR_ENTRY"
}

# Only ever run on explicit user action (never at startup): it edits hyprland.lua.
cmd_ensure_require() {
    [[ -f "$HYPR_ENTRY" ]] || { echo "no hyprland.lua at $HYPR_ENTRY" >&2; return 1; }
    require_present && return 0
    cp -p "$HYPR_ENTRY" "$HYPR_ENTRY.serpantinum.bak"
    printf '\n%s\n' "$REQUIRE_LINE" >> "$HYPR_ENTRY"
    xlog hotkeys info "ensure-require: added the user_keybinds require line to hyprland.lua (backup .serpantinum.bak)"
}

cmd_reload() {
    [[ "$NO_HYPRCTL" == "1" ]] && return 0
    hyprctl reload config-only >/dev/null 2>&1
}

cmd_errors() {
    [[ "$NO_HYPRCTL" == "1" ]] && return 0
    hyprctl configerrors 2>/dev/null
}

# ---------------------------------------------------------------------------
# apply  -> {"ok":bool,"stage":..,"error":..,"requirePresent":bool}
# ---------------------------------------------------------------------------

apply_result() {   # apply_result OK STAGE ERROR
    jq -cn --argjson ok "$1" --arg stage "$2" --arg error "$3" \
           --argjson req "$(require_present && echo true || echo false)" \
        '{ok:$ok, stage:$stage, error:$error, requirePresent:$req}'
}

cmd_apply() {
    local want_require=0 err t0
    [[ "${1:-}" == "--ensure-require" ]] && want_require=1
    t0=$(date +%s%3N)
    xlog hotkeys info "apply start ensure_require=$want_require hyprctl=$([[ "$NO_HYPRCTL" == "1" ]] && echo off || echo on)"

    if ! err="$(cmd_generate 2>&1)"; then
        xlog hotkeys error "apply failed stage=generate error=$(printf '%s' "$err" | head -c 300)"
        apply_result false generate "$err"; return 1
    fi
    if (( want_require )) && ! err="$(cmd_ensure_require 2>&1)"; then
        xlog hotkeys error "apply failed stage=require error=$(printf '%s' "$err" | head -c 300)"
        apply_result false require "$err"; return 1
    fi
    cmd_reload
    err="$(cmd_errors)"
    if [[ -n "${err//[[:space:]]/}" ]]; then
        xlog hotkeys error "apply failed stage=config hyprctl configerrors: $(printf '%s' "$err" | tr '\n' ' ' | head -c 400)"
        apply_result false config "$err"; return 1
    fi
    xlog hotkeys info "apply ok ms=$(( $(date +%s%3N) - t0 )) binds_file=$([[ -f "$GEN_FILE" ]] && echo present || echo missing) require_present=$(require_present && echo yes || echo no)"
    apply_result true done ""
}

# ---------------------------------------------------------------------------
# list / status / orphans
# ---------------------------------------------------------------------------

introspect() {
    local parsed
    parsed="$(timeout 5 lua "$XK_DIR/hypr_introspect.lua" "$HYPR_DIR" 2>/dev/null)"
    if [[ -n "$parsed" ]] && echo "$parsed" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$parsed"
    else
        printf '[]'
    fi
}

cmd_list() {
    local parsed hyprbinds="[]"
    parsed="$(introspect)"
    if [[ "$NO_HYPRCTL" != "1" ]]; then
        hyprbinds="$(timeout 3 hyprctl binds -j 2>/dev/null)"
        [[ -n "$hyprbinds" ]] && echo "$hyprbinds" | jq -e . >/dev/null 2>&1 || hyprbinds="[]"
    fi

    jq -n --argjson parsed "$parsed" --argjson live "$hyprbinds" '
      def nk: ascii_downcase
        | if . == "enter" then "return"
          elif . == "esc" then "escape"
          elif . == "page_up" or . == "pgup" then "prior"
          elif . == "page_down" or . == "pgdn" then "next"
          else . end;
      ($live | map({ key: ("\(.modmask)|" + (.key|nk)), value: . }) | from_entries) as $lm
      | $parsed
      | map(. + { live: ($lm[("\(.modmask)|" + (.key|nk))] != null) })
    '
}

cmd_status() {
    local hypr=false req=false exists=false sync=false errs=""
    command -v hyprctl >/dev/null 2>&1 && [[ -d "$HYPR_DIR" ]] && hypr=true
    require_present && req=true
    [[ -f "$GEN_FILE" ]] && exists=true
    if [[ "$exists" == true ]] && [[ "$(emit_lua)" == "$(cat "$GEN_FILE")" ]]; then sync=true; fi
    errs="$(cmd_errors)"
    jq -cn --argjson hypr "$hypr" --argjson req "$req" --argjson ex "$exists" \
           --argjson sync "$sync" --arg errs "$errs" --arg dir "$HYPR_DIR" \
        '{hyprland:$hypr, hyprDir:$dir, requirePresent:$req, generatedExists:$ex, inSync:$sync, configErrors:$errs}'
}

# Binds that sit in the generated file but that settings.json knows nothing about
# (e.g. entries lost through an old bug). Returned as hotkeys.custom[] entries so the
# UI can store them through the normal Config path; this command never writes.
_orphans_json() {
    _config_ensure_settings
    jq -n --argjson binds "$(introspect)" --slurpfile st "$CONFIG_SETTINGS_JSON" "$JQ_COMMON"'
      ($st[0].hotkeys // {}) as $h
      | ( [ ($h.custom // [])[]    | ident(maskof(.mods); .key) ]
        + [ ($h.overrides // [])[] | select(.disabled != true) | ident(maskof(.newMods); .newKey) ] ) as $known
      | [ $binds[]
          | select(.src | endswith("user_keybinds.lua"))
          | select(ident(.modmask; .key) as $i | ($known | index($i)) == null)
          | select(.kind == "exec_cmd" and ((.args[0] // "") | type == "string" and length > 0))
          | (.args[0]) as $cmd
          | ($cmd | split(" ")[0] | split("/") | last) as $base
          | {
              id: ("hk_import_" + ((.modmask | tostring) + "_" + (.key | ascii_downcase) | gsub("[^a-z0-9_]"; "_"))),
              name: (($base | .[0:1] | ascii_upcase) + ($base | .[1:])),
              mods: mods_from_mask(.modmask),
              key: .key,
              type: "command",
              command: $cmd,
              desktopId: "",
              enabled: true,
              locked: (.opts.locked // false),
              repeating: (.opts.repeating // false),
              imported: true
            } ]
    '
}

cmd_orphans() {
    local o
    o="$(_orphans_json)"
    xlog hotkeys info "orphans found=$(jq 'length' <<<"$o" 2>/dev/null || echo '?')"
    printf '%s\n' "$o"
}

case "${1:-}" in
    list)           cmd_list ;;
    generate)       shift; cmd_generate "$@" ;;
    apply)          shift; cmd_apply "$@" ;;
    status)         cmd_status ;;
    orphans)        cmd_orphans ;;
    ensure-require) cmd_ensure_require ;;
    reload)         cmd_reload ;;
    errors)         cmd_errors ;;
    *)
        echo "usage: x_keybinds.sh {list|generate [--dry-run]|apply [--ensure-require]|status|orphans|ensure-require|reload|errors}" >&2
        exit 1
        ;;
esac
