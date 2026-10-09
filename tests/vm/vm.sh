#!/usr/bin/env bash
# QEMU test stand for serp-installer (plan section 7). Everything stays under
# tests/vm/{images,state,out}; the host network is never touched (QEMU slirp
# user-net only, ssh reachable on 127.0.0.1:$VM_SSH_PORT).
#
#   vm.sh fetch            download + sha256-verify the Arch cloud image
#   vm.sh base             build images/base.qcow2 (updated system, tester user)
#   vm.sh up [name]        boot an overlay of base (or of $VM_BACKING) as <name>
#   vm.sh ssh [cmd...]     run a command in the VM as tester
#   vm.sh scp SRC DST      copy a host file/dir into the VM (DST is a VM path)
#   vm.sh pull SRC DST     copy VM -> host
#   vm.sh kill             QMP quit (hard power-off, like pulling the plug)
#   vm.sh down             clean poweroff, wait for exit
#   vm.sh serve [dir]      HTTP server (guest sees it at 10.0.2.2:$VM_HTTP_PORT)
#   vm.sh watch            host tmux session 'serp-vm (override: VM_TMUX)': window 'tui' mirrors the VM-side
#                          tmux session 'tui' (what TUI scenarios drive), window 'serial' tails the console
#                          watch live:  tmux attach -t serp-vm (override: VM_TMUX)
#   vm.sh status
# Env: VM_RAM(4G) VM_CPUS(4) VM_SSH_PORT(2222) VM_HTTP_PORT(8000) VM_BACKING(base)
#      VM_DISPLAY(none|gtk|sdl: open a QEMU window with the VM console, e.g. VM_DISPLAY=gtk)
#      VM_REUSE=1 (up: keep the overlay of <name>, e.g. resume after kill)
#      VM_DISK(size arg for a fresh overlay, e.g. 4G) VM_NAME(default)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
img=$here/images state=$here/state out=$here/out
mkdir -p "$img" "$state" "$out"
img=$(readlink -f "$img") state=$(readlink -f "$state") out=$(readlink -f "$out") # short real paths (qmp socket path limit)

IMG_URL=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg-20261001.604814.qcow2
IMG_FILE=cloudimg.qcow2
RAM=${VM_RAM:-4G} CPUS=${VM_CPUS:-4} SSH_PORT=${VM_SSH_PORT:-2222} HTTP_PORT=${VM_HTTP_PORT:-8000}
NAME=${VM_NAME:-default}
KEY=$state/id_ed25519

die() { echo "vm.sh: $*" >&2; exit 1; }
for t in qemu-system-x86_64 qemu-img; do command -v $t >/dev/null || die "$t missing"; done

pidf() { echo "$state/$NAME.pid"; }
qmp() { echo "$state/$NAME.qmp"; }
alive() { [ -f "$(pidf)" ] && kill -0 "$(cat "$(pidf)")" 2>/dev/null; }

sshopts=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o IdentitiesOnly=yes)
vssh() { ssh "${sshopts[@]}" -p "$SSH_PORT" tester@127.0.0.1 "$@"; }

wait_ssh() { # wait_ssh <seconds>
	local i
	for ((i = 0; i < ${1:-180}; i++)); do
		alive || die "qemu exited early (see $state/$NAME.serial.log)"
		vssh true 2>/dev/null && return 0
		sleep 1
	done
	die "ssh did not come up in ${1:-180}s"
}

qemu_args() { # qemu_args <disk> [extra...]
	local disk=$1; shift
	local acc=()
	if [ -w /dev/kvm ]; then acc=(-enable-kvm -cpu host); else acc=(-cpu max); fi
	rm -f "$(pidf)" "$(qmp)"
	qemu-system-x86_64 "${acc[@]}" -machine q35 -m "$RAM" -smp "$CPUS" \
		-display "${VM_DISPLAY:-none}" -serial "file:$state/$NAME.serial.log" \
		-qmp "unix:$(qmp),server=on,wait=off" -pidfile "$(pidf)" -daemonize \
		-drive "file=$disk,if=virtio,format=qcow2,cache=writeback" \
		-nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
		"$@"
}

cmd_fetch() {
	if [ ! -f "$img/$IMG_FILE" ]; then
		curl -fL -o "$img/$IMG_FILE.part" "$IMG_URL" && mv "$img/$IMG_FILE.part" "$img/$IMG_FILE"
	fi
	local want
	want=$(curl -fsSL "$IMG_URL.SHA256" | awk '{print $1}')
	echo "$want  $img/$IMG_FILE" | sha256sum -c - || die "sha256 mismatch for the cloud image"
}

cmd_base() {
	command -v xorriso >/dev/null || die "xorriso missing"
	cmd_fetch
	[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C serp-vm-stand -f "$KEY"
	local ci=$state/ci; rm -rf "$ci"; mkdir -p "$ci"
	cat >"$ci/meta-data" <<M
instance-id: serp-stand-base
local-hostname: serpvm
M
	cat >"$ci/user-data" <<U
#cloud-config
users:
  - name: tester
    shell: /bin/bash
    groups: [wheel]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: tester
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
growpart: {mode: auto, devices: ['/']}
resize_rootfs: true
U
	xorriso -as mkisofs -quiet -o "$state/cidata.iso" -V cidata -J -r "$ci" 2>/dev/null
	rm -f "$img/base.qcow2"
	qemu-img convert -O qcow2 "$img/$IMG_FILE" "$img/base.qcow2"
	qemu-img resize -q "$img/base.qcow2" 20G
	NAME=build
	qemu_args "$img/base.qcow2" -drive "file=$state/cidata.iso,if=virtio,format=raw,media=cdrom,readonly=on"
	wait_ssh 300
	# Update once; the stand starts from here ("naked TTY": no graphics).
	vssh 'sudo pacman-key --init && sudo pacman-key --populate archlinux >/dev/null 2>&1; sudo pacman -Syu --noconfirm --needed tmux zstd git sudo jq 2>&1 | tail -3; sudo touch /etc/cloud/cloud-init.disabled; sync'
	vssh 'sudo systemctl poweroff' || true
	for _ in $(seq 60); do alive || break; sleep 1; done
	alive && die "build vm did not power off"
	echo "base ready: $(qemu-img info "$img/base.qcow2" | grep 'disk size')"
}

cmd_up() {
	NAME=${1:-$NAME}
	alive && die "VM '$NAME' already running"
	local backing=${VM_BACKING:-base}
	[ -f "$img/$backing.qcow2" ] || die "no $img/$backing.qcow2 (run: vm.sh base)"
	if [ "${VM_REUSE:-}" = 1 ] && [ -f "$img/$NAME.qcow2" ]; then
		: # boot the existing overlay again (after a hard kill)
	else
		rm -f "$img/$NAME.qcow2" "$state/$NAME.serial.log"
		qemu-img create -q -f qcow2 -b "$img/$backing.qcow2" -F qcow2 "$img/$NAME.qcow2" ${VM_DISK:-}
	fi
	qemu_args "$img/$NAME.qcow2"
	wait_ssh "${VM_BOOT_TIMEOUT:-240}"
	echo "VM $NAME up (ssh port $SSH_PORT)"
}

cmd_kill() {
	alive || { echo "not running"; return 0; }
	python3 -I - "$(qmp)" <<'P' || kill -9 "$(cat "$(pidf)")"
import socket,sys
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.recv(4096)
s.send(b'{"execute":"qmp_capabilities"}'); s.recv(4096)
s.send(b'{"execute":"quit"}')
P
	for _ in $(seq 20); do alive || break; sleep 0.5; done
}

cmd_netlink() { # netlink on|off : QMP set_link of the guest NIC (no host network change)
	python3 -I - "$(qmp)" "${1:?on|off}" <<'P'
import socket,sys,json
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.recv(4096)
s.send(b'{"execute":"qmp_capabilities"}'); s.recv(4096)
s.send(json.dumps({"execute":"set_link","arguments":{"name":"net0","up":sys.argv[2]=="on"}}).encode()); print(s.recv(4096).decode())
P
}

cmd_down() {
	alive || return 0
	vssh 'sudo systemctl poweroff' 2>/dev/null || true
	for _ in $(seq 60); do alive || return 0; sleep 1; done
	cmd_kill
}

cmd_serve() {
	local d=${1:-$out/dist}
	cd "$d" && exec python3 -I -m http.server "$HTTP_PORT" --bind 127.0.0.1
}

cmd_watch() {
	command -v tmux >/dev/null || { echo "vm.sh: host tmux missing, skipping watch" >&2; return 0; }
	tmux has-session -t ${VM_TMUX:-serp-vm} 2>/dev/null && return 0
	local sh="ssh -t ${sshopts[*]} -p $SSH_PORT tester@127.0.0.1"
	tmux new-session -d -s ${VM_TMUX:-serp-vm} -n tui -x 200 -y 50 "while :; do $sh 'tmux new -A -s tui' 2>/dev/null; sleep 2; done"
	tmux new-window -t ${VM_TMUX:-serp-vm} -n serial "tail -F $state/$NAME.serial.log"
	echo "watch live: tmux attach -t ${VM_TMUX:-serp-vm}   (window 'tui' = TUI, ctrl-b n = serial log)"
}

case ${1:-} in
fetch) cmd_fetch ;;
base) cmd_base ;;
up) shift; cmd_up "$@" ;;
ssh) shift; vssh "$@" ;;
scp) scp -r "${sshopts[@]}" -P "$SSH_PORT" "$2" "tester@127.0.0.1:$3" ;;
pull) scp -r "${sshopts[@]}" -P "$SSH_PORT" "tester@127.0.0.1:$2" "$3" ;;
kill) cmd_kill ;;
down) cmd_down ;;
watch) cmd_watch ;;
netlink) shift; cmd_netlink "$@" ;;
serve) shift; cmd_serve "$@" ;;
status) if alive; then echo "running pid $(cat "$(pidf)")"; else echo stopped; fi ;;
*) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
