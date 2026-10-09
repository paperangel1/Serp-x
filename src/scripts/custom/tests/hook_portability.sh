#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# How portable is the serpantinum-x hook? Takes the hook patch (our diff to the upstream
# files we touch, relative to the merge-base with upstream) and replays the last N real
# upstream changes of those files against it (see "verdict" below).
#
# usage: hook_portability.sh [repo]      env: N=15  BASE_REF=origin/master  MIN_OK=13
# exit: 0 when, for every file, at least MIN_OK upstream steps merge without conflict with the
#       hook (all of them when fewer exist), 1 otherwise.
set -u

REPO="${1:-$(git rev-parse --show-toplevel)}"
N="${N:-15}"
BASE_REF="${BASE_REF:-origin/master}"
MIN_OK="${MIN_OK:-13}"
FILES=(
    src/quickshell/guide/GuidePopup.qml
    src/quickshell/guide/AboutTab.qml
    src/quickshell/Shell.qml
    src/quickshell/screenshot/ScreenshotOverlay.qml
    bin/serpantinum
    src/scripts/updater.py
)

cd "$REPO" || exit 2
base="$(git merge-base HEAD "$BASE_REF")" || exit 2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0
changed_lines=0
for f in "${FILES[@]}"; do
    patch="$tmp/$(basename "$f").patch"
    git diff "$base" HEAD -- "$f" > "$patch"
    if [ ! -s "$patch" ]; then
        echo "$f: no hook hunks"
        continue
    fi
    changed_lines=$((changed_lines + $(git diff --numstat "$base" HEAD -- "$f" | awk '{print $1 + $2}')))

    versions=($(git log --format=%h -n "$N" "$BASE_REF" -- "$f"))   # newest first
    n=${#versions[@]}

    # 1) informational: does the hook patch apply verbatim to each historical version?
    ok=0
    for i in "${!versions[@]}"; do
        d="$tmp/a$i"
        mkdir -p "$d/$(dirname "$f")"
        git show "${versions[$i]}:$f" > "$d/$f" 2>/dev/null
        (cd "$d" && git apply --check "$patch" 2>/dev/null) && ok=$((ok + 1))
    done

    # 2) verdict: for every real upstream step (older -> next newer version) merge
    #    "older + hook" with the newer version using the older one as base - exactly
    #    what `git merge` does on an update. Conflict = the upstream step collided with the hook.
    tested=0
    clean=0
    conflicts=""
    for ((i = 1; i < n; i++)); do
        older="${versions[$i]}"
        newer="${versions[$((i - 1))]}"
        d="$tmp/m$i"
        mkdir -p "$d/$(dirname "$f")"
        git show "$older:$f" > "$d/base"
        git show "$newer:$f" > "$d/theirs"
        cp "$d/base" "$d/$f"
        (cd "$d" && git apply "$patch" 2>/dev/null) || continue      # hook cannot be hosted on this old version: not a merge test
        cp "$d/$f" "$d/ours"
        tested=$((tested + 1))
        if git merge-file -p "$d/ours" "$d/base" "$d/theirs" > /dev/null 2>&1; then
            clean=$((clean + 1))
        else
            conflicts="$conflicts $older->$newer"
        fi
    done

    need=$(( tested < MIN_OK ? tested : MIN_OK ))
    verdict="ok"
    if [ "$clean" -lt "$need" ]; then verdict="TOO FRAGILE"; status=1; fi
    echo "$f: merge steps $clean/$tested clean ($verdict)${conflicts:+; conflicts:$conflicts}; patch applies verbatim to $ok/$n versions"
done

echo "hook size: $changed_lines changed lines in upstream files"
exit $status
