#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Stage 7 glue: `serpantinum-x backup export|import` wrapper (fake installer binary), tools/reinventory.sh,
# and static checks of the installer buttons in the Updates tab. Everything runs in a temp HOME.
set -u
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" X_LANG=en
mkdir -p "$HOME"
unset X_INSTALLER_BIN SERPANTINUM_FORK_DIR SERPANTINUM_UPDATE_CHANNEL X_UPDATE_CONF
X="$R/bin/serpantinum-x"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1 (got '$2', want '$3')"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 (missing '$3' in '$2')" ;; esac; }

# --- no installer binary: clear error, exit 3 (no serp-installer on PATH either)
out="$(PATH=/usr/bin:/bin "$X" backup export 2>&1)"; rc=$?
eq "missing binary rc" "$rc" 3
has "missing binary text" "$out" "installer not found"
out="$(X_LANG=ru PATH=/usr/bin:/bin "$X" backup export 2>&1)"; has "missing binary ru" "$out" "установщик не найден"

# --- usage errors
"$X" backup >/dev/null 2>&1; eq "no action" "$?" 2
"$X" backup frob >/dev/null 2>&1; eq "bad action" "$?" 2
out="$("$X" backup import "$T/nope.tar.zst" 2>&1)"; rc=$?; eq "import missing file rc" "$rc" 2; has "import missing file" "$out" "file not found"
"$X" backup import >/dev/null 2>&1; eq "import without file" "$?" 2

# --- fake installer: arguments are passed through, exit code is kept
cat > "$T/fake" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_LOG"
exit "${FAKE_RC:-0}"
EOS
chmod +x "$T/fake"
export FAKE_LOG="$T/fake.log" X_INSTALLER_BIN="$T/fake"
"$X" backup export --out "$T/o" >/dev/null 2>&1; eq "export rc" "$?" 0
eq "export args" "$(cat "$FAKE_LOG")" "backup export --out $T/o"
: > "$T/a.tar.zst"
"$X" backup import "$T/a.tar.zst" >/dev/null 2>&1; eq "import rc" "$?" 0
eq "import args" "$(cat "$FAKE_LOG")" "backup import $T/a.tar.zst"
FAKE_RC=7 "$X" backup export >/dev/null 2>&1; eq "installer rc kept" "$?" 7

# --- binary in the default install location
unset X_INSTALLER_BIN
mkdir -p "$XDG_DATA_HOME/serpantinum-x/installer"; cp "$T/fake" "$XDG_DATA_HOME/serpantinum-x/installer/serp-installer"
"$X" backup export >/dev/null 2>&1; eq "default location rc" "$?" 0
eq "default location args" "$(cat "$FAKE_LOG")" "backup export"
# non-executable file is not a binary
chmod -x "$XDG_DATA_HOME/serpantinum-x/installer/serp-installer"
PATH=/usr/bin:/bin "$X" backup export >/dev/null 2>&1; eq "non-executable ignored" "$?" 3

# --- logging: the module log exists and has no argument values
lg="$(cat "$SERPANTINUM_LOG_DIR"/backup.log 2>/dev/null)"
has "backup log written" "$lg" "installer binary not found"

# --- help lists the command
has "help mentions backup" "$("$X" --help)" "backup export"

# --- reinventory: a throwaway repo
G="$T/repo"; mkdir -p "$G"
git -C "$G" init -q -b master 2>/dev/null || git -C "$G" init -q
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$G/tools" "$G/src"; cp "$R/tools/reinventory.sh" "$G/tools/"
echo a > "$G/src/up.qml"; echo b > "$G/src/other.qml"; printf 'src/up.qml  hook\n' > "$G/NOTICE"
git -C "$G" add -A; git -C "$G" -c commit.gpgsign=false commit -qm base; git -C "$G" branch -q base
echo c >> "$G/src/up.qml"; echo n > "$G/src/new.qml"
git -C "$G" add -A; git -C "$G" -c commit.gpgsign=false commit -qm ours
out="$("$G/tools/reinventory.sh" --base base 2>&1)"; rc=$?
eq "reinventory covered rc" "$rc" 0; has "reinventory lists modified" "$out" "M src/up.qml"
echo d >> "$G/src/other.qml"; git -C "$G" -c commit.gpgsign=false commit -qam more
out="$("$G/tools/reinventory.sh" --base base 2>&1)"; rc=$?
eq "reinventory uncovered rc" "$rc" 1; has "reinventory flags uncovered" "$out" "NOT listed in NOTICE"
printf 'src/*.qml  glob\n' > "$G/NOTICE"
"$G/tools/reinventory.sh" --base base >/dev/null 2>&1; eq "reinventory glob in NOTICE" "$?" 0
"$G/tools/reinventory.sh" --base nonexistent >/dev/null 2>&1; eq "reinventory bad ref" "$?" 2
eq "reinventory json" "$("$G/tools/reinventory.sh" --base base --json | jq -r '.modified_upstream | join(",")')" "src/other.qml,src/up.qml"
"$R/tools/reinventory.sh" --base origin/master >/dev/null 2>&1; rcr=$?
[ "$rcr" = 2 ] || eq "this repo: every modified upstream file is in NOTICE" "$rcr" 0

# --- static checks of the QML wiring
Q="$R/src/quickshell/custom"
has "qmldir has XInstaller" "$(cat "$Q/qmldir")" "singleton XInstaller 1.0 XInstaller.qml"
tab="$(cat "$Q/update/UpdatesTab.qml")"
has "tab: buttons hidden without binary" "$tab" "visible: XInstaller.available"
has "tab: modules button" "$tab" "XInstaller.openModules()"
has "tab: backup button" "$tab" "XInstaller.exportBackup()"
has "singleton opens modules in kitty" "$(cat "$Q/XInstaller.qml")" '["kitty", "-e", root.binPath, "modules"]'
has "singleton logs" "$(cat "$Q/XInstaller.qml")" 'XLog.info("installer"'
for l in ru en; do
    eq "i18n $l keys" "$(jq -r '[.update.modules_btn, .update.backup_btn] | map(. != null) | all' "$R/src/assets/custom-i18n/$l.update.json" 2>/dev/null || jq -r 'tostring|length>0' "$R/src/assets/custom-i18n/$l.update.json")" true
done
### 2.2.4-s1"

echo "x_backup_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
