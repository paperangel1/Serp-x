#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Tests for x_keybinds.sh. Runs entirely in a throw-away fake HOME: never touches the
# real ~/.config, never calls hyprctl (X_KEYBINDS_NO_HYPRCTL=1).
#
# usage: keybinds_test.sh [path-to-hypr-config-to-copy]   (default: the neutral fixture keybinds/hypr)
set -u

HERE="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
XK="$HERE/../x_keybinds.sh"
SRC_HYPR="${1:-$HERE/keybinds/hypr}"

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
REAL_HOME="$HOME"
export HOME="$FAKE" X_KEYBINDS_NO_HYPRCTL=1
unset HYPR_CONFIG_DIR QS_SETTINGS
mkdir -p "$HOME/.config/serpantinum"
cp -r "$SRC_HYPR" "$HOME/.config/hypr"
SET="$HOME/.config/serpantinum/settings.json"
GEN="$HOME/.config/hypr/config/user_keybinds.lua"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

[[ "$HOME" != "$REAL_HOME" ]] || { echo "refusing: HOME is not faked"; exit 2; }

settings() { jq -c "$1" "$SET" > "$SET.t" && mv "$SET.t" "$SET"; }

# seed: settings like the live ones (two overrides, no custom)
cat > "$SET" <<'JSON'
{"hotkeys":{"custom":[],"overrides":[
 {"id":"ov_brave","name":"Brave","originalKeys":"SUPER + F","originalMods":["SUPER"],"originalKey":"F","kind":"exec_cmd","args":["brave"],"disabled":false,"newMods":["SUPER"],"newKey":"F"},
 {"id":"ov_tg","name":"Telegram","originalKeys":"SUPER + SHIFT + T","originalMods":["SUPER","SHIFT"],"originalKey":"T","kind":"exec_cmd","args":["/opt/tg/Telegram --"],"disabled":false,"newMods":["SUPER","SHIFT"],"newKey":"T"}]}}
JSON

echo "== generate --dry-run"
dry="$("$XK" generate --dry-run)"
check "dry-run has 2 unbinds"      "$(grep -c '^hl.unbind' <<<"$dry")" "2"
check "dry-run has brave rebind"   "$(grep -c 'exec_cmd("brave")' <<<"$dry")" "1"
check "dry-run valid Lua"          "$(printf '%s' "$dry" | lua -e 'assert(load(io.read("a")))' >/dev/null 2>&1 && echo yes || echo no)" "yes"
before="$(md5sum "$GEN" | cut -d' ' -f1)"; "$XK" generate --dry-run >/dev/null
check "dry-run does not write"     "$(md5sum "$GEN" | cut -d' ' -f1)" "$before"

echo "== orphans (the stale 'Yandex Music' -> termius bind)"
orph="$("$XK" orphans)"
check "one orphan"                 "$(jq length <<<"$orph")" "1"
check "orphan is Termius"          "$(jq -r '.[0].name' <<<"$orph")" "Termius"
check "orphan combo SUPER+SHIFT+S" "$(jq -r '.[0] | (.mods|join("+")) + "+" + .key' <<<"$orph")" "SUPER+SHIFT+S"
check "orphan command termius"     "$(jq -r '.[0].command' <<<"$orph")" "termius"

echo "== import orphans (what the tab does) then generate"
settings ".hotkeys.custom += $orph"
check "orphans idempotent (none left)" "$("$XK" orphans | jq length)" "0"
res="$("$XK" apply)"
check "apply ok"                   "$(jq -r .ok <<<"$res")" "true"
check "apply requirePresent"       "$(jq -r .requirePresent <<<"$res")" "true"
check "termius relabelled"         "$(grep -c 'description = "Termius"' "$GEN")" "1"
check "no 'Yandex Music' left"     "$(grep -c 'Yandex Music' "$GEN")" "0"
check "status inSync"              "$("$XK" status | jq -r .inSync)" "true"

echo "== custom exec / dispatcher presets / overrides"
settings '.hotkeys.custom += [
  {"id":"c1","name":"Term","mods":["SUPER","CTRL"],"key":"Return","command":"kitty","enabled":true},
  {"id":"c2","name":"Close","mods":["ALT"],"key":"F4","kind":"window.close","args":[],"enabled":true},
  {"id":"c3","name":"Float","mods":["SUPER"],"key":"V","kind":"window.float","args":[{"action":"toggle"}],"enabled":true},
  {"id":"c4","name":"Off","mods":["SUPER"],"key":"Y","command":"nope","enabled":false},
  {"id":"c5","name":"Vol","mods":[],"key":"XF86AudioRaiseVolume","command":"serpantinum volume raise","enabled":true,"locked":true,"repeating":true},
  {"id":"c6","name":"Shot","mods":[],"key":"Print","command":"serpantinum screenshot","enabled":true}]'
settings '.hotkeys.overrides += [
  {"id":"ov_off","name":"Закрыть","originalKeys":"SUPER + Q","originalMods":["SUPER"],"originalKey":"Q","kind":"window.close","args":[],"disabled":true,"newMods":[],"newKey":""},
  {"id":"ov_mv","name":"Move left","originalKeys":"SUPER + CTRL + Left","originalMods":["SUPER","CTRL"],"originalKey":"Left","kind":"window.move","args":[{"direction":"l"}],"disabled":false,"newMods":["SUPER","ALT"],"newKey":"H"}]'
out="$("$XK" generate --dry-run)"
has() { grep -qF -- "$1" <<<"$out" && echo yes || echo no; }
check "custom exec"                "$(has 'hl.bind("SUPER + CTRL + Return", hl.dsp.exec_cmd("kitty"), { description = "Term" })')" "yes"
check "dispatcher preset close"    "$(has 'hl.bind("ALT + F4", hl.dsp.window.close(), { description = "Close" })')" "yes"
check "dispatcher preset float"    "$(has 'hl.dsp.window.float({ action = "toggle" })')" "yes"
check "disabled custom skipped"    "$(has 'nope')" "no"
check "locked+repeating flags"     "$(has 'hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("serpantinum volume raise"), { locked = true, repeating = true')" "yes"
check "bare key combo"             "$(has 'hl.bind("Print"')" "yes"
check "disabled override = unbind only" "$(has 'hl.unbind("SUPER + Q")')" "yes"
check "disabled override not rebound"   "$(grep -c '"SUPER + Q"' <<<"$out")" "1"
check "moved override replays args" "$(has 'hl.bind("SUPER + ALT + H", hl.dsp.window.move({ direction = "l" })')" "yes"
check "all valid Lua"              "$(printf '%s' "$out" | lua -e 'assert(load(io.read("a")))' >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo "== hostile input is rejected / escaped, never executed"
settings '.hotkeys.custom += [
  {"id":"h1","name":"q\"uote","mods":["SUPER"],"key":"J","command":"echo \"a\\b\" 'x'\nrm -rf /","enabled":true},
  {"id":"h2","name":"bad combo","mods":["SUPER"],"key":"A\"); os.execute(\"x\"); (\"","command":"x","enabled":true},
  {"id":"h3","name":"bad kind","mods":["SUPER"],"key":"K","kind":"os.execute","args":["x"],"command":"","enabled":true},
  {"id":"h4","name":"inject mod","mods":["SUPER\"); os.exit() --"],"key":"L","command":"x","enabled":true}]'
out="$("$XK" generate --dry-run)"
check "hostile output still valid Lua"  "$(printf '%s' "$out" | lua -e 'assert(load(io.read("a")))' >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "bad combo rejected"        "$(has 'os.execute')" "no"
check "bad kind rejected"         "$(has 'hl.dsp.os')" "no"
check "inject mod rejected"       "$(has 'os.exit')" "no"
check "newline escaped (one line)" "$(grep -c '^rm -rf' <<<"$out")" "0"
# execute the generated chunk under a stub hl and make sure no os.* call happens
stub='local n=0; hl={bind=function() n=n+1 end, unbind=function() end, dsp=setmetatable({}, {__index=function(t,k) return setmetatable({}, {__index=function() return function() end end, __call=function() end}) end})}; os.execute=function() error("os.execute called") end; os.exit=function() error("os.exit called") end; assert(load(io.read("a")))(); print(n)'
check "executing generated Lua is inert" "$(printf '%s' "$out" | lua -e "$stub" 2>&1 | tail -1 | grep -E '^[0-9]+$' >/dev/null && echo yes || echo no)" "yes"

echo "== «Запустить команду…» hotkeys: names with quotes / spaces / unicode round-trip through Lua and sh"
if command -v node >/dev/null 2>&1 && command -v lua >/dev/null 2>&1; then
    QUOTE_JS="$HERE/../../../quickshell/custom/hotkeys/CmdQuote.js"
    names_json="$(jq -cn --arg nl $'строка1\nстрока2' '["Простая","Имя с пробелами","q\"uote","it'"'"'s","a$b `c` \\d $(x)","-dash","Ёлка 🎄 ёж","two  spaces","*glob* ?","semi; echo pwned", $nl, "'"'"'", "\\\\"]')"
    lines_json="$(NAMES="$names_json" node -e 'const fs=require("fs");eval(fs.readFileSync(process.argv[1],"utf8").replace(/^\.pragma.*$/m,""));console.log(JSON.stringify(JSON.parse(process.env.NAMES).map(runLine)))' "$QUOTE_JS")"
    check "node produced a line per name" "$(jq length <<<"$lines_json")" "$(jq length <<<"$names_json")"
    settings ".hotkeys.custom += ($lines_json | to_entries | map({id:(\"run\"+(.key|tostring)), name:\"run\", mods:[\"SUPER\",\"ALT\"], key:([\"A\",\"B\",\"C\",\"D\",\"E\",\"F\",\"G\",\"H\",\"I\",\"J\",\"K\",\"L\",\"M\"][.key]), command:.value, enabled:true}))"
    out="$("$XK" generate --dry-run)"
    check "run hotkeys: generated Lua is valid" "$(printf '%s' "$out" | lua -e 'assert(load(io.read("a")))' >/dev/null 2>&1 && echo yes || echo no)" "yes"
    CAP="$FAKE/cap"; mkdir -p "$CAP/bin"
    printf '#!/bin/sh\nprintf "%%s\\0" "$@" > "$CAP_DIR/args.$$"\n' > "$CAP/bin/serpantinum"; chmod +x "$CAP/bin/serpantinum"
    printf '%s' "$out" | CAP_DIR="$CAP" lua -e 'local n=0; local dir=os.getenv("CAP_DIR"); hl={bind=function() end, unbind=function() end, dsp=setmetatable({exec_cmd=function(c) n=n+1; local f=io.open(dir.."/cmd"..n,"w"); f:write(c); f:close(); return c end}, {__index=function() return setmetatable({}, {__index=function() return function() end end, __call=function() end}) end})}; assert(load(io.read("a")))()' >/dev/null 2>&1
    allok=yes
    runs=(); for f in $(ls "$CAP"/cmd* 2>/dev/null | sort -V); do grep -q '^serpantinum run ' "$f" && runs+=("$f"); done
    check "run hotkeys: one exec per name reached Lua" "${#runs[@]}" "$(jq length <<<"$names_json")"
    for idx in "${!runs[@]}"; do
        want="$(jq -j ".[$idx]" <<<"$names_json")"
        rm -f "$CAP"/args.*
        PATH="$CAP/bin:$PATH" CAP_DIR="$CAP" sh -c "$(cat "${runs[$idx]}")"
        mapfile -d '' -t got < <(cat "$CAP"/args.* 2>/dev/null)
        last="${got[${#got[@]}-1]-}"
        [[ "$last" == "$want" && "${got[0]-}" == "run" ]] || { allok=no; bad "run hotkey round-trip #$idx" "want [$want] got [${got[*]-}]"; }
    done
    check "run hotkeys: every name arrives as ONE argument, unchanged" "$allok" "yes"
    check "run hotkeys: no injection (nothing executed besides serpantinum)" "$(ls "$CAP" | grep -c pwned)" "0"
else
    echo "  skip  node or lua missing"
fi

echo "== ensure-require / apply / status"
sed -i '/config\/user_keybinds/d' "$HOME/.config/hypr/hyprland.lua"
st="$("$XK" status)"
check "status: require missing"    "$(jq -r .requirePresent <<<"$st")" "false"
res="$("$XK" apply)"
check "apply without flag leaves hyprland.lua alone" "$(grep -c 'config/user_keybinds' "$HOME/.config/hypr/hyprland.lua")" "0"
check "apply reports requirePresent=false" "$(jq -r .requirePresent <<<"$res")" "false"
res="$("$XK" apply --ensure-require)"
check "apply --ensure-require ok"  "$(jq -r .ok <<<"$res")" "true"
check "require line added once"    "$(grep -c 'config/user_keybinds' "$HOME/.config/hypr/hyprland.lua")" "1"
"$XK" ensure-require; check "ensure-require idempotent" "$(grep -c 'config/user_keybinds' "$HOME/.config/hypr/hyprland.lua")" "1"
check "backup of hyprland.lua made" "$([[ -f "$HOME/.config/hypr/hyprland.lua.serpantinum.bak" ]] && echo yes || echo no)" "yes"
check "status inSync after apply"  "$("$XK" status | jq -r .inSync)" "true"

echo "== list carries src"
lst="$("$XK" list)"
check "list has shipped + generated" "$(jq -r '[.[].src] | unique | join(",")' <<<"$lst")" "config/keybinds.lua,config/user_keybinds.lua"

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
