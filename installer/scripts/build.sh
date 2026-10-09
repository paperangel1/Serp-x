#!/usr/bin/env bash
# Reproducible build of serp-installer (static, CGO off, vendored deps).
#   installer/scripts/build.sh [--version V] [--out DIR] [--no-payload] [--verify-repro]
# Output (default installer/dist/):
#   serp-installer-<ver>-linux-amd64
#   serp-x-<ver>.tar.zst        payload: bin/ src/ config/ compositors/ version.txt installer/manifests
#   SHA256SUMS                  (+ SHA256SUMS.sig if SERP_SIGN_KEY is set)
# Env: SERP_SIGN_KEY (gpg key id to sign SHA256SUMS), SOURCE_DATE_EPOCH.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
inst=$(cd "$here/.." && pwd)
repo=$(cd "$inst/.." && pwd)

ver="" out="" payload=1 verify=0 internal_root=""
die() { echo "build.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
	--version) ver=${2:?--version needs a value}; shift 2 ;;
	--out) out=${2:?--out needs a value}; shift 2 ;;
	--no-payload) payload=0; shift ;;
	--verify-repro) verify=1; shift ;;
	--commit) commit=${2:?}; shift 2 ;;
	-h | --help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

command -v go >/dev/null || die "go not found (pacman -S go)"

have_git=0
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && have_git=1
: "${commit:=}"
if [ -z "$commit" ]; then
	[ $have_git = 1 ] && commit=$(git -C "$repo" rev-parse --short=12 HEAD) || commit=unknown
fi
if [ -z "$ver" ]; then
	[ $have_git = 1 ] && ver=$(git -C "$repo" describe --tags --always 2>/dev/null) || ver=dev
fi
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	[ $have_git = 1 ] && SOURCE_DATE_EPOCH=$(git -C "$repo" log -1 --format=%ct) || SOURCE_DATE_EPOCH=0
fi
export SOURCE_DATE_EPOCH
case $ver in *[!A-Za-z0-9._+-]* | "") die "bad version string: $ver" ;; esac

# build_one <module-dir> <output-file>
build_one() {
	local src=$1 dst=$2
	(
		cd "$src"
		env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 \
			GOFLAGS=-mod=vendor GOTOOLCHAIN=local GOPROXY=off GOWORK=off GOTELEMETRY=off \
			go build -trimpath -buildvcs=false \
			-ldflags "-s -w -buildid= -X main.version=$ver -X main.commit=$commit" \
			-o "$dst" ./cmd/serp-installer
	)
	touch -d "@$SOURCE_DATE_EPOCH" "$dst"
}

if [ $verify = 1 ]; then
	command -v git >/dev/null && [ $have_git = 1 ] || die "--verify-repro needs a git checkout"
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	mkdir "$tmp/a-one" "$tmp/b-different-path"
	for d in a-one b-different-path; do
		git -C "$repo" archive HEAD installer | tar -x -C "$tmp/$d"
		build_one "$tmp/$d/installer" "$tmp/$d/bin"
	done
	sa=$(sha256sum <"$tmp/a-one/bin" | cut -d' ' -f1)
	sb=$(sha256sum <"$tmp/b-different-path/bin" | cut -d' ' -f1)
	if [ "$sa" = "$sb" ]; then
		echo "reproducible: $sa (committed HEAD, version $ver)"
		exit 0
	fi
	echo "NOT reproducible: $sa != $sb" >&2
	exit 1
fi

out=${out:-$inst/dist}
mkdir -p "$out"
out=$(cd "$out" && pwd)
bin="serp-installer-$ver-linux-amd64"
build_one "$inst" "$out/$bin"
sums=("$bin")

if [ $payload = 1 ]; then
	command -v zstd >/dev/null || die "zstd not found"
	tarball="serp-x-$ver.tar.zst"
	list=$(mktemp)
	trap 'rm -f "$list"' EXIT
	if [ $have_git = 1 ]; then
		(cd "$repo" && git ls-files -- bin src config compositors version.txt installer/manifests) >"$list"
	else
		(cd "$repo" && find bin src config compositors version.txt installer/manifests -type f) >"$list"
	fi
	LC_ALL=C sort -o "$list" "$list"
	(cd "$repo" && tar --create --no-recursion --files-from="$list" --owner=0 --group=0 --numeric-owner \
		--mtime="@$SOURCE_DATE_EPOCH" --format=posix \
		--pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime') |
		zstd -q -19 --no-check -T1 -f -o "$out/$tarball"
	sums+=("$tarball")
fi

(cd "$out" && sha256sum "${sums[@]}" >SHA256SUMS)
if [ -n "${SERP_SIGN_KEY:-}" ]; then
	rm -f "$out/SHA256SUMS.sig"
	gpg --batch --yes --local-user "$SERP_SIGN_KEY" --detach-sign -o "$out/SHA256SUMS.sig" "$out/SHA256SUMS"
else
	echo "build.sh: SERP_SIGN_KEY not set, SHA256SUMS is not signed" >&2
fi
echo "built: $out/$bin"
cat "$out/SHA256SUMS"
