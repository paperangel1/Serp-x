#!/usr/bin/env bash
# Scenario 9: understandable errors: no network, no disk space, run as root.
. "$(dirname "$0")/../lib.sh"
sc_begin 09 errors
build_dist
msgok() { # last.log has an error message, no Go panic
	vrun 'test -s e.log && ! grep -qE "panic|goroutine|runtime error|nil pointer" e.log'
}
echo "-- run as root"
VMN=$SC vm_fresh
vrun "sudo $INST install --plain --yes --preset minimal --payload $PAY </dev/null >e.log 2>&1; echo \$? >rc"
vcheck "root: refused (exit != 0)" '[ "$(cat rc)" != 0 ]'
vcheck "root: clear message" 'grep -qiE "root" e.log'
vcheck "root: no panic" 'msgok() { ! grep -qE "panic|goroutine" e.log; }; msgok'
vrun 'cat e.log' | sed 's/^/   | /'
vrun 'sudo test -d /root/.local/state/serpantinum-installer && echo "root state dir created" || true'
echo "-- no network"
# cut the default route INSIDE the VM (QMP set_link did nothing: the NIC id is not net0; ssh stays up, it is on-link)
vrun 'ip route show default | head -1 > /tmp/def.route; sudo ip route del default; ip route'
vcheck "offline really: no route to the internet" '! curl -sS -m 5 -o /dev/null https://geo.mirror.pkgbuild.com/ 2>/dev/null'
vrun "$INST install --plain --yes --preset minimal --payload $PAY </dev/null >e.log 2>&1; echo \$? >rc"
vcheck "offline: refused (exit != 0)" '[ "$(cat rc)" != 0 ]'
vcheck "offline: message mentions the network" 'grep -qiE "network|internet|connect" e.log'
vcheck "offline: no panic" '! grep -qE "panic|goroutine" e.log'
vcheck "offline: stopped at the system check, nothing was changed" 'grep -qi "nothing was changed" e.log'
vcheck "offline: nothing was installed (no version file)" '! test -f ~/.local/state/serpantinum/version'
vrun 'grep -E "FAIL|nothing was changed" e.log' | sed 's/^/   | /'
vrun 'sudo ip route add $(cat /tmp/def.route)'
echo "-- low disk space"
vrun 'free=$(df --output=avail -BM / | tail -1 | tr -dc 0-9); sudo fallocate -l $((free-600))M /fill.img; df -h / | tail -1'
vrun "$INST install --plain --yes --preset minimal --payload $PAY </dev/null >e.log 2>&1; echo \$? >rc"
vcheck "low space: refused (exit != 0)" '[ "$(cat rc)" != 0 ]'
vcheck "low space: message mentions disk space" 'grep -qiE "disk|space" e.log'
vcheck "low space: no panic" '! grep -qE "panic|goroutine" e.log'
vrun 'grep -E "FAIL|nothing was changed" e.log' | sed 's/^/   | /'
sc_end
