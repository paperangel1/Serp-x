# shared helpers for scenarios/NN-*.sh   (source this file)
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
VM=$here/vm.sh
DIST=
PASS=0 FAILN=0 FAILED=()
INST=/home/tester/serp-installer
PAY=/home/tester/serp-x-vmtest.tar.zst

sc_begin() { # sc_begin NN name
	SC=$1-$2; OUT=$(readlink -f "$here/out")/$SC; rm -rf "$OUT"; mkdir -p "$OUT"; DIST=$OUT/dist  # per-scenario: parallel runs must not overwrite each other's build
	exec > >(tee "$OUT/run.log") 2>&1
	echo "== scenario $SC =="
}
ok() { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAILN=$((FAILN + 1)); FAILED+=("$1"); echo "FAIL - $1${2:+  ($2)}"; }
check() { # check "desc" cmd...   (cmd runs on the host)
	local d=$1; shift
	if "$@" >"$OUT/last.out" 2>&1; then ok "$d"; else bad "$d" "$(tail -c 300 "$OUT/last.out" | tr '\n' ' ')"; fi
}
vcheck() { # vcheck "desc" 'shell in the VM'
	local d=$1 c=$2
	if $VM ssh "$c" >"$OUT/last.out" 2>&1; then ok "$d"; else bad "$d" "$(tail -c 300 "$OUT/last.out" | tr '\n' ' ')"; fi
}
vrun() { $VM ssh "$@"; }
sc_end() {
	local logs=${1:-}
	collect_logs
	echo "== $SC: passed=$PASS failed=$FAILN =="
	if [ $FAILN = 0 ]; then echo "PASS $SC"; else printf 'FAIL %s: %s\n' "$SC" "${FAILED[*]}"; fi
	[ "${KEEP_VM:-}" = 1 ] || $VM down || true
	[ $FAILN = 0 ]
}
collect_logs() {
	$VM pull '.local/state/serpantinum-installer' "$OUT/" >/dev/null 2>&1 || true
	$VM pull '.local/state/serpantinum/logs' "$OUT/" >/dev/null 2>&1 || true
	$VM pull 'run.log' "$OUT/vm-run.log" >/dev/null 2>&1 || true
}

build_dist() {
	local t; t=$(mktemp -d)
	(cd "$repo/installer" && HOME=$t GOCACHE=${GOCACHE:-$HOME/.cache/go-build-vmstand} scripts/build.sh --version vmtest --out "$DIST" >"$OUT/build.log" 2>&1) \
		|| { cat "$OUT/build.log"; echo "build failed"; exit 1; }
	rm -rf "$t"
	[ -z "$(git -C "$repo" status --porcelain -- installer bin src config compositors)" ] || echo "NOTE: uncommitted changes are NOT in the payload (git ls-files tar) but ARE in the binary"
}

push_dist() {
	$VM scp "$DIST/serp-installer-vmtest-linux-amd64" /home/tester/serp-installer >/dev/null
	$VM scp "$DIST/serp-x-vmtest.tar.zst" /home/tester/ >/dev/null
	vrun 'chmod +x serp-installer'
}

vm_fresh() { # vm_fresh [backing]  -> boots overlay named $SC, pushes the build
	local n=${VMN:-$SC}; VM_BACKING=${1:-base} $VM up "$n" || exit 1
	export VM_NAME=$n
	$VM watch >/dev/null 2>&1 || true
	push_dist
}

# TUI helpers (VM-side tmux session "tui", mirrored on the host: tmux attach -t serp-vm)
tui_start() { # tui_start 'command line'
	vrun "tmux kill-session -t tui 2>/dev/null; tmux new-session -d -s tui -x 120 -y 36 \"$1; echo EXIT=\\\$? > /tmp/tui.exit; sleep 600\""
}
tui_screen() { vrun 'tmux capture-pane -p -t tui'; }
tui_keys() { vrun "tmux send-keys -t tui $*"; }
tui_wait() { # tui_wait 'regex' [seconds]  -> 0 if the screen shows it
	local i n=${2:-60}
	for ((i = 0; i < n; i++)); do
		tui_screen >"$OUT/screen.txt" 2>/dev/null
		grep -Eq -- "$1" "$OUT/screen.txt" && return 0
		sleep 1
	done
	return 1
}
tui_shot() { tui_screen >"$OUT/screen-$1.txt" 2>/dev/null; }

# after-core snapshot image (core only), built once; backing for the fast module scenarios
ensure_after_core() {
	local img; img=$(readlink -f "$here/images")
	[ -f "$img/after-core.qcow2" ] && return 0
	echo "-- building after-core image"
	VMN=build-core vm_fresh base
	vrun "$INST install --plain --yes --preset custom --modules core --payload $PAY </dev/null >core.log 2>&1; echo \$? >rc" 
	vrun '[ "$(cat rc)" = 0 ]' || { vrun 'tail -20 core.log'; echo "after-core build failed"; exit 1; }
	$VM down
	mv "$img/build-core.qcow2" "$img/after-core.qcow2"
}

# fake secret / data helpers for the backup scenarios
mk_config() { # mk_config <path-in-vm> <modules-toml-list> [with-secrets]
	local sec=''
	[ "${3:-}" = secrets ] && sec='gemini_key = "file:~/keys/gemini"'
	vrun "mkdir -p ~/keys && printf 'AIzaSyFAKEFAKEFAKEFAKEFAKEFAKEFAKE12345' > ~/keys/gemini && cat > $1 <<CFG
schema = 1
lang = \"en\"
preset = \"custom\"
modules = $2
[secrets]
$sec
[options]
notes_dir = \"~/Notes\"
commands_start_daemon = false
[run]
on_error = \"abort\"
finish = \"exit\"
CFG"
}
# settings.json is compared without general.location (stripped from backups by design; location.sh refreshes its updated_at on reinstall)
data_sums() { vrun 'cd ~ && { find Notes -type f 2>/dev/null | sort | xargs sha256sum; printf "%s  settings.json(normalized)\n" "$(jq -S "del(.general.location)" .config/serpantinum/settings.json | sha256sum | cut -d" " -f1)"; }'; }
