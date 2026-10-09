#!/usr/bin/env bash
# Prepare a signed release. Builds, signs SHA256SUMS and PRINTS the `gh release create`
# command; it never publishes anything and never pushes.
#   installer/scripts/release.sh TAG [--out DIR]       TAG like v2.2.5-s1
# Env: SERP_RELEASE_GNUPGHOME (default ~/.local/share/serpantinum-x/release-gnupg, holds the
#      private release key; keep it out of the repo and out of backups you share),
#      SERP_RELEASE_OUT (default ~/.cache/serp-x-release), SERP_RELEASE_REPO (default paperangel1/Serp-x)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
die() { echo "release.sh: $*" >&2; exit 1; }

tag="" out=""
while [ $# -gt 0 ]; do
	case $1 in
	--out) out=${2:?--out needs a value}; shift 2 ;;
	-h | --help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "unknown option: $1" ;;
	*) [ -z "$tag" ] || die "one TAG only"; tag=$1; shift ;;
	esac
done
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+-s[0-9]+$ ]] || die "TAG must look like v2.2.5-s1 (upstream version + -s<our build number>)"

gh_home=${SERP_RELEASE_GNUPGHOME:-$HOME/.local/share/serpantinum-x/release-gnupg}
slug=${SERP_RELEASE_REPO:-paperangel1/Serp-x}
out=${out:-${SERP_RELEASE_OUT:-$HOME/.cache/serp-x-release}/$tag}
[ -d "$gh_home" ] || die "release key home not found: $gh_home"

# the key must be the one pinned in bootstrap.sh and in x_update.sh
pinned=$(sed -n 's/^SERP_KEY_FPR_DEFAULT="\([0-9A-F]\{40\}\)"$/\1/p' "$here/bootstrap.sh")
pinned_upd=$(sed -n 's/^RELEASE_KEY_FPR_DEFAULT="\([0-9A-F]\{40\}\)".*/\1/p' "$repo/src/scripts/custom/x_update.sh")
[ -n "$pinned" ] && [ "$pinned" = "$pinned_upd" ] || die "pinned fingerprints in bootstrap.sh and x_update.sh differ or are missing"
have=$(GNUPGHOME=$gh_home gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
[ "$have" = "$pinned" ] || die "secret key in $gh_home ($have) is not the pinned release key ($pinned)"

# only committed, clean state is released (build.sh packs `git ls-files`)
[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes"
commit=$(git -C "$repo" rev-parse HEAD)
[ ! -e "$out" ] || [ -z "$(ls -A "$out" 2>/dev/null)" ] || die "output dir is not empty: $out"
grep -q "^### ${tag#v}\$" "$repo/CHANGELOG-serp-x.md" || die "CHANGELOG-serp-x.md has no '### ${tag#v}' section (write the release notes first)"
[ "$(tr -d '[:space:]' <"$repo/version.txt")" = "$(echo "${tag#v}" | sed 's/-s[0-9]*$//')" ] ||
	echo "release.sh: WARNING: version.txt ($(tr -d '[:space:]' <"$repo/version.txt")) differs from the upstream part of $tag" >&2

mkdir -p "$out"
SERP_SIGN_KEY=$pinned GNUPGHOME=$gh_home "$here/build.sh" --version "$tag" --out "$out"
cp "$repo/installer/release-key.asc" "$out/serp-x-release.asc"
cp "$here/bootstrap.sh" "$out/install.sh"

# notes = the changelog section of this tag
awk -v h="### ${tag#v}" '$0==h{p=1;next} /^### /{p=0} p' "$repo/CHANGELOG-serp-x.md" | sed '1{/^$/d}' >"$out/notes.md"

# self-check exactly as a client does: fresh GNUPGHOME, pinned fingerprint only
chk=$(mktemp -d); trap 'GNUPGHOME=$chk gpgconf --kill all >/dev/null 2>&1; rm -rf "$chk"' EXIT
chmod 700 "$chk"
GNUPGHOME=$chk gpg --batch --quiet --import "$out/serp-x-release.asc" 2>/dev/null
GNUPGHOME=$chk gpg --batch --status-fd 1 --verify "$out/SHA256SUMS.sig" "$out/SHA256SUMS" 2>/dev/null |
	awk -v f="$pinned" '$2=="VALIDSIG" && toupper($12)==f {ok=1} END{exit !ok}' || die "self-check: signature does not verify against the pinned key"
(cd "$out" && sha256sum -c --quiet SHA256SUMS) || die "self-check: sha256 mismatch"
echo "self-check OK (signature by $pinned, sha256 valid)"

cat <<MSG

Built: $out   (from commit $commit)

Next, by hand:
  1. push the commit that is being released (the release is created from it):
       git -C $repo push publish HEAD:main
  2. publish:
       gh release create $tag --repo $slug --target $commit --title "serp-x ${tag#v}" --notes-file $out/notes.md \\
         $out/serp-installer-$tag-linux-amd64 $out/serp-x-$tag.tar.zst $out/SHA256SUMS $out/SHA256SUMS.sig \\
         $out/serp-x-release.asc $out/install.sh
MSG
