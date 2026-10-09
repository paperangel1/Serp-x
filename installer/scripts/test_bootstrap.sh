#!/usr/bin/env bash
# Tests for bootstrap.sh and build.sh. Offline: local HTTP server on 127.0.0.1,
# throwaway GNUPGHOME, temp HOME/XDG. Touches nothing outside a temp dir.
#   installer/scripts/test_bootstrap.sh            all tests (incl. real build, ~2 min)
#   SERP_TEST_FAST=1 installer/scripts/test_bootstrap.sh   skip the real-build tests
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOOT=$here/bootstrap.sh
BUILD=$here/build.sh
T=$(mktemp -d)
srv_pid=""
cleanup() {
	[ -n "$srv_pid" ] && kill "$srv_pid" 2>/dev/null
	GNUPGHOME=$T/gnupg gpgconf --kill all >/dev/null 2>&1
	GNUPGHOME=$T/gnupg2 gpgconf --kill all >/dev/null 2>&1
	rm -rf "$T"
}
trap cleanup EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
check() { # check <name> <cond-exit-code>
	if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

export HOME=$T/home XDG_CACHE_HOME=$T/home/.cache XDG_CONFIG_HOME=$T/home/.config
export XDG_STATE_HOME=$T/home/.state XDG_DATA_HOME=$T/home/.data
export SERP_SKIP_ENV_CHECK=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
mkdir -p "$HOME"
unset SERP_RELEASE_BASE_URL SERP_SOURCE_URL SERP_GPG_FINGERPRINT
echo "stdin-from-tty" >"$T/tty"
export SERP_TTY=$T/tty

# ---- throwaway keys ---------------------------------------------------------
mkkey() { # mkkey <homedir> <name> -> prints fingerprint
	mkdir -m 700 "$1"
	GNUPGHOME=$1 gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
		--quick-generate-key "$2 <$2@test.invalid>" ed25519 sign never >/dev/null 2>&1
	GNUPGHOME=$1 gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'
}
FPR=$(mkkey "$T/gnupg" release)
FPR2=$(mkkey "$T/gnupg2" attacker)
[ ${#FPR} = 40 ] && [ ${#FPR2} = 40 ] || { echo "cannot create test gpg keys"; exit 1; }
GNUPGHOME=$T/gnupg gpg --batch --armor --export "$FPR" >"$T/release.asc"
GNUPGHOME=$T/gnupg2 gpg --batch --armor --export "$FPR2" >"$T/attacker.asc"

# ---- fake release -----------------------------------------------------------
W=$T/www
mk_release() { # mk_release <dir> <ver> [signing-gnupghome] [keyfile]
	local d=$1 v=$2 gh=${3:-$T/gnupg} kf=${4:-$T/release.asc} s=$T/stage-$2
	rm -rf "$s"; mkdir -p "$d" "$s/bin" "$s/src" "$s/installer/manifests"
	echo "x" >"$s/bin/serpantinum-x"; echo "y" >"$s/src/file"; echo "m" >"$s/installer/manifests/a.toml"
	cat >"$d/serp-installer-$v-linux-amd64" <<'STUB'
#!/bin/sh
echo "STUB-RAN args: $*"
printf 'STUB-STDIN: '; cat
echo "STUB-PAYLOAD-OK: $(ls "$2" | tr '\n' ' ')"
STUB
	chmod +x "$d/serp-installer-$v-linux-amd64"
	tar -C "$s" --create bin src installer | zstd -q -o "$d/serp-x-$v.tar.zst"
	(cd "$d" && sha256sum "serp-installer-$v-linux-amd64" "serp-x-$v.tar.zst" >SHA256SUMS)
	rm -f "$d/SHA256SUMS.sig"
	GNUPGHOME=$gh gpg --batch --yes --detach-sign -o "$d/SHA256SUMS.sig" "$d/SHA256SUMS" 2>/dev/null
	cp "$kf" "$d/serp-x-release.asc"
}
mk_release "$W/v1" v1
mk_release "$W/latest" v1

PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$W" >"$T/http.log" 2>&1 &
srv_pid=$!
for _ in $(seq 50); do curl -fsS "http://127.0.0.1:$PORT/v1/SHA256SUMS" >/dev/null 2>&1 && break; sleep 0.1; done
export SERP_RELEASE_BASE_URL=http://127.0.0.1:$PORT
export SERP_GPG_FINGERPRINT=$FPR

run() { # run <args...>; sets OUT, RC
	OUT=$("$BOOT" "$@" 2>&1); RC=$?
}

# ---- syntax -----------------------------------------------------------------
for f in bootstrap.sh build.sh test_bootstrap.sh; do
	bash -n "$here/$f"; check "bash -n $f" $?
done
if command -v shellcheck >/dev/null; then
	shellcheck -x "$here"/*.sh; check "shellcheck" $?
else
	echo "skip - shellcheck not installed"
fi

# ---- good signature -----------------------------------------------------------
run --version v1 --plain --yes
[ $RC = 0 ]; check "good signature: exit 0" $? "rc=$RC $OUT"
case $OUT in *"STUB-RAN args: --payload "*" --plain --yes"*) r=0 ;; *) r=1 ;; esac
check "good signature: exec with --payload and passthrough args" $r "$OUT"
case $OUT in *"STUB-STDIN: stdin-from-tty"*) r=0 ;; *) r=1 ;; esac
check "stdin is the tty, not the pipe" $r "$OUT"
case $OUT in *"STUB-PAYLOAD-OK: bin installer src"*) r=0 ;; *) r=1 ;; esac
check "payload extracted" $r "$OUT"
case $OUT in *"Signature OK"*"Checksums OK"*) r=0 ;; *) r=1 ;; esac
check "reports signature and checksums" $r "$OUT"

run --plain # latest
[ $RC = 0 ]; check "version defaults to latest" $? "$OUT"

# curl | bash style: script on stdin
OUT=$(SERP_TTY=$T/tty bash -s -- --version v1 --plain <"$BOOT" 2>&1); RC=$?
[ $RC = 0 ] && case $OUT in *"STUB-STDIN: stdin-from-tty"*) true ;; *) false ;; esac
check "works when the script itself comes from stdin" $? "rc=$RC $OUT"

# ---- tampering ----------------------------------------------------------------
mk_release "$W/bad-sha" v1
echo tampered >>"$W/bad-sha/serp-installer-v1-linux-amd64"
run --version bad-sha
[ $RC -ne 0 ]; check "tampered binary: stops" $? "$OUT"
case $OUT in *"SHA256 MISMATCH"*) r=0 ;; *) r=1 ;; esac
check "tampered binary: clear message" $r "$OUT"
case $OUT in *STUB-RAN*) r=1 ;; *) r=0 ;; esac
check "tampered binary: nothing executed" $r "$OUT"

mk_release "$W/bad-sig" v1
echo "deadbeef  serp-installer-v1-linux-amd64" >>"$W/bad-sig/SHA256SUMS"
run --version bad-sig
[ $RC -ne 0 ]; check "modified SHA256SUMS (bad signature): stops" $? "$OUT"
case $OUT in *"BAD SIGNATURE"*) r=0 ;; *) r=1 ;; esac
check "bad signature: clear message" $r "$OUT"
case $OUT in *STUB-RAN*) r=1 ;; *) r=0 ;; esac
check "bad signature: nothing executed" $r "$OUT"

mk_release "$W/no-sig" v1
rm "$W/no-sig/SHA256SUMS.sig"
run --version no-sig
[ $RC -ne 0 ]; check "missing signature file: stops" $? "$OUT"

mk_release "$W/attacker" v1 "$T/gnupg2" "$T/attacker.asc"
run --version attacker
[ $RC -ne 0 ]; check "release re-signed by another key: stops" $? "$OUT"
case $OUT in *"FINGERPRINT MISMATCH"*) r=0 ;; *) r=1 ;; esac
check "other key: fingerprint mismatch message" $r "$OUT"

mk_release "$W/attacker2" v1 "$T/gnupg2" "$T/release.asc" # real key file, attacker signature
run --version attacker2
[ $RC -ne 0 ]; check "attacker signature with genuine key file: stops" $? "$OUT"
case $OUT in *"BAD SIGNATURE"*) r=0 ;; *) r=1 ;; esac
check "attacker signature: bad-signature message" $r "$OUT"

run --version nonexistent
[ $RC -ne 0 ]; check "unknown version: stops" $? "$OUT"

# placeholder fingerprint is refused
OUT=$(env -u SERP_GPG_FINGERPRINT "$BOOT" --version v1 2>&1); RC=$?
[ $RC -ne 0 ]; check "placeholder fingerprint: refuses to run" $? "$OUT"
case $OUT in *"not configured"*) r=0 ;; *) r=1 ;; esac
check "placeholder fingerprint: clear message" $r "$OUT"

# plain http to a non-local host is refused
OUT=$(SERP_RELEASE_BASE_URL=http://example.invalid "$BOOT" --version v1 2>&1); RC=$?
[ $RC -ne 0 ]; check "http to non-local host: refused" $? "$OUT"

# ---- dry-run / from-source ------------------------------------------------------
rm -rf "$HOME/.cache/serp-x-bootstrap"
run --bootstrap-dry-run --version v1 --yes
[ $RC = 0 ] && case $OUT in *"[dry-run]"*) true ;; *) false ;; esac
check "dry-run (normal path)" $? "$OUT"
[ ! -e "$HOME/.cache/serp-x-bootstrap" ]; check "dry-run changes nothing" $?

run --from-source --bootstrap-dry-run --version v2.2.4-s3 --plain
[ $RC = 0 ] && case $OUT in *"pacman -S --needed go git"*"git clone --depth 1 --branch v2.2.4-s3"*"build.sh"*"--plain"*) true ;; *) false ;; esac
check "--from-source dry-run shows pacman/clone/build/exec" $? "$OUT"
[ ! -e "$HOME/.cache/serp-x-bootstrap" ]; check "--from-source dry-run changes nothing" $?

run --from-source --bootstrap-dry-run
[ $RC -ne 0 ]; check "--from-source without a tag: stops" $? "$OUT"

# real --from-source against a local git repo (no pacman: go/git already present)
if command -v go >/dev/null && command -v git >/dev/null && [ -z "${SERP_TEST_FAST:-}" ]; then
	R=$T/srcrepo
	mkdir -p "$R"
	git -C "$T" init -q srcrepo 2>/dev/null
	(cd "$R" && mkdir -p installer/scripts && cp -r "$here/../go.mod" "$here/../go.sum" "$here/../cmd" "$here/../internal" \
		"$here/../manifests" "$here/../i18n" "$here/../vendor" "$here/../embed.go" installer/ &&
		cp "$BUILD" installer/scripts/ &&
		git add -A >/dev/null &&
		git -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false commit -qm init &&
		git -c user.name=t -c user.email=t@t.invalid tag -m t v9.9.9-test >/dev/null 2>&1 || git tag v9.9.9-test)
	OUT=$(SERP_SOURCE_URL=file://$R GOCACHE=${GOCACHE:-$T/gocache} "$BOOT" --from-source --version v9.9.9-test -- --version 2>&1); RC=$?
	[ $RC = 0 ] && case $OUT in *"serp-installer v9.9.9-test"*) true ;; *) false ;; esac
	check "--from-source: clone, build, exec" $? "rc=$RC $OUT"
fi

# ---- build.sh -----------------------------------------------------------------------
if command -v go >/dev/null && [ -z "${SERP_TEST_FAST:-}" ]; then
	export GOCACHE=${GOCACHE:-$T/gocache}
	B1=$T/build1 B2=$T/build2
	SERP_SIGN_KEY=$FPR GNUPGHOME=$T/gnupg "$BUILD" --version vtest --out "$B1" >"$T/b1.log" 2>&1; RC=$?
	check "build.sh: exit 0" $RC "$(cat "$T/b1.log")"
	f=$B1/serp-installer-vtest-linux-amd64
	file "$f" 2>/dev/null | grep -q 'statically linked'; check "build.sh: static binary" $?
	"$f" --version | grep -q "serp-installer vtest"; check "build.sh: version injected" $?
	(cd "$B1" && sha256sum -c --quiet SHA256SUMS); check "build.sh: SHA256SUMS valid" $?
	GNUPGHOME=$T/gnupg gpg --batch --verify "$B1/SHA256SUMS.sig" "$B1/SHA256SUMS" 2>/dev/null
	check "build.sh: SHA256SUMS.sig verifies" $?
	"$BUILD" --version vtest --out "$B2" >/dev/null 2>&1
	cmp -s "$B1/SHA256SUMS" "$B2/SHA256SUMS"; check "build.sh: two builds, same output dir layout -> identical sums (binary + payload)" $?

	# the engine reads config/ (kitty, settings.json, sddm), compositors/ and version.txt from the payload
	zstd -dc "$B1/serp-x-vtest.tar.zst" | tar -t >"$T/payload.lst" 2>/dev/null
	for want in bin/serpantinum-x src/version.txt version.txt config/kitty config/serpantinum/settings.json compositors/hyprland/ installer/manifests/core.toml; do
		grep -q "^$want" "$T/payload.lst"; check "payload contains $want" $?
	done

	# end to end: bootstrap against the real build output
	mkdir -p "$W/real"
	cp "$B1"/* "$W/real/" && cp "$T/release.asc" "$W/real/serp-x-release.asc"
	run --version real -- --version
	[ $RC = 0 ] && case $OUT in *"serp-installer vtest"*) true ;; *) false ;; esac
	check "end to end: bootstrap verifies and runs the real build" $? "rc=$RC $OUT"

	if git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
		"$BUILD" --verify-repro --version vtest >"$T/repro.log" 2>&1
		check "build.sh --verify-repro (different paths, same sha256)" $? "$(cat "$T/repro.log")"
	fi
fi

echo
echo "passed: $pass  failed: $fail"
[ $fail = 0 ]
