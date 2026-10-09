#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Acceptance tests for x_update.sh against throwaway repos (a local bare "upstream", a fork
# clone and a fake install dir). Never touches the live install, ~/.config or the real repo.
#
# usage: x_update_test.sh [repo]        env: KEEP=1 keeps the temp dir
set -u

R="${1:-$(git rev-parse --show-toplevel)}"
SCRIPT="$R/src/scripts/custom/x_update.sh"
CHANGELOG="$R/src/scripts/custom/x_changelog.sh"
T="$(mktemp -d)"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
UP="$T/up.git"; FORK="$T/fork"; FI="$T/fi"; WORK="$T/upw"
pass=0; fail=0

ok()   { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# an update ends with `serpantinum-x migrate`, which looks at HOME/XDG_*: keep it all inside the temp dir
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share"
mkdir -p "$HOME"
unset SERPANTINUM_UPDATE_CHANNEL X_UPDATE_CONF SERPANTINUM_UPDATE_BASE_URL

mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify-send"; chmod +x "$T/bin/notify-send"
export PATH="$T/bin:$PATH"

export SERPANTINUM_FORK_DIR="$FORK" SERPANTINUM_FORK_BRANCH=serp-x SERPANTINUM_FORK_EXPECT_URL="$UP" \
       SERPANTINUM_INSTALL_DIR="$FI" X_UPDATE_STATE_DIR="$T/state" X_UPDATE_VERSION_FILE="$T/state/version" \
       X_UPDATE_BACKUP_ROOT="$T/backups" X_UPDATE_RUN_DIR="$T/run" X_UPDATE_SETTINGS="$T/settings.json" \
       X_UPDATE_HYPR_DIR="$T/hypr" X_UPDATE_NO_RESTART=1 X_UPDATE_CACHE_DIR="$T/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git_() { git -C "$FORK" "$@"; }
st() { jq -r "$1" "$T/state/status.json"; }

# --- fixture ----------------------------------------------------------------------------
BASE="$(git -C "$R" merge-base HEAD origin/master 2>/dev/null || git -C "$R" rev-parse HEAD~1)"
TIP="$(git -C "$R" rev-parse HEAD)"
VER="$(git -C "$R" show "$BASE:version.txt" 2>/dev/null | tr -d '[:space:]')"; VER="${VER:-2.2.4}"
rm -rf "$UP"; git clone -q --bare --no-hardlinks "$R" "$UP"
git -C "$UP" update-ref refs/heads/master "$BASE"
git -C "$UP" update-ref refs/heads/serp-x "$TIP"

reset_world() {
    rm -rf "$FORK" "$FI" "$WORK" "$T/state" "$T/backups" "$T/run"
    git -C "$UP" update-ref refs/heads/master "$BASE"
    git clone -q --no-hardlinks "$UP" "$FORK"
    git_ checkout -q -b local-serp-x origin/serp-x 2>/dev/null
    git_ branch -q -m local-serp-x serp-x 2>/dev/null || git_ checkout -q serp-x
    git_ remote set-url origin "$UP"
    mkdir -p "$FI"; cp -a "$FORK/bin" "$FI/bin"; cp -a "$FORK/src" "$FI/src"
    mkdir -p "$T/state"; printf 'SERPANTINUM_VERSION="%s"\nSERPANTINUM_COMMIT="base"\nSERPANTINUM_FORK_COMMIT="base"\nENABLE_TELEMETRY="true"\n' "$VER" > "$T/state/version"
    mkdir -p "$T/hypr/config"; echo 'require "x"' > "$T/hypr/hyprland.lua"; echo '{"a":1}' > "$T/settings.json"
    PRE="$(git_ rev-parse HEAD)"
    rm -rf "$T/fi.snapshot"; cp -a "$FI" "$T/fi.snapshot"
}

upstream_commit() {   # upstream_commit <msg> <script run inside a clone of master>
    rm -rf "$WORK"; git clone -q --no-hardlinks "$UP" "$WORK"
    git -C "$WORK" checkout -q master
    (cd "$WORK" && eval "$2") >/dev/null 2>&1
    git -C "$WORK" add -A; git -C "$WORK" commit -q -m "$1"
    git -C "$WORK" push -q origin master
}

run_update() { bash "$SCRIPT" run --foreground "$@" > "$T/out.json" 2> "$T/err.txt"; echo $? > "$T/rc"; RC="$(cat "$T/rc")"; }

echo "== (a) clean merge -> mirror -> state"
reset_world
upstream_commit "feat: new popout" 'printf "import QtQuick\nItem {}\n" > src/quickshell/popouts/NewThing.qml; echo "- feat: extra" >> CHANGELOG.md'
CK="$(bash "$SCRIPT" check)"
check "check: hasUpdate=true" '[ "$(jq -r .hasUpdate <<< "$CK")" = true ]'
check "check: label '$VER + 1'" '[ "$(jq -r .updateLabel <<< "$CK")" = "$VER + 1" ]'
check "check: dry run clean" '[ "$(jq -r .dryRun.clean <<< "$CK")" = true ]'
check "check: no drift" '[ "$(jq -r .drift <<< "$CK")" = false ]'
run_update
check "run exits 0" '[ "$RC" = 0 ]'
check "status ok/done" '[ "$(st .status)" = ok ] && [ "$(st .phase)" = done ]'
check "upstream commit merged" 'git_ merge-base --is-ancestor origin/master HEAD'
check "install mirrors fork (bin+src)" 'diff -r --no-dereference "$FORK/src" "$FI/src" >/dev/null && diff -r --no-dereference "$FORK/bin" "$FI/bin" >/dev/null'
check "new file installed" '[ -f "$FI/src/quickshell/popouts/NewThing.qml" ]'
check "state file updated" 'grep -q "^SERPANTINUM_FORK_COMMIT=\"$(git_ rev-parse --short HEAD)\"" "$T/state/version" && ! grep -q TELEMETRY "$T/state/version"'
check "backup created with extras" 'ls -d "$T"/backups/*/ >/dev/null 2>&1 && ls "$T"/backups/*/extra/settings.json "$T"/backups/*/extra/hyprland.lua >/dev/null 2>&1'
check "check afterwards: up to date" '[ "$(bash "$SCRIPT" check | jq -r .hasUpdate)" = false ]'
BK="$(bash "$SCRIPT" backups)"
check "backups json lists 1" '[ "$(jq length <<< "$BK")" = 1 ] && [ "$(jq -r ".[0].from" <<< "$BK")" = "$VER" ]'
echo "-- restore latest"
bash "$SCRIPT" restore latest >/dev/null
check "restore -> byte-identical to pre-update install" 'diff -r --no-dereference "$T/fi.snapshot" "$FI" >/dev/null'

echo "== (b) conflict in a non-hook file (user's own edit vs upstream) -> aborted, files listed"
reset_world
(cd "$FORK" && echo "OURS: my own tweak" >> README.md && git commit -qam "ours: tweak README")
PRE="$(git_ rev-parse HEAD)"; rm -rf "$T/fi.snapshot"; cp -a "$FI" "$T/fi.snapshot"
upstream_commit "docs: theirs edits README" 'echo "THEIRS: upstream line" >> README.md'
CK="$(bash "$SCRIPT" check)"
check "check: dry run reports conflict + file" '[ "$(jq -r .dryRun.clean <<< "$CK")" = false ] && jq -e ".dryRun.files | index(\"README.md\")" <<< "$CK" >/dev/null && [ "$(jq -r .dryRun.hookOnly <<< "$CK")" = false ]'
run_update
check "run exits 1" '[ "$RC" = 1 ]'
check "status error merge_conflict" '[ "$(st .code)" = merge_conflict ]'
check "UI-visible file list in detail" 'st .detail | jq -e "index(\"README.md\")" >/dev/null'
check "tree reset: HEAD unchanged" '[ "$(git_ rev-parse HEAD)" = "$PRE" ]'
check "tree clean, no merge in progress" '[ -z "$(git_ status --porcelain --untracked-files=no)" ] && [ ! -e "$(git_ rev-parse --git-path MERGE_HEAD)" ]'
check "install untouched" 'diff -r --no-dereference "$T/fi.snapshot" "$FI" >/dev/null'

echo "== (c) conflict only in hook lines -> repaired automatically"
reset_world
upstream_commit "fix: upstream touches the update button" \
    'sed -i "s/visible: Updater.updateAvailable \&\& !root.searchActive/visible: Updater.updateAvailable \&\& !root.searchActive \&\& true/" src/quickshell/guide/GuidePopup.qml'
CK="$(bash "$SCRIPT" check)"
check "check: hookOnly conflict" '[ "$(jq -r .dryRun.clean <<< "$CK")" = false ] && [ "$(jq -r .dryRun.hookOnly <<< "$CK")" = true ]'
run_update
check "run exits 0" '[ "$RC" = 0 ]'
check "upstream change kept" 'grep -q "XUpdate.updateAvailable) && !root.searchActive && true" "$FORK/src/quickshell/guide/GuidePopup.qml"'
check "hooks intact" 'grep -q "serp-x hook" "$FORK/src/quickshell/guide/GuidePopup.qml" && grep -q "XUpdate.buttonText" "$FORK/src/quickshell/guide/GuidePopup.qml" && grep -q "serp-x hook" "$FORK/src/quickshell/guide/AboutTab.qml"'
check "merge commit exists, tree clean" '[ -z "$(git_ status --porcelain --untracked-files=no)" ] && git_ merge-base --is-ancestor origin/master HEAD'
check "install mirrors fork" 'diff -r --no-dereference "$FORK/src" "$FI/src" >/dev/null'

echo "== (c2) repair-hooks re-creates the hook on a pristine upstream file"
rm -rf "$T/pristine"; mkdir -p "$T/pristine/src/quickshell/guide" "$T/pristine/src/quickshell/screenshot"
HOOKED=(guide/GuidePopup.qml guide/AboutTab.qml Shell.qml screenshot/ScreenshotOverlay.qml)
for f in "${HOOKED[@]}"; do git -C "$UP" show "$BASE:src/quickshell/$f" > "$T/pristine/src/quickshell/$f"; done
mkdir -p "$T/pristine/bin"; git -C "$UP" show "$BASE:bin/serpantinum" > "$T/pristine/bin/serpantinum"
mkdir -p "$T/pristine/src/scripts"; git -C "$UP" show "$BASE:src/scripts/updater.py" > "$T/pristine/src/scripts/updater.py"
SERPANTINUM_FORK_DIR="$T/pristine" bash "$SCRIPT" repair-hooks >/dev/null
for f in "${HOOKED[@]}"; do
    check "repair-hooks: $f identical to the committed hook version" \
        'git -C "$UP" show "serp-x:src/quickshell/'$f'" | diff -q - "$T/pristine/src/quickshell/'$f'" >/dev/null'
done
check "repair-hooks: updater.py identical to the committed hook version" \
    'git -C "$UP" show "serp-x:src/scripts/updater.py" | diff -q - "$T/pristine/src/scripts/updater.py" >/dev/null'
check "repair-hooks: no curl|eval left in AboutTab, updater.py has the marker" \
    '! grep -q "install/install.sh" "$T/pristine/src/quickshell/guide/AboutTab.qml" && grep -q "serp-x hook" "$T/pristine/src/scripts/updater.py"'
check "repair-hooks: bin/serpantinum identical to the committed hook version" \
    'git -C "$UP" show "serp-x:bin/serpantinum" | diff -q - "$T/pristine/bin/serpantinum" >/dev/null'
SERPANTINUM_FORK_DIR="$T/pristine" bash "$SCRIPT" repair-hooks >/dev/null
check "repair-hooks is idempotent" 'git -C "$UP" show "serp-x:src/quickshell/guide/GuidePopup.qml" | diff -q - "$T/pristine/src/quickshell/guide/GuidePopup.qml" >/dev/null'
echo 'Item { }' > "$T/pristine/src/quickshell/guide/GuidePopup.qml"
SERPANTINUM_FORK_DIR="$T/pristine" bash "$SCRIPT" repair-hooks > "$T/rh.json" 2>/dev/null; RC=$?
check "repair-hooks fails loudly when anchors are gone" '[ "$RC" != 0 ] && [ "$(jq -r .code "$T/rh.json")" = hook_anchor_missing ]'

echo "== (c3) upstream updater.py hook: no network, never offers an upstream update"
UPD="$T/updhook"; rm -rf "$UPD"; mkdir -p "$UPD/bin" "$UPD/src/scripts"
cp "$R/src/scripts/updater.py" "$UPD/src/scripts/updater.py"; : > "$UPD/bin/serpantinum-x"
UJ="$(HTTPS_PROXY=http://127.0.0.1:1 HTTP_PROXY=http://127.0.0.1:1 python3 "$UPD/src/scripts/updater.py" --state-dir "$T/updstate")"; RC=$?
check "updater.py with serpantinum-x next to it: exit 0, has_update=false, remote=local" '[ "$RC" = 0 ] && [ "$(jq -r .has_update <<< "$UJ")" = false ] && [ "$(jq -r .remote <<< "$UJ")" = "$(jq -r .local <<< "$UJ")" ]'
check "hooks_ok-style grep: marker in updater.py" 'grep -q "serp-x hook" "$R/src/scripts/updater.py"'

echo "== (d) validation failure -> reset, install untouched"
reset_world
upstream_commit "fix: broken language json" 'echo "{" > src/assets/languages/zz.json'
run_update
check "run exits 1" '[ "$RC" = 1 ]'
check "status validation_failed" '[ "$(st .code)" = validation_failed ] && st .detail | grep -q zz.json'
check "HEAD reset to pre-merge" '[ "$(git_ rev-parse HEAD)" = "$PRE" ]'
check "install untouched" 'diff -r --no-dereference "$T/fi.snapshot" "$FI" >/dev/null'

echo "== (e) simulated health failure -> rollback restores the install byte-identically"
reset_world
upstream_commit "feat: new popout" 'printf "import QtQuick\nItem {}\n" > src/quickshell/popouts/NewThing.qml'
X_UPDATE_FAKE_HEALTH=fail run_update
check "run exits 1" '[ "$RC" = 1 ]'
check "status health_failed" '[ "$(st .code)" = health_failed ]'
check "install byte-identical after rollback (diff -r)" 'diff -r --no-dereference "$T/fi.snapshot" "$FI" >/dev/null'
check "version state restored" 'grep -q "^SERPANTINUM_COMMIT=\"base\"" "$T/state/version"'
check "fork reset to pre-update" '[ "$(git_ rev-parse HEAD)" = "$PRE" ]'

echo "== (f) bootstrap: stock install -> serp-x"
reset_world
rm -rf "$FI"; mkdir -p "$FI"
rm -rf "$T/stock"; mkdir -p "$T/stock"; git -C "$UP" archive master bin src | tar -x -C "$T/stock"
cp -a "$T/stock/bin" "$FI/bin"; cp -a "$T/stock/src" "$FI/src"
CK="$(bash "$SCRIPT" check)"
check "check sees drift" '[ "$(jq -r .drift <<< "$CK")" = true ]'
bash "$SCRIPT" run --foreground > "$T/out.json" 2>/dev/null; RC=$?
check "plain run refuses on drift" '[ "$RC" = 1 ] && [ "$(st .code)" = drift ]'
bash "$SCRIPT" bootstrap > "$T/out.json" 2>/dev/null; RC=$?
check "bootstrap exits 0" '[ "$RC" = 0 ]'
check "install now equals fork" 'diff -r --no-dereference "$FORK/src" "$FI/src" >/dev/null && [ -f "$FI/src/quickshell/custom/GuideExtensions.qml" ]'
check "backup holds the stock install" 'diff -r --no-dereference "$T/stock/src" "$(ls -d "$T"/backups/*/ | head -1)src" >/dev/null'

echo "== (h) rerere: a conflict resolved once by hand is resolved automatically next time"
reset_world
git_ config rerere.enabled true     # throwaway clone only
(cd "$FORK" && echo "OURS: my own tweak" >> README.md && git commit -qam "ours: tweak README")
PRE="$(git_ rev-parse HEAD)"; rm -rf "$T/fi.snapshot"; cp -a "$FI" "$T/fi.snapshot"
upstream_commit "docs: theirs edits README" 'echo "THEIRS: upstream line" >> README.md'
git_ fetch -q origin
git_ merge origin/master >/dev/null 2>&1                      # conflicts; rerere records the preimage
printf '%s\n' "$(git_ show origin/master:README.md)" "OURS: my own tweak" > "$FORK/README.md"
git_ add README.md; git_ commit -q --no-edit                  # rerere records the resolution
git_ reset -q --hard "$PRE"                                   # undo; the rr-cache stays
run_update
check "run exits 0 (no manual step)" '[ "$RC" = 0 ]'
check "log says rerere resolved it" 'grep -q "rerere resolved all conflicts" "$T/state/update.log"'
check "merged, resolution applied" 'git_ merge-base --is-ancestor origin/master HEAD && grep -q "THEIRS: upstream line" "$FORK/README.md" && grep -q "OURS: my own tweak" "$FORK/README.md" && ! grep -q "^<<<<<<<" "$FORK/README.md"'

echo "== (g) wrong branch / dirty tree preflight"
reset_world
git_ checkout -q -b other
run_update
check "wrong_branch refused" '[ "$RC" = 1 ] && [ "$(st .code)" = wrong_branch ]'
git_ checkout -q serp-x; echo "x" >> "$FORK/CHANGELOG.md"
run_update
check "dirty_tree refused" '[ "$RC" = 1 ] && [ "$(st .code)" = dirty_tree ]'

echo "== channels"
nofork() { env -u SERPANTINUM_FORK_DIR -u SERPANTINUM_FORK_EXPECT_URL "$@"; }
CONF="$XDG_CONFIG_HOME/serpantinum-x/update.toml"
rm -f "$CONF"
# explicit SERPANTINUM_FORK_DIR (the whole suite above) means channel dev
check "channel: env fork dir -> dev" '[ "$(bash "$SCRIPT" channel)" = dev ]'
check "channel: nothing configured -> release" '[ "$(nofork bash "$SCRIPT" channel)" = release ]'
CK="$(nofork bash "$SCRIPT" check)"
check "release without base_url: check says not-configured" '[ "$(jq -r .status <<< "$CK")" = not-configured ] && [ "$(jq -r .hasUpdate <<< "$CK")" = false ]'
nofork bash "$SCRIPT" run --foreground > "$T/out.json" 2>/dev/null; RC=$?
check "release without base_url: run refuses, status not-configured" '[ "$RC" = 1 ] && [ "$(st .status)" = not-configured ]'
mkdir -p "$(dirname "$CONF")"
printf 'channel = "dev"  # developer machine\nfork_dir = "%s"\n' "$FORK" > "$CONF"
check "update.toml channel=dev is honoured" '[ "$(nofork bash "$SCRIPT" channel)" = dev ]'
CK="$(nofork env SERPANTINUM_FORK_EXPECT_URL="$UP" bash "$SCRIPT" check)"
check "dev from update.toml: fork_dir is used (git flow works)" '[ "$(jq -r .status <<< "$CK")" = ok ] && [ "$(jq -r .forkDir <<< "$CK")" = "$FORK" ]'
printf 'channel = "git"\nfork_dir = "~/nowhere"\n' > "$CONF"
check "git is an alias of dev" '[ "$(nofork bash "$SCRIPT" channel)" = dev ]'
rm -f "$CONF"
check "release doctor: no repo failure without a checkout" \
      '! nofork bash "$R/bin/serpantinum-x" doctor --json 2>/dev/null | jq -e ".[] | select(.id|startswith(\"repo\")) | select(.level==\"fail\")" >/dev/null'

echo "== doctor: ru/en, serpantinum-x symlink"
DR="$T/dr"; rm -rf "$DR"; mkdir -p "$DR/home/.local/bin"
dctr() { nofork env HOME="$DR/home" X_LANG="$1" X_BIN_LINK="$DR/home/.local/bin/serpantinum-x" bash "$R/bin/serpantinum-x" doctor --json 2>/dev/null; }
check "doctor en: english text, x_symlink warn when link is missing" \
      '[ "$(dctr en | jq -r ".[] | select(.id==\"x_symlink\") | .level")" = warn ] && dctr en | jq -r ".[] | select(.id==\"backup\") | .message" | grep -q "no backups yet"'
check "doctor ru: russian text" 'dctr ru | jq -r ".[] | select(.id==\"backup\") | .message" | grep -q "резервных копий"'
ln -s "$R/bin/serpantinum-x" "$DR/home/.local/bin/serpantinum-x"
check "doctor: x_symlink ok with a good link" '[ "$(dctr en | jq -r ".[] | select(.id==\"x_symlink\") | .level")" = ok ]'
rm -f "$DR/home/.local/bin/serpantinum-x"; ln -s "$DR/nowhere" "$DR/home/.local/bin/serpantinum-x"
check "doctor: x_symlink warn with a broken link" '[ "$(dctr en | jq -r ".[] | select(.id==\"x_symlink\") | .level")" = warn ]'

echo "== doctor: modules that were not installed are not checked"
MJ="$T/modules.json"
dmod() { nofork env HOME="$DR/home" X_LANG=en X_MODULES_FILE="$MJ" bash "$R/bin/serpantinum-x" doctor --json 2>/dev/null; }
echo '{"enabled":["core","hotkeys"]}' > "$MJ"
check "doctor: minimal install has no VPN/Servers/Commands rows" '! dmod | jq -e ".[] | select(.message|test(\"^(VPN|Servers|Commands)\"))" >/dev/null'
echo '{"enabled":["core","vpn","servers","commands"]}' > "$MJ"
check "doctor: installed modules are still checked" 'dmod | jq -e ".[] | select(.message|test(\"^VPN\"))" >/dev/null'
rm -f "$MJ"
check "doctor: no modules.json = all modules checked" 'dmod | jq -e ".[] | select(.message|test(\"^VPN\"))" >/dev/null'

echo "== mirror/drift ignore __pycache__"
eval "$(sed -n '/^same_file()/,/^install_differs()/p' "$SCRIPT" | sed '$d')"
MS="$T/ms"; MD="$T/md"; rm -rf "$MS" "$MD"; mkdir -p "$MS/a/__pycache__" "$MD"
echo x > "$MS/a/f.py"; echo c > "$MS/a/__pycache__/f.pyc"
mirror_dir "$MS" "$MD"
check "mirror_dir: __pycache__ is not copied" '[ -f "$MD/a/f.py" ] && [ ! -e "$MD/a/__pycache__" ]'
mkdir -p "$MD/a/__pycache__"; echo y > "$MD/a/__pycache__/g.pyc"
check "mirror_differs: stray __pycache__ is not drift" '! mirror_differs "$MS" "$MD"'

echo "== changelog parser"
VJ="$(SERPANTINUM_FORK_DIR="$FORK" bash "$CHANGELOG" versions)"
# the parser reads the changelog of the fork's origin/master, so count in that very text
CLTXT="$(git -C "$FORK" show origin/master:CHANGELOG.md 2>/dev/null || git -C "$FORK" show HEAD:CHANGELOG.md)"
nver="$(grep -c '^### ' <<< "$CLTXT")"
check "sections parsed for all $nver versions" '[ "$(jq length <<< "$VJ")" = "$nver" ]'
check "item counts match the markdown" '[ "$(jq "[.[].count] | add" <<< "$VJ")" = "$(grep -c "^- " <<< "$CLTXT")" ]'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
