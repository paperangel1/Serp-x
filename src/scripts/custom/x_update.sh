#!/usr/bin/env bash
# serpantinum-x safe updater: brings upstream changes into the local `serp-x` branch
# (merge, never rebase), validates, backs up, mirrors the result onto the live install,
# restarts the shell and rolls everything back if the new shell does not come up.
#
# The live install is only ever written by `mirror_dir` AFTER the merge and validation
# succeeded and a backup exists; any failure after that point restores the backup.
#
# Subcommands:
#   check                    read-only (fetches): is there anything to update? (JSON)
#   run [--foreground] [--allow-drift]
#                            do the update. Detached by default (returns {"status":"started"}),
#                            progress goes to the status file.
#   bootstrap                first-time cut-over / manual run: foreground, allows drift
#   status | ack             read / acknowledge the status file
#   backups | restore <name|latest>
#   repair-hooks             re-apply the GuidePopup/AboutTab hook by anchors (working tree)
#
# Channels (~/.config/serpantinum-x/update.toml: channel, fork_dir, base_url, pubkey_fpr):
#   release (default for fresh installs)  numbered releases from base_url; no git checkout needed.
#                                         Without base_url every command reports "not-configured".
#   dev     (the developer's own machine) the git flow described above, from the checkout in
#                                         fork_dir / SERPANTINUM_FORK_DIR. "git" is accepted as an alias.
#
# env (tests): SERPANTINUM_UPDATE_CHANNEL, X_UPDATE_CONF, SERPANTINUM_FORK_DIR/_BRANCH/_REMOTE/_EXPECT_URL, SERPANTINUM_INSTALL_DIR,
#   X_UPDATE_STATE_DIR, X_UPDATE_VERSION_FILE, X_UPDATE_BACKUP_ROOT, X_UPDATE_RUN_DIR,
#   X_UPDATE_SETTINGS, X_UPDATE_HYPR_DIR, X_UPDATE_NO_RESTART=1, X_UPDATE_FAKE_HEALTH=fail

SELF="$(realpath "${BASH_SOURCE[0]}")"

X_UPDATE_CONF="${X_UPDATE_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/serpantinum-x/update.toml}"
x_conf_get() {   # x_conf_get <key>   (same helper as in bin/serpantinum-x: this script must work standalone)
    [ -f "$X_UPDATE_CONF" ] || return 0
    awk -F= -v k="$1" '{ key=$1; gsub(/[ \t]/, "", key) } key == k { v=$0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v); gsub(/^"|"$/, "", v); print v; exit }' "$X_UPDATE_CONF"
}
CHANNEL="${SERPANTINUM_UPDATE_CHANNEL:-$(x_conf_get channel)}"
[ -n "$CHANNEL" ] || { [ -n "${SERPANTINUM_FORK_DIR:-}" ] && CHANNEL=dev || CHANNEL=release; }
[ "$CHANNEL" = git ] && CHANNEL=dev
BASE_URL="${SERPANTINUM_UPDATE_BASE_URL:-$(x_conf_get base_url)}"
FORK_DIR="${SERPANTINUM_FORK_DIR:-}"
if [ -z "$FORK_DIR" ] && [ "$CHANNEL" = dev ]; then
    FORK_DIR="$(x_conf_get fork_dir)"; FORK_DIR="${FORK_DIR/#\~/$HOME}"; FORK_DIR="${FORK_DIR/#\$HOME/$HOME}"
fi
BRANCH="${SERPANTINUM_FORK_BRANCH:-serp-x}"
REMOTE="${SERPANTINUM_FORK_REMOTE:-origin}"
EXPECT_URL="${SERPANTINUM_FORK_EXPECT_URL:-https://github.com/ilyamiro/serpantinum.git}"   # upstream (the project this build is based on)
INSTALL_DIR="${SERPANTINUM_INSTALL_DIR:-$HOME/.local/share/serpantinum}"

STATE_DIR="${X_UPDATE_STATE_DIR:-$HOME/.local/state/serpantinum/x_update}"
VERSION_FILE="${X_UPDATE_VERSION_FILE:-$HOME/.local/state/serpantinum/version}"
BACKUP_ROOT="${X_UPDATE_BACKUP_ROOT:-$HOME/.local/share/serpantinum-backups}"
RUN_DIR="${X_UPDATE_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/serpantinum}"
SETTINGS_FILE="${X_UPDATE_SETTINGS:-$HOME/.config/serpantinum/settings.json}"
HYPR_DIR="${X_UPDATE_HYPR_DIR:-$HOME/.config/hypr}"

STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/update.log"
LOCK_DIR="$RUN_DIR/x_update.lock.d"
WORKER_SNAPSHOT="$STATE_DIR/worker.sh"
KEEP_BACKUPS=5
HEALTH_TIMEOUT=45
HEALTH_STABLE_SECS=10

HOOK_FILES=(src/quickshell/guide/GuidePopup.qml src/quickshell/guide/AboutTab.qml src/quickshell/Shell.qml src/quickshell/screenshot/ScreenshotOverlay.qml bin/serpantinum src/scripts/updater.py)

mkdir -p "$STATE_DIR" "$RUN_DIR" "$BACKUP_ROOT" 2>/dev/null

# Shared logging (module "update"). The worker runs from a snapshot copy, so look in the checkout, then the install.
for _xl in "${FORK_DIR:+$FORK_DIR/src/scripts/custom/xlog/xlog.sh}" "$INSTALL_DIR/src/scripts/custom/xlog/xlog.sh"; do
    # shellcheck disable=SC1090
    [ -n "$_xl" ] && [ -f "$_xl" ] && . "$_xl" && break
done
type xlog >/dev/null 2>&1 || xlog() { :; }

# git needs an identity for the merge commit; use the repo's config when present and only
# fall back to environment values (the git config itself is never modified).
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$( { [ -n "$FORK_DIR" ] && git -C "$FORK_DIR" config user.name; } 2>/dev/null || echo serpantinum-x)}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$( { [ -n "$FORK_DIR" ] && git -C "$FORK_DIR" config user.email; } 2>/dev/null || echo serpantinum-x@localhost)}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

g() { git -C "$FORK_DIR" "$@"; }

# ---------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------

state_get() {
    [ -f "$VERSION_FILE" ] || return 0
    awk -F= -v k="$1" '$1 == k { gsub(/"/, "", $2); print $2 }' "$VERSION_FILE" | head -1
}

state_rewrite() {   # state_rewrite VERSION UPSTREAM_COMMIT FORK_COMMIT
    mkdir -p "$(dirname "$VERSION_FILE")"
    local tmp="$VERSION_FILE.tmp.$$"
    {
        printf 'SERPANTINUM_VERSION="%s"\n' "$1"
        printf 'SERPANTINUM_COMMIT="%s"\n' "$2"
        printf 'SERPANTINUM_FORK_COMMIT="%s"\n' "$3"
        [ -f "$VERSION_FILE" ] && grep -vE '^(SERPANTINUM_VERSION|SERPANTINUM_COMMIT|SERPANTINUM_FORK_COMMIT|TELEMETRY_ID|ENABLE_TELEMETRY)=' "$VERSION_FILE"
        true   # grep -v exits 1 when it keeps no line; that must not abort the rewrite
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$VERSION_FILE"
}

phase_pct() {
    case "$1" in
        preflight) echo 4 ;; fetching) echo 10 ;; dryrun) echo 18 ;; merging) echo 28 ;;
        validating) echo 40 ;; hookcheck) echo 48 ;; backup) echo 58 ;; syncing) echo 70 ;;
        state) echo 78 ;; restarting) echo 86 ;; healthcheck) echo 94 ;; rolling_back) echo 90 ;;
        done) echo 100 ;; *) echo 0 ;;
    esac
}

status_write() {   # status_write STATUS PHASE CODE DETAIL
    local tmp="$STATUS_FILE.tmp.$$"
    jq -cn --arg st "$1" --arg ph "$2" --arg code "$3" --arg detail "$4" \
           --arg from "${FROM_VERSION:-}" --arg to "${TO_LABEL:-${TO_VERSION:-}}" \
           --argjson pct "$(phase_pct "$2")" --argjson ts "$(date +%s)" \
        '{status:$st,phase:$ph,code:$code,detail:$detail,from:$from,to:$to,pct:$pct,ts:$ts,ack:false}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE"
    [ -n "${X_UPDATE_VERBOSE:-}" ] && printf '[x_update] %s %s %s %s\n' "$1" "$2" "$3" "$4" >&2
    xlog update "$([ "$1" = error ] && echo error || echo info)" "phase=$2 status=$1${3:+ code=$3}${4:+ detail=$(printf '%s' "$4" | tr '\n' ' ' | head -c 300)}"
}

log_line() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null
    local lvl=info
    case "$*" in *failed*|*error*|*conflict*|*"rolling back"*|*missing*|*incomplete*) lvl=warn ;; esac
    xlog update "$lvl" "$(printf '%s' "$*" | tr '\n' ' ' | head -c 400)"
}

head_version()   { g show HEAD:version.txt 2>/dev/null | tr -d '[:space:]'; }
remote_version() { g show "$REMOTE/master:version.txt" 2>/dev/null | tr -d '[:space:]'; }
commits_ahead()  { g rev-list --count "HEAD..$REMOTE/master" 2>/dev/null || echo 0; }

# "2.2.5" on a version bump, "2.2.4 + 37" when upstream only has more commits.
update_label() {   # update_label HEAD_VERSION REMOTE_VERSION AHEAD
    if [ -n "$2" ] && [ "$2" != "$1" ]; then echo "$2"; else echo "$1 + $3"; fi
}

repo_ok() {
    [ "$(g rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}

git_path_exists() { [ -e "$(g rev-parse --git-path "$1" 2>/dev/null)" ]; }

# ---------------------------------------------------------------------------------------
# mirror (rsync -a --delete replacement; always unlink before copy so hardlinked backups
# and this script's own running file stay intact)
# ---------------------------------------------------------------------------------------

same_file() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    [ ! -L "$1" ] && [ ! -L "$2" ] || return 1
    [ "$(stat -c '%s' "$1" 2>/dev/null)" = "$(stat -c '%s' "$2" 2>/dev/null)" ] || return 1
    [ "$(stat -c '%Y' "$1" 2>/dev/null)" = "$(stat -c '%Y' "$2" 2>/dev/null)" ] && return 0
    cmp -s "$1" "$2"
}

mirror_dir() {   # mirror_dir SRC DST -- make DST byte-identical to SRC
    local src="${1%/}" dst="${2%/}" rel
    [ -d "$src" ] || { echo "mirror_dir: no such source: $src" >&2; return 1; }
    mkdir -p "$dst" || return 1
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"; [ "$rel" = "." ] && continue
        mkdir -p "$dst/$rel" || return 1
    done < <(cd "$src" && find . -name __pycache__ -prune -o -type d -print0)
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        same_file "$src/$rel" "$dst/$rel" && continue
        rm -rf -- "$dst/$rel"
        cp -a -- "$src/$rel" "$dst/$rel" || return 1
    done < <(cd "$src" && find . -name __pycache__ -prune -o \( -type f -o -type l \) -print0)
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [ -e "$src/$rel" ] || [ -L "$src/$rel" ] || rm -f -- "$dst/$rel"
    done < <(cd "$dst" && find . \( -type f -o -type l \) -print0)
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"; { [ -z "$rel" ] || [ "$rel" = "." ]; } && continue
        [ -d "$src/$rel" ] || rm -rf -- "$dst/$rel"
    done < <(cd "$dst" && find . -depth -type d -print0)
    return 0
}

mirror_differs() {   # 0 = SRC and DST are not identical
    local src="${1%/}" dst="${2%/}" rel
    [ -d "$src" ] && [ -d "$dst" ] || return 0
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"; same_file "$src/$rel" "$dst/$rel" || return 0
    done < <(cd "$src" && find . -name __pycache__ -prune -o -type f -print0)
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"; [ -e "$src/$rel" ] || return 0
    done < <(cd "$dst" && find . -name __pycache__ -prune -o -type f -print0)
    return 1
}

install_differs() {
    mirror_differs "$FORK_DIR/bin" "$INSTALL_DIR/bin" || mirror_differs "$FORK_DIR/src" "$INSTALL_DIR/src"
}

# Files (relative to the repo root) that differ between the fork checkout and the install.
install_diff_files() {
    local d
    for d in bin src; do
        [ -d "$INSTALL_DIR/$d" ] || continue
        diff -rq -x __pycache__ "$FORK_DIR/$d" "$INSTALL_DIR/$d" 2>/dev/null | awk -v root="$FORK_DIR/" '
            /^Files / { p = $2; sub("^" root, "", p); print p; next }
            /^Only in / {
                dir = $3; sub(":$", "", dir); if (index(dir, root) == 1) { sub("^" root, "", dir); print dir "/" $4 }
            }'
    done
}

fix_perms() {
    chmod +x "$INSTALL_DIR/bin/"* 2>/dev/null
    find "$INSTALL_DIR/src/scripts" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null
    true
}

# ---------------------------------------------------------------------------------------
# dry run + check
# ---------------------------------------------------------------------------------------

DRY_CLEAN="null"
DRY_FILES="[]"
DRY_HOOK_ONLY=false

dry_run_merge() {
    DRY_CLEAN="null"; DRY_FILES="[]"; DRY_HOOK_ONLY=false
    local out rc files
    out="$(g merge-tree --write-tree --name-only --no-messages HEAD "$REMOTE/master" 2>/dev/null)"; rc=$?
    if [ $rc -eq 0 ]; then
        DRY_CLEAN=true
    elif [ $rc -eq 1 ]; then
        DRY_CLEAN=false
        files="$(printf '%s\n' "$out" | tail -n +2 | awk 'NF == 0 { exit } { print }')"
        DRY_FILES="$(printf '%s\n' "$files" | jq -Rn '[inputs | select(length > 0)]')"
        if jq -e --argjson hooks "$(printf '%s\n' "${HOOK_FILES[@]}" | jq -Rn '[inputs]')" \
              'length > 0 and all(.[]; . as $f | $hooks | index($f) != null)' <<< "$DRY_FILES" >/dev/null 2>&1; then
            DRY_HOOK_ONLY=true
        fi
    fi
}

cmd_check() {
    local err="" installed_v installed_c head_v target_v target_c ahead has_update=false clean=false branch_ok=false drift=false label=""
    installed_v="$(state_get SERPANTINUM_VERSION)"
    installed_c="$(state_get SERPANTINUM_COMMIT)"

    if [ ! -d "$FORK_DIR" ] || ! repo_ok; then
        err="repo_missing"
    elif [ "$(g remote get-url "$REMOTE" 2>/dev/null)" != "$EXPECT_URL" ]; then
        err="wrong_remote"
    else
        [ "$(g rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ] && branch_ok=true
        [ -z "$(g status --porcelain --untracked-files=no 2>/dev/null)" ] && clean=true
        timeout 30 git -C "$FORK_DIR" fetch --quiet "$REMOTE" 2>/dev/null || err="fetch_failed"
    fi

    ahead=0
    if [ -z "$err" ]; then
        head_v="$(head_version)"; target_v="$(remote_version)"
        target_c="$(g rev-parse --short "$REMOTE/master" 2>/dev/null)"
        ahead="$(commits_ahead)"
        if [ "${ahead:-0}" -gt 0 ] || { [ -n "$target_v" ] && [ "$target_v" != "$head_v" ]; }; then
            has_update=true
            label="$(update_label "$head_v" "$target_v" "$ahead")"
        fi
        install_differs && drift=true
        dry_run_merge
    fi

    jq -cn \
        --arg status "$([ -n "$err" ] && echo error || echo ok)" --arg error "$err" \
        --arg forkDir "$FORK_DIR" --arg branch "$BRANCH" \
        --argjson branchOk "$branch_ok" --argjson clean "$clean" --argjson drift "$drift" \
        --arg installedVersion "$installed_v" --arg installedCommit "$installed_c" \
        --arg headVersion "${head_v:-}" --arg targetVersion "${target_v:-}" --arg targetCommit "${target_c:-}" \
        --argjson commitsAhead "${ahead:-0}" --argjson hasUpdate "$has_update" --arg updateLabel "$label" \
        --argjson dryClean "$DRY_CLEAN" --argjson dryFiles "$DRY_FILES" --argjson dryHookOnly "$DRY_HOOK_ONLY" \
        --argjson ts "$(date +%s)" \
        '{status:$status,error:$error,forkDir:$forkDir,branch:$branch,branchOk:$branchOk,clean:$clean,
          drift:$drift,installedVersion:$installedVersion,installedCommit:$installedCommit,
          headVersion:$headVersion,targetVersion:$targetVersion,targetCommit:$targetCommit,
          commitsAhead:$commitsAhead,hasUpdate:$hasUpdate,updateLabel:$updateLabel,
          dryRun:{clean:$dryClean,files:$dryFiles,hookOnly:$dryHookOnly},ts:$ts}'
}

# ---------------------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------------------

PREFLIGHT_ERR=""

preflight() {
    PREFLIGHT_ERR=""
    if [ ! -d "$FORK_DIR" ] || ! repo_ok; then PREFLIGHT_ERR="repo_missing"; return 1; fi
    [ "$(g remote get-url "$REMOTE" 2>/dev/null)" = "$EXPECT_URL" ] || { PREFLIGHT_ERR="wrong_remote"; return 1; }
    [ "$(g rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ] || { PREFLIGHT_ERR="wrong_branch"; return 1; }
    [ -z "$(g status --porcelain --untracked-files=no 2>/dev/null)" ] || { PREFLIGHT_ERR="dirty_tree"; return 1; }
    if git_path_exists MERGE_HEAD || git_path_exists rebase-merge || git_path_exists rebase-apply; then
        PREFLIGHT_ERR="merge_in_progress"; return 1
    fi
    [ -d "$INSTALL_DIR/bin" ] && [ -d "$INSTALL_DIR/src" ] || { PREFLIGHT_ERR="install_missing"; return 1; }
    local t
    for t in git jq find cp rm diff; do
        command -v "$t" >/dev/null 2>&1 || { PREFLIGHT_ERR="missing_tool:$t"; return 1; }
    done
    if [ "$ALLOW_DRIFT" != "true" ] && install_differs; then PREFLIGHT_ERR="drift"; return 1; fi
    return 0
}

# ---------------------------------------------------------------------------------------
# hooks: sanity check + anchor based re-application
# ---------------------------------------------------------------------------------------

hooks_ok() {
    local gp="$FORK_DIR/src/quickshell/guide/GuidePopup.qml" ab="$FORK_DIR/src/quickshell/guide/AboutTab.qml"
    grep -q 'serp-x hook' "$gp" 2>/dev/null \
        && grep -q 'import "../custom"' "$gp" 2>/dev/null \
        && grep -q 'XUpdate.buttonText' "$gp" 2>/dev/null \
        && grep -q 'serp-x hook' "$ab" 2>/dev/null \
        && grep -q 'XTools {}' "$FORK_DIR/src/quickshell/Shell.qml" 2>/dev/null \
        && grep -q 'import "custom"' "$FORK_DIR/src/quickshell/Shell.qml" 2>/dev/null \
        && grep -q 'XOcrButton' "$FORK_DIR/src/quickshell/screenshot/ScreenshotOverlay.qml" 2>/dev/null \
        && grep -q 'import "../custom"' "$FORK_DIR/src/quickshell/screenshot/ScreenshotOverlay.qml" 2>/dev/null \
        && grep -q 'serp-x hook' "$FORK_DIR/bin/serpantinum" 2>/dev/null \
        && ! grep -q 'install/install.sh' "$ab" 2>/dev/null \
        && grep -q 'serp-x hook' "$FORK_DIR/src/scripts/updater.py" 2>/dev/null
}

# Every component registered in our qmldir files must exist, and the CLI must be present:
# catches a file lost or forgotten in a merge before anything is installed.
custom_files_ok() {
    local d="$FORK_DIR/src/quickshell/custom" q line f
    [ -f "$FORK_DIR/bin/serpantinum-x" ] || { log_line "bin/serpantinum-x missing"; return 1; }
    local req
    for req in src/scripts/custom/xlog/xlog.py src/scripts/custom/xlog/xlog.sh src/quickshell/custom/XLog.qml; do
        [ -f "$FORK_DIR/$req" ] || { log_line "logging layer file missing: $req"; return 1; }
    done
    # commands engine (python package, node schema, launcher)
    local cf
    for cf in cmd/x_cmd.sh cmd/xcmd/__init__.py cmd/xcmd/engine.py cmd/nodes/event.json cmd/systemd/serpantinum-cmdd.service; do
        [ -f "$FORK_DIR/src/scripts/custom/$cf" ] || { log_line "commands engine file missing: $cf"; return 1; }
    done
    for q in "$d/qmldir" "$d"/*/qmldir; do
        [ -f "$q" ] || continue
        while IFS= read -r line; do
            case "$line" in ''|\#*) continue ;; esac
            f="$(awk '{print $NF}' <<<"$line")"
            [ -f "$(dirname "$q")/$f" ] || { log_line "custom qmldir entry without file: $q -> $f"; return 1; }
        done < "$q"
    done
    # JS modules imported by our QML (import "X.js" as X) are not listed in any qmldir: check them separately.
    local qf js
    while IFS= read -r qf; do
        while IFS= read -r js; do
            [ -f "$(dirname "$qf")/$js" ] || { log_line "QML imports a missing JS module: $qf -> $js"; return 1; }
        done < <(sed -n 's/^import "\([^"]*\.js\)" as .*/\1/p' "$qf")
    done < <(find "$d" -name '*.qml' 2>/dev/null)
    return 0
}

# Idempotent: re-inserts every hook edit that is missing. rc 3 = an anchor is gone
# (upstream restructured that area) -> needs a human.
apply_hooks_py() {   # apply_hooks_py <repo root>
    python3 - "$1" <<'PY'
import sys, re, os
root = sys.argv[1]
gp = os.path.join(root, "src/quickshell/guide/GuidePopup.qml")
ab = os.path.join(root, "src/quickshell/guide/AboutTab.qml")
sh = os.path.join(root, "src/quickshell/Shell.qml")
ss = os.path.join(root, "src/quickshell/screenshot/ScreenshotOverlay.qml")
bs = os.path.join(root, "bin/serpantinum")
up = os.path.join(root, "src/scripts/updater.py")
failed = []

def edit_guidepopup(t):
    if 'import "../custom"' not in t:
        lines = t.split("\n")
        idx = [i for i, l in enumerate(lines[:80]) if l.startswith("import ")]
        if not idx:
            failed.append("GuidePopup: no import block"); return t
        lines.insert(idx[-1] + 1, 'import "../custom"')
        t = "\n".join(lines)
    if "XUpdate.updateAvailable" not in t:
        old = "visible: Updater.updateAvailable && !root.searchActive"
        if old not in t: failed.append("GuidePopup: update button visible anchor")
        else: t = t.replace(old, "visible: (Updater.updateAvailable || XUpdate.updateAvailable) && !root.searchActive", 1)
    if "XUpdate.buttonText" not in t:
        old = 'buttonText: I18n.t("guide.update_available")'
        if old not in t: failed.append("GuidePopup: update button text anchor")
        else: t = t.replace(old, "buttonText: XUpdate.buttonText", 1)
    lines = t.split("\n")
    for i, l in enumerate(lines):
        if "buttonText: XUpdate.buttonText" in l:
            for j in range(i, min(i + 30, len(lines))):
                if 'root.gotoTab("updates");' in lines[j]: break
                if 'root.gotoTab("about");' in lines[j]:
                    lines[j] = lines[j].replace('root.gotoTab("about");', 'root.gotoTab("updates");', 1); break
            else:
                failed.append("GuidePopup: update button gotoTab anchor")
            break
    t = "\n".join(lines)
    if "GuideExtensions {" not in t:
        lines = t.rstrip("\n").split("\n")
        if lines[-1].strip() != "}":
            failed.append("GuidePopup: closing brace anchor"); return t
        lines.insert(len(lines) - 1, "    GuideExtensions { guide: root; sidebarColumn: tabsCol; sidebarFlickable: tabsFlickable } // serp-x hook")
        t = "\n".join(lines) + "\n"
    return t

ABOUT_CMD = ('let cmd = "X=\\"$HOME/.local/bin/serpantinum-x\\"; [ -x \\"$X\\" ] || X=\\"$HOME/.local/share/serpantinum/bin/serpantinum-x\\"; '
             'if command -v kitty >/dev/null 2>&1; then kitty --hold \\"$X\\" update run --foreground; '
             'else ${TERM:-xterm} -hold -e \\"$X\\" update run --foreground; fi"; // serp-x hook: our updater instead of curl|eval')

def edit_abouttab(t):
    lines = t.split("\n")
    for i, l in enumerate(lines):
        if "let cmd = " in l and ("install.sh" in l or "serpantinum-x" in l):
            ind = l[: len(l) - len(l.lstrip())]
            lines[i] = ind + ABOUT_CMD
            for j in range(i - 1, max(i - 6, 0), -1):
                if lines[j].strip().startswith("onTriggered: {"):
                    jnd = lines[j][: len(lines[j]) - len(lines[j].lstrip())]
                    lines[j] = jnd + 'onTriggered: { if (rootObj.isGuidePopup) { rootObj.gotoTab("updates"); return; } // serp-x hook: outside the guide run our updater'
                    break
            return "\n".join(lines)
    failed.append("AboutTab: install.sh onTriggered anchor")
    return t

def edit_updater(t):
    if "serp-x hook" in t:
        return t
    anchor = "local_ver = get_local_ver()\n"
    if anchor not in t:
        failed.append("updater.py: local_ver anchor"); return t
    hook = ('if os.path.isfile(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin", "serpantinum-x")):  # serp-x hook\n'
            '    # updates come from `serpantinum-x update` (XUpdate), never from upstream GitHub\n'
            '    print(json.dumps({"local": local_ver, "remote": local_ver, "has_update": False, "last_notified": get_last_notified()}))\n'
            '    sys.exit(0)\n')
    return t.replace(anchor, anchor + hook, 1)

def last_import(lines):
    idx = [i for i, l in enumerate(lines[:80]) if l.startswith("import ")]
    return idx[-1] if idx else -1

def edit_shell(t):
    lines = t.split("\n")
    if 'import "custom"' not in t:
        i = last_import(lines)
        if i < 0: failed.append("Shell: no import block"); return t
        lines.insert(i + 1, 'import "custom"  // serp-x hook')
    if "XTools {}" not in "\n".join(lines):
        at = next((i for i, l in enumerate(lines) if l.strip() == "PopoutManager {}"), -1)
        if at < 0:
            closing = max(i for i, l in enumerate(lines) if l.strip() == "}")
            at = closing - 1
        lines.insert(at + 1, "    XTools {}  // serp-x hook")
    return "\n".join(lines)

def edit_screenshot(t):
    lines = t.split("\n")
    if 'import "../custom"' not in t:
        i = last_import(lines)
        if i < 0: failed.append("ScreenshotOverlay: no import block"); return t
        lines.insert(i + 1, 'import "../custom"  // serp-x hook')
    if "XOcrButton" not in "\n".join(lines):
        q = next((i for i, l in enumerate(lines) if "root.performQrScan()" in l), -1)
        j = next((k for k in range(q, min(q + 4, len(lines))) if q >= 0 and lines[k].strip() == "}"), -1)
        if j < 0: failed.append("ScreenshotOverlay: QR button anchor"); return t
        ind = lines[j][: len(lines[j]) - len(lines[j].lstrip())]
        lines[j + 1:j + 1] = ["", ind + "XOcrButton { overlay: root }  // serp-x hook"]
    return "\n".join(lines)

def edit_binserpantinum(t):
    if "serp-x hook" in t:
        return t
    anchor = "ALLOWED_SCRIPTS=(\n"
    if anchor not in t:
        failed.append("bin/serpantinum: ALLOWED_SCRIPTS anchor"); return t
    hook = ('# serp-x hook: `serpantinum run "Name"` -> commands engine (bin/serpantinum-x)\n'
            'if [[ "$1" == "run" && -x "$BIN_DIR/serpantinum-x" ]]; then shift; exec "$BIN_DIR/serpantinum-x" run "$@"; fi\n\n')
    return t.replace(anchor, hook + anchor, 1)

for path, fn in ((gp, edit_guidepopup), (ab, edit_abouttab), (sh, edit_shell), (ss, edit_screenshot), (bs, edit_binserpantinum), (up, edit_updater)):
    if not os.path.exists(path):
        failed.append(os.path.basename(path) + ": missing"); continue
    old = open(path, encoding="utf-8").read()
    new = fn(old)
    if new != old:
        open(path, "w", encoding="utf-8").write(new)
if failed:
    print("; ".join(failed), file=sys.stderr)
    sys.exit(3)
PY
}

cmd_repair_hooks() {
    if apply_hooks_py "$FORK_DIR"; then
        echo '{"status":"ok"}'
    else
        echo '{"status":"error","code":"hook_anchor_missing"}'
        return 1
    fi
}

# ---------------------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------------------

resolve_qmllint() {
    local c
    for c in "${QMLLINT:-}" /usr/lib/qt6/bin/qmllint "$(command -v qmllint6 2>/dev/null)" "$(command -v qmllint 2>/dev/null)"; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        case "$("$c" --version 2>/dev/null)" in *' 6.'*) printf '%s' "$c"; return 0 ;; esac
    done
    return 1
}

VALIDATION_ERRORS=""
vfail() { VALIDATION_ERRORS="${VALIDATION_ERRORS}${VALIDATION_ERRORS:+; }$1: $2"; }

validate_changed() {   # validate_changed PRE_COMMIT
    local pre="$1" ql tmp f rc out old_rc
    VALIDATION_ERRORS=""
    ql="$(resolve_qmllint)" || ql=""
    tmp="$(mktemp -d)" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$FORK_DIR/$f" ] || continue
        case "$f" in
            *.qml)
                [ -n "$ql" ] || continue
                out="$("$ql" "$FORK_DIR/$f" 2>&1)"; rc=$?
                case "$out" in
                    *'[syntax]'*) vfail "$f" "syntax error" ;;
                    *)
                        if [ $rc -ne 0 ]; then
                            if g show "$pre:$f" > "$tmp/old.qml" 2>/dev/null; then
                                "$ql" "$tmp/old.qml" >/dev/null 2>&1; old_rc=$?
                                [ $old_rc -eq 0 ] && vfail "$f" "qmllint errors"
                            else
                                vfail "$f" "qmllint errors"
                            fi
                        fi ;;
                esac ;;
            *.json) jq -e . "$FORK_DIR/$f" >/dev/null 2>&1 || vfail "$f" "invalid json" ;;
            *.lua)  command -v lua >/dev/null 2>&1 && { lua -e "assert(loadfile('$FORK_DIR/$f'))" >/dev/null 2>&1 || vfail "$f" "lua parse error"; } ;;
            *.sh)   bash -n "$FORK_DIR/$f" 2>/dev/null || vfail "$f" "bash syntax error" ;;
            *.py)   python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$FORK_DIR/$f" >/dev/null 2>&1 || vfail "$f" "python syntax error" ;;
            *qmldir) [ -s "$FORK_DIR/$f" ] || vfail "$f" "empty qmldir" ;;
        esac
    done < <({ g diff --name-only "$pre..HEAD" -- bin src 2>/dev/null; install_diff_files; } | sort -u)
    rm -rf "$tmp"
    [ -z "$VALIDATION_ERRORS" ]
}

# ---------------------------------------------------------------------------------------
# backup / restore
# ---------------------------------------------------------------------------------------

make_backup() {
    BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-${FROM_VERSION:-unknown}-to-${TO_LABEL// /}"
    mkdir -p "$BACKUP_DIR/extra" || return 1
    ( cp -al "$INSTALL_DIR/bin" "$BACKUP_DIR/bin" 2>/dev/null || cp -a "$INSTALL_DIR/bin" "$BACKUP_DIR/bin" ) || return 1
    ( cp -al "$INSTALL_DIR/src" "$BACKUP_DIR/src" 2>/dev/null || cp -a "$INSTALL_DIR/src" "$BACKUP_DIR/src" ) || return 1
    [ -f "$VERSION_FILE" ] && cp -a "$VERSION_FILE" "$BACKUP_DIR/version.state" 2>/dev/null
    [ -f "$SETTINGS_FILE" ] && cp -a "$SETTINGS_FILE" "$BACKUP_DIR/extra/settings.json" 2>/dev/null
    [ -f "$HYPR_DIR/hyprland.lua" ] && cp -a "$HYPR_DIR/hyprland.lua" "$BACKUP_DIR/extra/hyprland.lua" 2>/dev/null
    [ -f "$HYPR_DIR/config/user_keybinds.lua" ] && cp -a "$HYPR_DIR/config/user_keybinds.lua" "$BACKUP_DIR/extra/user_keybinds.lua" 2>/dev/null
    printf '%s\n' "$FORK_PRE_COMMIT" > "$BACKUP_DIR/fork_commit" 2>/dev/null
    return 0
}

prune_backups() {
    local d n=0
    while IFS= read -r d; do
        n=$((n + 1)); [ "$n" -le "$KEEP_BACKUPS" ] && continue
        rm -rf -- "$d"
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
}

cmd_backups() {
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | xargs -r -I{} basename {} \
        | jq -Rn -c '[inputs | . as $n
            | ([capture("^(?<ts>[0-9]{8}T[0-9]{6}Z)-(?<from>.+)-to-(?<to>.+)$")] | .[0]) as $m
            | {name: $n, ts: ($m.ts // ""), from: ($m.from // ""), to: ($m.to // "")}]'
}

restore_from() {   # restore_from <backup dir> -- mirror a backup onto the install
    local dir="$1"
    mirror_dir "$dir/bin" "$INSTALL_DIR/bin" && mirror_dir "$dir/src" "$INSTALL_DIR/src" || return 1
    if [ -f "$dir/version.state" ]; then
        cp -a "$dir/version.state" "$VERSION_FILE.tmp.$$" 2>/dev/null && mv -f "$VERSION_FILE.tmp.$$" "$VERSION_FILE"
    fi
    fix_perms
}

cmd_restore() {
    local name="${1:-latest}" dir
    if [ -z "$name" ] || [ "$name" = "latest" ]; then
        dir="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | head -1)"
    else
        dir="$BACKUP_ROOT/$name"
    fi
    [ -n "$dir" ] && [ -d "$dir/src" ] || { echo '{"status":"error","code":"backup_not_found"}'; return 1; }
    restore_from "$dir" || { echo '{"status":"error","code":"restore_failed"}'; return 1; }
    restart_shell
    echo "{\"status\":\"ok\",\"restored\":\"$(basename "$dir")\"}"
}

# ---------------------------------------------------------------------------------------
# restart + health
# ---------------------------------------------------------------------------------------

qs_pids() { pgrep -f "quickshell -p $INSTALL_DIR/src/quickshell/Shell.qml" 2>/dev/null; }

qs_logfile() {
    local l t
    for l in /proc/"$1"/fd/*; do
        t="$(readlink "$l" 2>/dev/null)" || continue
        case "$t" in */quickshell/by-id/*/log.log) printf '%s' "$t"; return 0 ;; esac
    done
    return 1
}

layer_present() {   # skips gracefully outside Hyprland
    command -v hyprctl >/dev/null 2>&1 || return 0
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
    timeout 3 hyprctl layers -j 2>/dev/null | jq -e --argjson p "${1:-0}" \
        '[.. | objects | select(.namespace? == "quickshell") | select(.pid? == $p)] | length > 0' >/dev/null 2>&1
}

# Full restart: hot reload (Quickshell.reload) proved unreliable for large structural changes.
restart_shell() {
    [ "${X_UPDATE_NO_RESTART:-}" = "1" ] && return 0
    timeout 15 "$INSTALL_DIR/bin/serpantinum" kill >/dev/null 2>&1
    sleep 1
    rm -f /tmp/serpantinumd.pid /tmp/serpantinumd.lock 2>/dev/null
    setsid nohup "$INSTALL_DIR/bin/serpantinumd" start </dev/null >>"$LOG_FILE" 2>&1 &
    disown 2>/dev/null
    return 0
}

HEALTH_ERR=""
wait_for_healthy() {
    HEALTH_ERR=""
    if [ "${X_UPDATE_NO_RESTART:-}" = "1" ]; then
        [ "${X_UPDATE_FAKE_HEALTH:-}" = "fail" ] && { HEALTH_ERR="simulated"; return 1; }
        return 0
    fi
    local deadline pid="" log="" seg start=0
    deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -z "$pid" ]; then
            pid="$(qs_pids | head -1)"
            [ -n "$pid" ] && start="$(date +%s)"
        fi
        if [ -n "$pid" ]; then
            kill -0 "$pid" 2>/dev/null || { HEALTH_ERR="process_died"; return 1; }
            [ -n "$log" ] || log="$(qs_logfile "$pid")"
            if [ -n "$log" ] && [ -f "$log" ]; then
                seg="$(cat "$log" 2>/dev/null)"
                case "$seg" in
                    *' ERROR'*|*'is not a type'*) HEALTH_ERR="reload_error"; return 1 ;;
                esac
                if printf '%s' "$seg" | grep -qE 'Type .* unavailable'; then HEALTH_ERR="reload_error"; return 1; fi
                case "$seg" in
                    *'Configuration Loaded'*)
                        if [ $(( $(date +%s) - start )) -ge "$HEALTH_STABLE_SECS" ] && layer_present "$pid"; then return 0; fi ;;
                esac
            fi
        fi
        sleep 0.5
    done
    HEALTH_ERR="timeout"
    return 1
}

# ---------------------------------------------------------------------------------------
# merge handling
# ---------------------------------------------------------------------------------------

abort_merge() {
    g merge --abort >/dev/null 2>&1
    g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
}

# Called after `git merge` failed. 0 = merge completed (rerere or hook repair), 1 = aborted.
handle_merge_failure() {
    local unmerged remaining f hookonly=true rerere_on=false
    unmerged="$(g diff --name-only --diff-filter=U 2>/dev/null)"
    if [ -z "$unmerged" ]; then
        abort_merge
        status_write error merging merge_failed "$(tail -3 "$LOG_FILE" | tr '\n' ' ')"
        log_line "merge failed without conflicts; aborted"
        return 1
    fi

    [ "$(g config --get rerere.enabled 2>/dev/null)" = "true" ] && rerere_on=true
    remaining="$unmerged"
    if [ "$rerere_on" = true ]; then
        remaining="$(g rerere remaining 2>/dev/null)"
        # trust rerere only if the files really are free of conflict markers
        for f in $unmerged; do
            if grep -qE '^(<<<<<<<|>>>>>>>) ' "$FORK_DIR/$f" 2>/dev/null; then remaining="${remaining}${remaining:+$'\n'}$f"; fi
        done
        remaining="$(printf '%s\n' "$remaining" | sort -u | sed '/^$/d')"
    fi

    if [ -z "$remaining" ]; then
        log_line "rerere resolved all conflicts: $(echo $unmerged)"
        (cd "$FORK_DIR" && git add -- $unmerged) >/dev/null 2>&1
        g commit --no-edit >>"$LOG_FILE" 2>&1 && return 0
        abort_merge
        status_write error merging merge_failed "commit after rerere failed"
        return 1
    fi

    for f in $remaining; do
        case " ${HOOK_FILES[*]} " in *" $f "*) ;; *) hookonly=false ;; esac
    done
    if [ "$hookonly" = true ]; then
        log_line "conflict only in hook files ($(echo $remaining)) -> repair-hooks"
        for f in $remaining; do g checkout --theirs -- "$f" >>"$LOG_FILE" 2>&1; done
        if apply_hooks_py "$FORK_DIR" >>"$LOG_FILE" 2>&1; then
            (cd "$FORK_DIR" && git add -- $unmerged "${HOOK_FILES[@]}") >/dev/null 2>&1
            g commit --no-edit -m "Merge $REMOTE/master (serp-x hooks re-applied by anchors)" >>"$LOG_FILE" 2>&1 && return 0
        fi
    fi

    abort_merge
    status_write error merging merge_conflict "$(printf '%s\n' "$remaining" | jq -Rn -c '[inputs | select(length > 0)]')"
    log_line "merge conflict in: $(echo $remaining); aborted and reset to $FORK_PRE_COMMIT"
    return 1
}

# ---------------------------------------------------------------------------------------
# the worker
# ---------------------------------------------------------------------------------------

rollback() {
    status_write running rolling_back "" ""
    log_line "rolling back from $BACKUP_DIR"
    restore_from "$BACKUP_DIR"
    restart_shell
    wait_for_healthy || true
    g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
    notify-send -a "Serpantinum" -i dialog-warning "Обновление не удалось, выполнен откат" "Ничего не потеряно." 2>/dev/null
}

run_worker() {
    FROM_VERSION="$(state_get SERPANTINUM_VERSION)"
    status_write running preflight "" ""
    log_line "run_worker: installed=$FROM_VERSION/$(state_get SERPANTINUM_COMMIT) fork=$FORK_DIR branch=$BRANCH"

    if ! preflight; then
        status_write error preflight "$PREFLIGHT_ERR" "$FORK_DIR"
        log_line "preflight failed: $PREFLIGHT_ERR"
        return 1
    fi

    status_write running fetching "" ""
    if ! timeout 90 git -C "$FORK_DIR" fetch --quiet "$REMOTE" >>"$LOG_FILE" 2>&1; then
        status_write error fetching fetch_failed ""
        return 1
    fi

    local head_v remote_v ahead to_commit
    head_v="$(head_version)"; remote_v="$(remote_version)"; ahead="$(commits_ahead)"
    TO_VERSION="${remote_v:-$head_v}"
    TO_LABEL="$TO_VERSION"
    [ "${ahead:-0}" -gt 0 ] && TO_LABEL="$(update_label "$head_v" "$remote_v" "$ahead")"
    to_commit="$(g rev-parse --short "$REMOTE/master" 2>/dev/null)"

    # Git being up to date is not the same as the install being up to date.
    if [ "${ahead:-0}" -eq 0 ] && ! install_differs; then
        status_write ok done "" "already up to date"
        log_line "already up to date"
        printf '%s\n' "$(jq -cn '{status:"ok",message:"already up to date"}')"
        return 0
    fi

    FORK_PRE_COMMIT="$(g rev-parse HEAD)"

    status_write running dryrun "" ""
    dry_run_merge
    if [ "$DRY_CLEAN" = "false" ]; then
        log_line "dry run: conflicts in $DRY_FILES (hookOnly=$DRY_HOOK_ONLY)"
    fi

    status_write running merging "" ""
    if [ "${ahead:-0}" -gt 0 ]; then
        if ! g merge --no-edit "$REMOTE/master" >>"$LOG_FILE" 2>&1; then
            handle_merge_failure || return 1
        fi
    fi

    status_write running validating "" ""
    if ! validate_changed "$FORK_PRE_COMMIT"; then
        g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
        status_write error validating validation_failed "$VALIDATION_ERRORS"
        log_line "validation failed: $VALIDATION_ERRORS"
        return 1
    fi

    status_write running hookcheck "" ""
    if ! hooks_ok; then
        log_line "hook markers missing after merge, trying repair-hooks"
        if apply_hooks_py "$FORK_DIR" >>"$LOG_FILE" 2>&1 && hooks_ok; then
            (cd "$FORK_DIR" && git add -- "${HOOK_FILES[@]}" && git commit -q -m "Re-apply serp-x hooks by anchors") >>"$LOG_FILE" 2>&1
        else
            g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
            status_write error hookcheck hook_missing ""
            log_line "hooks missing and anchors not found; reset"
            return 1
        fi
    fi
    if ! custom_files_ok; then
        g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
        status_write error hookcheck custom_incomplete ""
        log_line "custom module incomplete after merge; reset"
        return 1
    fi

    status_write running backup "" ""
    if ! make_backup; then
        g reset --hard "$FORK_PRE_COMMIT" >/dev/null 2>&1
        status_write error backup backup_failed ""
        return 1
    fi

    status_write running syncing "" ""
    if ! mirror_dir "$FORK_DIR/bin" "$INSTALL_DIR/bin" || ! mirror_dir "$FORK_DIR/src" "$INSTALL_DIR/src"; then
        rollback
        status_write error syncing sync_failed ""
        return 1
    fi
    fix_perms

    status_write running state "" ""
    state_rewrite "$TO_VERSION" "$to_commit" "$(g rev-parse --short HEAD)"
    # one-off data migrations of the new build (never fatal: a failure here must not roll back an update)
    python3 "$INSTALL_DIR/src/scripts/custom/x_migrate.py" >>"$LOG_FILE" 2>&1 || log_line "migrate failed (ignored)"

    status_write running restarting "" ""
    restart_shell

    status_write running healthcheck "" ""
    if ! wait_for_healthy; then
        log_line "health check failed: $HEALTH_ERR -- rolling back"
        rollback
        status_write error healthcheck health_failed "$HEALTH_ERR"
        return 1
    fi

    prune_backups
    status_write ok done "" ""
    log_line "update complete: $FROM_VERSION -> $TO_LABEL"
    notify-send -a "Serpantinum" -i software-update-available "Serpantinum обновлён" "$FROM_VERSION → $TO_LABEL" 2>/dev/null
    printf '%s\n' "$(jq -cn --arg f "$FROM_VERSION" --arg t "$TO_LABEL" '{status:"ok",from:$f,to:$t}')"
    return 0
}

# ---------------------------------------------------------------------------------------
# run / detach / bootstrap
# ---------------------------------------------------------------------------------------

ALLOW_DRIFT=false

lock_acquire() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then echo $$ > "$LOCK_DIR/pid"; return 0; fi
    local p; p="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 1; fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR" 2>/dev/null && echo $$ > "$LOCK_DIR/pid"
}

cmd_run() {
    local foreground=false a
    for a in "$@"; do
        case "$a" in
            --foreground) foreground=true ;;
            --allow-drift) ALLOW_DRIFT=true ;;
        esac
    done

    if [ "$foreground" = true ]; then
        lock_acquire || { echo '{"status":"error","code":"already_running"}'; return 1; }
        trap 'rm -rf "$LOCK_DIR"' EXIT
        run_worker
        return $?
    fi

    if ! lock_acquire; then
        echo '{"status":"error","code":"already_running"}'
        return 1
    fi
    rm -rf "$LOCK_DIR"   # the worker re-acquires under its own pid

    status_write running preflight "" ""
    # The worker runs from a snapshot: a merge may rewrite this very file mid-run.
    cp -a "$SELF" "$WORKER_SNAPSHOT" 2>/dev/null
    chmod +x "$WORKER_SNAPSHOT" 2>/dev/null

    local drift_flag=""
    [ "$ALLOW_DRIFT" = true ] && drift_flag="--allow-drift"
    setsid nohup bash "$WORKER_SNAPSHOT" _worker $drift_flag </dev/null >>"$LOG_FILE" 2>&1 &
    disown
    printf '%s\n' "$(jq -cn --arg sf "$STATUS_FILE" '{status:"started",statusFile:$sf}')"
}

cmd_ack() {
    [ -f "$STATUS_FILE" ] || return 0
    local tmp="$STATUS_FILE.tmp.$$"
    jq -c '.ack = true' "$STATUS_FILE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE"
}

# release channel: numbered releases from base_url. Not wired up yet (installer stage 2+);
# without base_url the honest answer is "not-configured".
cmd_release() {
    local sub="$1" st=not-configured code=no_base_url
    if [ -n "$BASE_URL" ]; then st=error; code=release_channel_unsupported; fi
    case "$sub" in
        check) jq -cn --arg s "$st" --arg c "$code" --arg ch "$CHANNEL" --argjson ts "$(date +%s)" \
                   '{status:$s,error:$c,channel:$ch,hasUpdate:false,updateLabel:"",ts:$ts}' ;;
        run|bootstrap) status_write "$st" preflight "$code" ""; jq -cn --arg s "$st" --arg c "$code" '{status:$s,code:$c}'; return 1 ;;
    esac
}

case "${1:-}" in
    check|run|bootstrap) if [ "$CHANNEL" != dev ]; then cmd_release "$1"; exit $?; fi ;;
esac
# repair-hooks edits a working tree: with no checkout use the install (same bin/ + src/ layout)
[ "${1:-}" = repair-hooks ] && [ -z "$FORK_DIR" ] && FORK_DIR="$INSTALL_DIR"

case "${1:-}" in
    channel)       echo "$CHANNEL" ;;
    check)         cmd_check ;;
    run)           shift; cmd_run "$@" ;;
    bootstrap)     ALLOW_DRIFT=true; X_UPDATE_VERBOSE=1; shift; cmd_run --foreground --allow-drift "$@" ;;
    _worker)
        shift
        for a in "$@"; do [ "$a" = "--allow-drift" ] && ALLOW_DRIFT=true; done
        lock_acquire || exit 1
        trap 'rm -rf "$LOCK_DIR"' EXIT
        run_worker
        ;;
    status)        cat "$STATUS_FILE" 2>/dev/null || echo '{}' ;;
    ack)           cmd_ack ;;
    backups)       cmd_backups ;;
    restore)       shift; cmd_restore "$@" ;;
    repair-hooks)  cmd_repair_hooks ;;
    *)
        echo "usage: x_update.sh {channel|check|run [--foreground] [--allow-drift]|bootstrap|status|ack|backups|restore <name|latest>|repair-hooks}" >&2
        exit 1 ;;
esac
