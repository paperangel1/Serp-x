#!/usr/bin/env bash
# Tests of the `release` channel of x_update.sh against a local fake release server
# (python http.server on 127.0.0.1), a throwaway GNUPGHOME and a temp HOME. Touches nothing real.
#   good release / bad sha256 / bad signature / foreign key / not newer / unreachable / rollback /
#   GitHub-style API metadata / unsafe archive
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
set -u
R="${1:-$(git rev-parse --show-toplevel)}"
SCRIPT="$R/src/scripts/custom/x_update.sh"
T="$(mktemp -d)"
srv=""
cleanup() {
    [ -n "$srv" ] && kill "$srv" 2>/dev/null
    GNUPGHOME="$T/gpg1" gpgconf --kill all >/dev/null 2>&1
    GNUPGHOME="$T/gpg2" gpgconf --kill all >/dev/null 2>&1
    [ -n "${KEEP:-}" ] || rm -rf "$T"
}
trap cleanup EXIT
pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share"
mkdir -p "$HOME"
unset SERPANTINUM_UPDATE_CHANNEL X_UPDATE_CONF SERPANTINUM_UPDATE_BASE_URL SERPANTINUM_FORK_DIR SERPANTINUM_UPDATE_PUBKEY_FPR X_UPDATE_API_URL
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/notify-send"; chmod +x "$T/bin/notify-send"
export PATH="$T/bin:$PATH"

FI="$T/fi"
export SERPANTINUM_INSTALL_DIR="$FI" X_UPDATE_STATE_DIR="$T/state" X_UPDATE_VERSION_FILE="$T/state/version" \
       X_UPDATE_BACKUP_ROOT="$T/backups" X_UPDATE_RUN_DIR="$T/run" X_UPDATE_SETTINGS="$T/settings.json" \
       X_UPDATE_HYPR_DIR="$T/hypr" X_UPDATE_NO_RESTART=1 X_UPDATE_NO_RECONCILE=1 X_UPDATE_CACHE_DIR="$T/cache"
st() { jq -r "$1" "$T/state/status.json"; }

# ---- keys ------------------------------------------------------------------------------
mkkey() { mkdir -m 700 "$1"; GNUPGHOME="$1" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$2 <$2@test.invalid>" ed25519 sign never >/dev/null 2>&1
    GNUPGHOME="$1" gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'; }
FPR="$(mkkey "$T/gpg1" release)"; FPR2="$(mkkey "$T/gpg2" attacker)"
[ ${#FPR} = 40 ] && [ ${#FPR2} = 40 ] || { echo "cannot make test keys"; exit 1; }
GNUPGHOME="$T/gpg1" gpg --batch --armor --export "$FPR" > "$T/release.asc"
GNUPGHOME="$T/gpg2" gpg --batch --armor --export "$FPR2" > "$T/attacker.asc"
export SERPANTINUM_UPDATE_PUBKEY_FPR="$FPR"

# ---- fake releases ---------------------------------------------------------------------
W="$T/www"; mkdir -p "$W"
mk_payload() {   # mk_payload <dir> <tag> [marker]  -> tarball in <dir>
    local d="$1" tag="$2" mk="${3:-brand-new}" s="$T/stage-$2"
    rm -rf "$s"; mkdir -p "$s/bin" "$s/src/quickshell" "$s/src/scripts/custom" "$s/installer/manifests" "$d"
    printf '#!/bin/sh\necho x\n' > "$s/bin/serpantinum-x"; chmod +x "$s/bin/serpantinum-x"
    echo "Item {}" > "$s/src/quickshell/Shell.qml"
    echo "$mk" > "$s/src/marker"; echo '{"a":1}' > "$s/src/data.json"; echo null > "$s/src/null.json"; echo 'echo hi' > "$s/src/scripts/custom/t.sh"
    echo "2.2.5" > "$s/version.txt"; ln -s ../version.txt "$s/src/version.txt"
    tar -C "$s" --create --sort=name --owner=0 --group=0 bin src version.txt installer | zstd -q -o "$d/serp-x-$tag.tar.zst"
}
sign_release() {   # sign_release <dir> <tag> [gnupghome] [keyfile]
    local d="$1" tag="$2" gh="${3:-$T/gpg1}" kf="${4:-$T/release.asc}"
    (cd "$d" && sha256sum "serp-x-$tag.tar.zst" > SHA256SUMS)
    rm -f "$d/SHA256SUMS.sig"; GNUPGHOME="$gh" gpg --batch --yes --detach-sign -o "$d/SHA256SUMS.sig" "$d/SHA256SUMS" 2>/dev/null
    cp "$kf" "$d/serp-x-release.asc"
}
mk_release() { mk_payload "$W/$1" "$1" "${2:-brand-new}"; sign_release "$W/$1" "$1" "${3:-$T/gpg1}" "${4:-$T/release.asc}"; }

mk_release v2.2.5-s1
mk_release v2.2.5-s2
mk_release v2.3.0-badsha;  echo tampered >> "$W/v2.3.0-badsha/serp-x-v2.3.0-badsha.tar.zst"
mk_release v2.3.0-badsig;  echo "deadbeef  serp-x-v2.3.0-badsig.tar.zst" >> "$W/v2.3.0-badsig/SHA256SUMS"
mk_release v2.3.0-attacker brand-new "$T/gpg2" "$T/attacker.asc"
mk_release v2.3.0-attacker2 brand-new "$T/gpg2" "$T/release.asc"      # genuine key file, foreign signature
# a correctly signed archive with a path-traversal member
mkdir -p "$W/v2.3.0-evil" "$T/evil/x"; echo pwn > "$T/evil/x/f"
tar -C "$T/evil/x" --create --transform 's,^f$,../escape,' f | zstd -q -o "$W/v2.3.0-evil/serp-x-v2.3.0-evil.tar.zst"
sign_release "$W/v2.3.0-evil" v2.3.0-evil
# a correctly signed archive with a broken json (validation must stop it)
mk_payload "$W/v2.3.0-broken" v2.3.0-broken; (cd "$T/stage-v2.3.0-broken" && echo '{oops' > src/data.json &&
    tar --create --sort=name --owner=0 --group=0 bin src version.txt | zstd -qf -o "$W/v2.3.0-broken/serp-x-v2.3.0-broken.tar.zst"); sign_release "$W/v2.3.0-broken" v2.3.0-broken
# GitHub-style layout: <base>/download/<tag>/F and an API json
mkdir -p "$W/o/r/releases/download" "$W/api"
cp -r "$W/v2.2.5-s1" "$W/o/r/releases/download/v2.2.5-s1"
echo '{"tag_name":"v2.2.5-s1","draft":false,"prerelease":false}' > "$W/api/latest"

PORT="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$W" > "$T/http.log" 2>&1 &
srv=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/api/latest" >/dev/null 2>&1 && break; sleep 0.1; done
BASE="http://127.0.0.1:$PORT"
export SERPANTINUM_UPDATE_BASE_URL="$BASE"

reset_world() {
    rm -rf "$FI" "$T/state" "$T/backups" "$T/run" "$T/snap"
    mkdir -p "$FI/bin" "$FI/src/quickshell" "$T/state"
    echo old > "$FI/bin/serpantinum-x"; echo old > "$FI/src/marker"; echo "Item {}" > "$FI/src/quickshell/Shell.qml"
    printf 'SERPANTINUM_VERSION="%s"\nSERPANTINUM_COMMIT="base"\nSERPANTINUM_FORK_COMMIT="base"\n' "${1:-2.2.4}" > "$T/state/version"
    cp -a "$FI" "$T/snap"
}
latest() { echo "$1" > "$W/latest.txt"; }
upd() { env "$@" bash "$SCRIPT" run --foreground > "$T/out.json" 2>/dev/null; RC=$?; }
untouched() { diff -r "$FI" "$T/snap" >/dev/null 2>&1; }

echo "== channel / check"
check "channel: default is release" '[ "$(bash "$SCRIPT" channel)" = release ]'
reset_world; latest v2.2.5-s1
CK="$(bash "$SCRIPT" check)"
check "check: update available (2.2.4 -> v2.2.5-s1)" '[ "$(jq -r .status <<< "$CK")" = ok ] && [ "$(jq -r .hasUpdate <<< "$CK")" = true ] && [ "$(jq -r .updateLabel <<< "$CK")" = 2.2.5-s1 ]'
check "check: read-only (install untouched)" untouched
CK="$(SERPANTINUM_UPDATE_PUBKEY_FPR=bogus bash "$SCRIPT" check)"
check "check: invalid pubkey_fpr -> not-configured" '[ "$(jq -r .status <<< "$CK")" = not-configured ]'

echo "== good release"
reset_world; latest v2.2.5-s1
upd; check "good: exit 0, status ok/done" '[ "$RC" = 0 ] && [ "$(st .status)" = ok ] && [ "$(st .phase)" = done ]'
check "good: payload mirrored into the install" '[ "$(cat "$FI/src/marker")" = brand-new ] && [ -f "$FI/src/data.json" ]'
check "good: state records version and release" 'grep -q "SERPANTINUM_VERSION=\"2.2.5\"" "$T/state/version" && grep -q "SERPANTINUM_RELEASE=\"2.2.5-s1\"" "$T/state/version"'
check "good: a backup of the old install exists" '[ "$(cat "$(ls -d "$T"/backups/*/ | head -1)src/marker")" = old ]'
check "good: no temp download dirs left" '[ -z "$(ls -d "$T"/state/dl.* 2>/dev/null)" ]'
CK="$(bash "$SCRIPT" check)"
check "good: check afterwards says no update" '[ "$(jq -r .hasUpdate <<< "$CK")" = false ] && [ "$(jq -r .installedVersion <<< "$CK")" = 2.2.5-s1 ]'
upd; check "same release again: ok, already up to date" '[ "$RC" = 0 ] && [ "$(st .detail)" = "already up to date" ]'
latest v2.2.5-s2; upd
check "next release s2 installs over s1 (2.2.5-s1 < 2.2.5-s2)" '[ "$RC" = 0 ] && grep -q "SERPANTINUM_RELEASE=\"2.2.5-s2\"" "$T/state/version"'
latest v2.2.5-s1; upd
check "older release (s1 after s2): refused, not_newer" '[ "$RC" = 1 ] && [ "$(st .code)" = not_newer ]'

echo "== bad sha256 / signature / key / archive"
for tcase in "v2.3.0-badsha sha256_mismatch" "v2.3.0-badsig bad_signature" "v2.3.0-attacker key_mismatch" "v2.3.0-attacker2 bad_signature" "v2.3.0-evil bad_archive" "v2.3.0-broken validation_failed"; do
    set -- $tcase; rel="$1"; want="$2"
    reset_world; latest "$rel"; upd
    check "$rel: refused with $want" '[ "$RC" = 1 ] && [ "$(st .status)" = error ] && [ "$(st .code)" = "$want" ]'
    check "$rel: install untouched" untouched
done
reset_world; latest v2.3.0-evil; upd
check "path traversal: nothing written outside" '[ ! -e "$T/escape" ] && [ ! -e "$T/state/escape" ] && [ ! -e "$FI/escape" ]'

reset_world; latest v2.3.0-broken; echo '{oops' > "$FI/src/data.json"; upd
check "a file broken in the release AND in the install does not block the update" '[ "$RC" = 0 ] && [ "$(st .status)" = ok ]'

echo "== not newer"
reset_world 2.2.5-s2; latest v2.2.5-s1; upd
check "older than installed: refused (not_newer)" '[ "$RC" = 1 ] && [ "$(st .code)" = not_newer ]'
check "older than installed: install untouched" untouched
reset_world 2.2.9; latest v2.2.5-s1; upd
check "installed 2.2.9 vs release 2.2.5-s1: refused" '[ "$RC" = 1 ] && [ "$(st .code)" = not_newer ]'

echo "== unreachable / transport"
reset_world; latest v2.2.5-s1
upd SERPANTINUM_UPDATE_BASE_URL=http://127.0.0.1:1
check "unreachable: error release_unreachable, install untouched" '[ "$RC" = 1 ] && [ "$(st .code)" = release_unreachable ]' ; check "unreachable: untouched" untouched
CK="$(SERPANTINUM_UPDATE_BASE_URL=http://127.0.0.1:1 bash "$SCRIPT" check)"
check "unreachable: check reports the error, no update" '[ "$(jq -r .status <<< "$CK")" = error ] && [ "$(jq -r .error <<< "$CK")" = release_unreachable ] && [ "$(jq -r .hasUpdate <<< "$CK")" = false ]'
upd SERPANTINUM_UPDATE_BASE_URL=http://example.com/serp
check "plain http to a non-local host is refused" '[ "$RC" = 1 ] && [ "$(st .code)" = release_unreachable ]'
rm -f "$W/latest.txt"; upd
check "no latest.txt (404): release_unreachable" '[ "$RC" = 1 ] && [ "$(st .code)" = release_unreachable ]'
latest 'v1;rm -rf /'; upd
check "malicious tag in latest.txt: rejected" '[ "$RC" = 1 ] && [ "$(st .code)" = bad_release_meta ]'
reset_world; latest v2.2.5-s1
upd SERPANTINUM_UPDATE_PUBKEY_FPR=bogus
check "invalid pubkey_fpr: not-configured, refuses" '[ "$RC" = 1 ] && [ "$(st .status)" = not-configured ]'

echo "== health failure -> automatic rollback"
reset_world; latest v2.2.5-s1
upd X_UPDATE_FAKE_HEALTH=fail
check "unhealthy new shell: error health_failed" '[ "$RC" = 1 ] && [ "$(st .code)" = health_failed ]'
check "rolled back: install and state restored" 'untouched && grep -q "SERPANTINUM_VERSION=\"2.2.4\"" "$T/state/version" && ! grep -q SERPANTINUM_RELEASE "$T/state/version"'

echo "== GitHub-style metadata (API json + releases/download/TAG)"
reset_world
upd SERPANTINUM_UPDATE_BASE_URL="$BASE/o/r/releases" X_UPDATE_API_URL="$BASE/api/latest"
check "github layout: installs the release from the API tag" '[ "$RC" = 0 ] && [ "$(cat "$FI/src/marker")" = brand-new ] && grep -q "SERPANTINUM_RELEASE=\"2.2.5-s1\"" "$T/state/version"'
echo '{"tag_name":"v9.9.9","draft":true,"prerelease":false}' > "$W/api/latest"
CK="$(SERPANTINUM_UPDATE_BASE_URL="$BASE/o/r/releases" X_UPDATE_API_URL="$BASE/api/latest" bash "$SCRIPT" check)"
check "github layout: draft releases are ignored" '[ "$(jq -r .hasUpdate <<< "$CK")" = false ] && [ "$(jq -r .error <<< "$CK")" = bad_release_meta ]'

echo "== defaults"
check "default base_url is the GitHub releases of this repo" 'grep -q "^RELEASE_DEFAULT_BASE=\"https://github.com/paperangel1/Serp-x/releases\"" "$SCRIPT"'
fp="$(gpg --batch --show-keys --with-colons "$R/installer/release-key.asc" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
check "default pubkey_fpr equals installer/release-key.asc" '[ -n "$fp" ] && grep -q "^RELEASE_KEY_FPR_DEFAULT=\"$fp\"" "$SCRIPT"'

echo; echo "passed: $pass  failed: $fail"
[ "$fail" = 0 ]
