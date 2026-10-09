#!/usr/bin/env bash
# scrub_test.sh: the repository must carry no personal data and no telemetry. Static scan of the tracked
# (and not-ignored untracked) text files; reads nothing outside the repo except the current user name / hostname.
#   - home paths of real users, e-mail addresses, public IPs / hosts
#   - the developer's own login name and hostname (taken from the environment, never written here)
#   - the hardcoded fork path and the old built-in Gemini proxy
#   - telemetry (guard for G7: it must not come back)
# usage: scrub_test.sh [repo]
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${1:-$(cd "$DIR/../../../.." && pwd)}"
cd "$R" || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; shift; printf '%s\n' "$@" | head -n 12 | sed 's/^/        /'; }

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t FILES < <(git ls-files -co --exclude-standard | grep -vE '(\.(png|jpe?g|gif|webp|ttf|otf|woff2?|ogg|wav|mp3|ico)$|^installer/vendor/)')
else
    mapfile -t FILES < <(find . -type f -not -path './.git/*' | sed 's#^\./##')
fi
# files that may legitimately mention a pattern (tests of the very rule, the notice)
SELF="src/scripts/custom/tests/scrub_test.sh"
scan() {   # scan <extended regex> [exclude regex for paths]  -> "file:line:text" lines (grep -I skips binaries)
    local re="$1" skip="${2:-^\$}" f
    for f in "${FILES[@]}"; do
        [ -f "$f" ] || continue
        [[ "$f" == "$SELF" ]] && continue
        [[ "$f" =~ $skip ]] && continue
        case "$f" in *.svg) continue ;; esac
        grep -InoE -- "$re" "$f" 2>/dev/null | sed "s#^#$f:#"
    done
}
expect_none() {   # expect_none <name> <hits...>
    local name="$1"; shift
    if [ -z "$*" ]; then ok "$name"; else bad "$name" "$@"; fi
}

# 1. home directories of real users (placeholders only)
hits="$(scan '/(home|Users)/[A-Za-z0-9][A-Za-z0-9._-]*' | grep -vE '/(home|Users)/(alice|bob|user|username|example|me|you|name|someone|test|h|x|u|tester)\b')"
expect_none "no real home paths" "$hits"

# 2. e-mail addresses (only reserved/placeholder domains)
hits="$(scan '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' | grep -vE '@([A-Za-z0-9.-]+\.)?(example(\.[a-z]+)?|localhost|invalid|test)$|noreply\.github\.com$')"
expect_none "no personal e-mail addresses" "$hits"

# 3. IPv4: loopback, private and documentation ranges, a few well-known public resolvers
hits="$(scan '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' '^src/assets/' | grep -vE ':(127\.|0\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|100\.64\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|8\.8\.[48]\.[48]$|1\.1\.1\.1$|1\.0\.0\.1$|9\.9\.9\.9$|77\.88\.8\.[18]$|999\.1\.1\.1$|120\.0\.0\.0$)')"
expect_none "no non-placeholder IP addresses" "$hits"

# 4. dynamic identity of whoever runs the test: login name and hostname must not occur in the tree
ident=()
u="$(id -un 2>/dev/null)"; h="$(cat /etc/hostname 2>/dev/null | head -1)"
for v in "$u" "$h"; do
    [ "${#v}" -ge 4 ] || continue
    case "$v" in root|user|test|localhost|alice|archlinux|admin|nobody|runner|builder) continue ;; esac
    ident+=("$v")
done
if [ "${#ident[@]}" -eq 0 ]; then ok "login name / hostname not in the tree (nothing to check on this machine)"; else
    hits=""
    for v in "${ident[@]}"; do hits+="$(scan "\\b$(printf '%s' "$v" | sed 's/[.[\*^$]/\\&/g')\\b" '^src/assets/languages/')"$'\n'; done
    expect_none "login name / hostname not in the tree" "${hits//$'\n'/}"
fi

# 5. no hardcoded developer checkout or built-in personal proxy (tests and the migration may name them)
hits="$(scan 'Projects/serpantinum' '^src/scripts/custom/tests/')"
expect_none "no hardcoded fork path (Projects/serpantinum)" "$hits"
hits="$(scan '127\.0\.0\.1:1080' '^(src/scripts/custom/tests/|src/scripts/custom/x_migrate\.py$|installer/.*_test\.go$)')"
expect_none "no built-in Gemini proxy 127.0.0.1:1080" "$hits"

# 6. telemetry must not come back (NOTICE/CHANGELOG record its removal; the migration and its tests name the old keys)
hits="$(scan 'workers\.dev|dots-telemetry|TELEMETRY_ID|ENABLE_TELEMETRY|telemetry\.sh|menu_telemetry' '^(NOTICE|CHANGELOG\.md|src/scripts/custom/(x_migrate\.py|x_update\.sh|tests/.*)|installer/.*_test\.go|tests/vm/.*)$')"
expect_none "no telemetry code or keys" "$hits"
tel_files="$(printf '%s\n' "${FILES[@]}" | grep -i 'telemetry' | grep -v '^tests/vm/upstream-no-telemetry.patch$')"
expect_none "no telemetry files" "$tel_files"

# 7. the desktop entry templates carry no concrete home directory
hits="$(scan 'Exec=.*(/home/|~)' | grep 'custom-desktop/')"
expect_none "desktop entry templates use @HOME@" "$hits"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
