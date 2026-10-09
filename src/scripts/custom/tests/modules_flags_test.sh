#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# G10: module flags (~/.config/serpantinum-x/modules.json). Logic is tested with node on the real modules.js,
# the QML wiring statically. Nothing outside a temp dir is touched.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
C="$ROOT/src/quickshell/custom"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; else fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; fi; }

# the library pragma is not valid plain JS: drop it
sed '1{/^\.pragma/d}' "$C/modules.js" > "$T/modules.cjs"
echo 'module.exports = { parse, isEnabled };' >> "$T/modules.cjs"
js() { node -e "const m=require('$T/modules.cjs'); $1"; }

if command -v node >/dev/null 2>&1; then
    check "missing file (null) -> everything enabled"  '[ "$(js "console.log(m.isEnabled(m.parse(null),\"ocr\"))")" = true ]'
    check "enabled list is honoured"                    '[ "$(js "const l=m.parse(JSON.stringify({enabled:[\"tools\"]})); console.log(m.isEnabled(l,\"tools\"), m.isEnabled(l,\"ocr\"), m.isEnabled(l,\"vpn\"))")" = "true false false" ]'
    check "core is always on"                           '[ "$(js "console.log(m.isEnabled(m.parse(\"{\\\"enabled\\\":[]}\"),\"core\"))")" = true ]'
    check "empty enabled list disables optional ones"   '[ "$(js "console.log(m.isEnabled(m.parse(\"{\\\"enabled\\\":[]}\"),\"tools\"))")" = false ]'
    check "garbage / wrong shape -> everything enabled" '[ "$(js "console.log(m.isEnabled(m.parse(\"nope\"),\"ocr\"), m.isEnabled(m.parse(\"{\\\"enabled\\\":5}\"),\"ocr\"), m.isEnabled(m.parse(\"[]\"),\"ocr\"))")" = "true true true" ]'
else
    echo "  node not installed: logic checks skipped"
fi

check "XModules singleton registered in qmldir"  'grep -q "^singleton XModules 1.0 XModules.qml" "$C/qmldir"'
check "XModules reads ~/.config/serpantinum-x/modules.json" 'grep -q "serpantinum-x/modules.json" "$C/XModules.qml" && grep -q "XDG_CONFIG_HOME" "$C/XModules.qml"'
check "XModules: no file -> list null (all on)"  'grep -q "onLoadFailed: root.list = null" "$C/XModules.qml"'
check "XTools gated by the tools flag"           'grep -q "XModules.enabled(\"tools\")" "$C/tools/XTools.qml"'
check "XOcrButton gated by the ocr flag"         'grep -q "XModules.enabled(\"ocr\")" "$C/tools/XOcrButton.qml"'
check "GuideExtensions filters tabs by flag"     'grep -q "XModules.enabled(t.module)" "$C/GuideExtensions.qml" && [ "$(grep -c "module: \"" "$C/GuideExtensions.qml")" = 5 ]'
check "Updates tab is core (cannot be switched off)" 'grep -q "key: \"updates\", module: \"core\"" "$C/GuideExtensions.qml"'

echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
