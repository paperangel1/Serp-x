#!/usr/bin/env bash
# Re-inventory of what this build changes on top of upstream (run before every release).
#
# usage: tools/reinventory.sh [--base REF] [--head REF] [--json]
#   --base REF   upstream ref (default: $REINV_BASE, else origin/master)
#   --head REF   our ref      (default: HEAD)
#
# Prints: files of upstream that this build modified or deleted (must all be listed in NOTICE),
# a count of added files per area. Exit 0 = every modified upstream file is covered by NOTICE,
# 1 = some are not (listed), 2 = bad usage / refs not found. Read-only: changes nothing.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${REINV_BASE:-origin/master}"; HEAD_REF=HEAD; JSON=false
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 || exit 2 ;;
        --head) HEAD_REF="${2:-}"; shift 2 || exit 2 ;;
        --json) JSON=true; shift ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "reinventory: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
g() { git -C "$ROOT" "$@"; }
g rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "reinventory: ref '$BASE' not found (use --base)" >&2; exit 2; }
g rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null || { echo "reinventory: ref '$HEAD_REF' not found" >&2; exit 2; }
MB="$(g merge-base "$BASE" "$HEAD_REF")" || { echo "reinventory: no common history between $BASE and $HEAD_REF" >&2; exit 2; }

changed="$(g diff --name-status --no-renames "$MB" "$HEAD_REF" | awk '$1 != "A"')"
added="$(g diff --name-only --no-renames --diff-filter=A "$MB" "$HEAD_REF")"
missing=()
while IFS=$'\t' read -r st f; do
    [ -n "$f" ] || continue
    covered=false
    while read -r tok _; do   # NOTICE lists a path or a glob (src/assets/languages/*.json) as the first word of a line
        # shellcheck disable=SC2254
        case "$f" in $tok) covered=true; break ;; esac
    done < "$ROOT/NOTICE"
    [ "$covered" = true ] || missing+=("$st $f")
done <<< "$changed"

area() { case "$1" in
    installer/*) echo installer ;; src/quickshell/custom/*) echo shell-qml ;; src/scripts/custom/tests/*) echo tests ;;
    src/scripts/custom/*) echo scripts ;; src/assets/*) echo assets ;; bin/*) echo bin ;; tools/*) echo tools ;; *) echo other ;; esac; }
counts="$(while IFS= read -r f; do [ -n "$f" ] && area "$f"; done <<< "$added" | sort | uniq -c | awk '{print $2 "\t" $1}')"

if [ "$JSON" = true ]; then
    jq -n --arg base "$MB" --argjson changed "$(printf '%s\n' "$changed" | awk -F'\t' 'NF{print $2}' | jq -R . | jq -sc .)" \
        --argjson missing "$(printf '%s\n' "${missing[@]:-}" | awk 'NF' | jq -R . | jq -sc .)" \
        --argjson added "$(printf '%s\n' "$counts" | jq -R 'select(length>0) | split("\t") | {(.[0]): (.[1]|tonumber)}' | jq -sc add)" \
        '{merge_base: $base, modified_upstream: $changed, not_in_notice: $missing, added_by_area: $added}'
else
    echo "merge-base: $MB ($BASE vs $HEAD_REF)"
    echo "upstream files modified or deleted:"
    printf '%s\n' "$changed" | awk -F'\t' 'NF{print "  " $1 " " $2}'
    echo "added files by area:"
    printf '%s\n' "$counts" | awk -F'\t' 'NF{printf "  %-12s %s\n", $1, $2}'
    if [ ${#missing[@]} -gt 0 ]; then echo "NOT listed in NOTICE:"; printf '  %s\n' "${missing[@]}"; else echo "all modified upstream files are listed in NOTICE"; fi
fi
[ ${#missing[@]} -eq 0 ]
