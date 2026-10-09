#!/usr/bin/env bash
# Manual try-out of the installer: boots a FRESH Arch VM (overlay of images/base.qcow2),
# pushes the current build into it and prints what to type. The host network is not touched.
#   tests/vm/try.sh          start (opens a VM window; VM_DISPLAY=none for no window)
#   tests/vm/try.sh stop     power the VM off
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
cd "$here"
for d in images state out; do [ -e "$d" ] || ln -s "$HOME/vmstand/$d" "$d"; done
export VM_NAME=try
if [ "${1:-}" = stop ]; then ./vm.sh down; exit 0; fi
[ -f images/base.qcow2 ] || { echo "no base image: run tests/vm/vm.sh fetch && tests/vm/vm.sh base first"; exit 1; }
dist=$(readlink -f out)/try-dist; rm -rf "$dist"; mkdir -p "$dist"
t=$(mktemp -d)
(cd "$repo/installer" && HOME=$t GOCACHE=${GOCACHE:-$HOME/.cache/go-build-vmstand} scripts/build.sh --version vmtest --out "$dist") >/dev/null
rm -rf "$t"
VM_BACKING=base VM_DISPLAY=${VM_DISPLAY:-gtk} ./vm.sh up try
./vm.sh scp "$dist/serp-installer-vmtest-linux-amd64" /home/tester/serp-installer >/dev/null
./vm.sh scp "$dist/serp-x-vmtest.tar.zst" /home/tester/ >/dev/null
./vm.sh ssh 'chmod +x serp-installer'
cat <<'M'

VM is ready. Log in (in the VM window or via ssh):  login: tester   password: tester
Start the installer INSIDE the VM:
    ./serp-installer install --payload serp-x-vmtest.tar.zst
Shell in a host terminal instead of the VM window:   tests/vm/vm.sh ssh     (run with VM_NAME=try)
Power off and throw the VM away:                      tests/vm/try.sh stop
M
