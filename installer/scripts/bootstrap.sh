#!/usr/bin/env bash
# serp-x bootstrap (published as install.sh):
#   curl -fsSL https://raw.githubusercontent.com/paperangel1/Serp-x/main/installer/scripts/bootstrap.sh | bash
#   ... | bash -s -- --version v2.2.5-s1 [installer args...]
# Downloads the static serp-installer + payload, verifies the gpg signature of
# SHA256SUMS against the fingerprint embedded below, checks sha256, then runs it.
# Any mismatch stops the run (no fallback). Emergency path: --from-source.
#
# Bootstrap options (everything else goes to serp-installer):
#   --version TAG         release tag (default: latest)
#   --from-source         build from a git clone (needs a tag via --version)
#   --bootstrap-dry-run   print what would be done, change nothing
#   --                    pass everything after it to serp-installer verbatim
#   -h, --help
# Env: SERP_RELEASE_BASE_URL, SERP_SOURCE_URL, SERP_GPG_FINGERPRINT
set -euo pipefail

# Release signing key (primary key fingerprint; public key: installer/release-key.asc in the repo).
SERP_KEY_FPR_DEFAULT="8F84E4915C98F28DFA1E7F484E2045971CEF3BD0"
# Default: GitHub releases of this repo (layout: releases/latest/download/F, releases/download/TAG/F).
# SERP_RELEASE_BASE_URL (tests, mirrors) uses the layout <base>/<version>/F instead.
GH_RELEASES=https://github.com/paperangel1/Serp-x/releases
BASE_URL=${SERP_RELEASE_BASE_URL:-}
SOURCE_URL=${SERP_SOURCE_URL:-https://github.com/paperangel1/Serp-x.git}
KEY_FILE=serp-x-release.asc

case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in ru*) L=ru ;; *) L=en ;; esac
say() { if [ "$L" = ru ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
die() { { printf 'serp-x bootstrap: '; say "$1" "$2"; } >&2; exit 1; }

version=latest from_source=0 dry=0
args=()
while [ $# -gt 0 ]; do
	case $1 in
	--version) [ $# -ge 2 ] || die "--version требует значение" "--version needs a value"; version=$2; shift 2 ;;
	--version=*) version=${1#*=}; shift ;;
	--from-source) from_source=1; shift ;;
	--bootstrap-dry-run) dry=1; shift ;;
	--) shift; args+=("$@"); break ;;
	-h | --help) sed -n '2,14p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; exit 0 ;;
	*) args+=("$1"); shift ;;
	esac
done
case $version in *[!A-Za-z0-9._+-]* | "") die "недопустимая версия" "invalid version" ;; esac

fpr=${SERP_GPG_FINGERPRINT:-$SERP_KEY_FPR_DEFAULT}
fpr=${fpr//[[:space:]]/}; fpr=${fpr^^}
if [ -n "${SERP_GPG_FINGERPRINT:-}" ]; then
	say "ВНИМАНИЕ: отпечаток ключа переопределён через SERP_GPG_FINGERPRINT" \
		"WARNING: key fingerprint overridden via SERP_GPG_FINGERPRINT" >&2
fi

# ---- environment checks ---------------------------------------------------
if [ -z "${SERP_SKIP_ENV_CHECK:-}" ]; then
	[ "$(uname -m)" = x86_64 ] || die "поддерживается только x86_64" "only x86_64 is supported"
	[ "$(id -u)" -ne 0 ] || die "запусти от обычного пользователя, не от root" "run as a normal user, not root"
	osr=${SERP_OS_RELEASE:-/etc/os-release}
	if ! grep -Eqi '^(ID|ID_LIKE)=.*arch' "$osr" 2>/dev/null || ! command -v pacman >/dev/null; then
		die "нужна Arch-подобная система с pacman" "an Arch-based system with pacman is required"
	fi
fi

# stdin for the installer: the terminal (curl | bash consumed our stdin)
TTY=${SERP_TTY:-/dev/tty}
tty_ok=0
if { : <"$TTY"; } 2>/dev/null; then tty_ok=1; fi

# no command given (the usual `curl | bash`): start the installer's default, `install`
has_cmd=0
for a in ${args[@]+"${args[@]}"}; do
	case $a in install|repair|modules|uninstall|backup|reconcile|export-config) has_cmd=1 ;; esac
done
[ $has_cmd = 1 ] || args+=(install)

run_installer() { # run_installer <bin> <payload-dir>
	if [ $tty_ok = 1 ]; then
		exec "$1" --payload "$2" ${args[@]+"${args[@]}"} <"$TTY"
	else
		exec "$1" --payload "$2" ${args[@]+"${args[@]}"}
	fi
}

work_root=${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/serp-x-bootstrap

# ---- emergency path: build from source -------------------------------------
if [ $from_source = 1 ]; then
	[ "$version" != latest ] || die "для --from-source укажи тег: --version TAG" "--from-source needs a tag: --version TAG"
	if [ $dry = 1 ]; then
		echo "[dry-run] sudo pacman -S --needed go git"
		echo "[dry-run] git clone --depth 1 --branch $version $SOURCE_URL $work_root/src-$version"
		echo "[dry-run] $work_root/src-$version/installer/scripts/build.sh --version $version"
		echo "[dry-run] exec serp-installer --payload $work_root/src-$version ${args[*]:-}"
		exit 0
	fi
	command -v go >/dev/null && command -v git >/dev/null || sudo pacman -S --needed go git
	mkdir -p "$work_root"
	dir=$work_root/src-$version
	rm -rf "$dir"
	git clone --depth 1 --branch "$version" "$SOURCE_URL" "$dir"
	"$dir/installer/scripts/build.sh" --version "$version" --no-payload --out "$dir/installer/dist"
	run_installer "$dir/installer/dist/serp-installer-$version-linux-amd64" "$dir"
fi

# ---- normal path: download + verify ----------------------------------------
for t in curl gpg sha256sum tar zstd; do
	command -v "$t" >/dev/null || die "не найдено: $t" "missing tool: $t"
done
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || die "некорректный отпечаток ключа" "malformed key fingerprint"

if [ -n "$BASE_URL" ]; then
	url="${BASE_URL%/}/$version"
elif [ "$version" = latest ]; then
	url="$GH_RELEASES/latest/download"
else
	url="$GH_RELEASES/download/$version"
fi
if [ $dry = 1 ]; then
	echo "[dry-run] download $url/{SHA256SUMS,SHA256SUMS.sig,$KEY_FILE}"
	echo "[dry-run] gpg --verify (fingerprint $fpr), sha256sum -c, extract payload"
	echo "[dry-run] exec serp-installer --payload <dir> ${args[*]:-}"
	exit 0
fi

mkdir -p "$work_root"
work=$(mktemp -d "$work_root/run.XXXXXX")
ok=0
stop_gpg() { gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$work/gnupg"; }
cleanup() { stop_gpg; [ $ok = 1 ] || rm -rf "$work"; }
trap cleanup EXIT
chmod 700 "$work"

fetch() { curl -fsSL --proto '=https,http' --retry 2 -o "$work/$1" "$url/$1" ||
	die "не удалось скачать $url/$1" "download failed: $url/$1"; }
case $url in https://*) ;; http://127.0.0.1* | http://localhost*) ;; *) die "только https" "https only" ;; esac

say "Скачиваю контрольные суммы и подпись…" "Fetching checksums and signature…"
fetch SHA256SUMS; fetch SHA256SUMS.sig; fetch "$KEY_FILE"

export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$work/$KEY_FILE" 2>/dev/null || die "не удалось импортировать ключ релизов" "cannot import release key"
have=$(gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10; p=0}')
printf '%s\n' "$have" | grep -qx "$fpr" ||
	die "ОТПЕЧАТОК КЛЮЧА НЕ СОВПАДАЕТ - остановка" "KEY FINGERPRINT MISMATCH - aborting"
status=$(gpg --batch --status-fd 1 --verify "$work/SHA256SUMS.sig" "$work/SHA256SUMS" 2>/dev/null || true)
printf '%s\n' "$status" | awk -v f="$fpr" '$2=="VALIDSIG" && toupper($12)==f {ok=1} END{exit !ok}' ||
	die "ПОДПИСЬ SHA256SUMS НЕВЕРНА - остановка (ничего не запущено)" "BAD SIGNATURE on SHA256SUMS - aborting (nothing was run)"
say "Подпись верна." "Signature OK."

bin=$(awk '$2 ~ /^serp-installer-[A-Za-z0-9._+-]+-linux-amd64$/ {print $2; exit}' "$work/SHA256SUMS")
tarball=$(awk '$2 ~ /^serp-x-[A-Za-z0-9._+-]+\.tar\.zst$/ {print $2; exit}' "$work/SHA256SUMS")
[ -n "$bin" ] && [ -n "$tarball" ] || die "в SHA256SUMS нет нужных файлов" "SHA256SUMS lacks the expected files"

say "Скачиваю $bin и $tarball…" "Downloading $bin and $tarball…"
fetch "$bin"; fetch "$tarball"
(cd "$work" && grep -E "  ($bin|$tarball)\$" SHA256SUMS | sha256sum -c --quiet -) ||
	die "СУММА SHA256 НЕ СОВПАДАЕТ - остановка" "SHA256 MISMATCH - aborting"
say "Суммы совпали." "Checksums OK."

mkdir "$work/payload"
tar --zstd -xf "$work/$tarball" -C "$work/payload" --no-same-owner
chmod 755 "$work/$bin"
stop_gpg
ok=1
run_installer "$work/$bin" "$work/payload"
