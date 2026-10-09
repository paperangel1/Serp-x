#!/usr/bin/env bash
# Scenario 1: fresh Full install from a bare TTY, driven through the TUI (VM-side tmux "tui").
# Watch live: tmux attach -t serp-vm
. "$(dirname "$0")/../lib.sh"
sc_begin 01 full-tui
build_dist
vm_fresh
tui_start "$INST install --payload $PAY"
tui_wait 'Result: ready' 90; tui_shot 1-check; check "check screen: ready to go" tui_wait 'Result: ready' 1
tui_keys Enter; tui_wait 'Preset:' 20; tui_shot 2-modules
tui_keys Enter
for i in $(seq 25); do tui_wait 'Summary' 3 && grep -q '● Summary' "$OUT/screen.txt" && break; tui_keys Enter; sleep 1; done
tui_shot 3-summary
check "summary screen reached" grep -q 'Everything is ready to install' "$OUT/screen-3-summary.txt"
tui_keys Enter
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "${SC_TIMEOUT:-3000}" ]; do
	tui_screen >"$OUT/screen.txt" 2>/dev/null
	grep -q '● Done' "$OUT/screen.txt" && break
	grep -qiE 'failed|error' "$OUT/screen.txt" && grep -qiE 'retry|skip' "$OUT/screen.txt" && { tui_shot error; break; }
	sleep 10
done
tui_shot 4-finish
check "finish screen reached" grep -q '● Done' "$OUT/screen-4-finish.txt"
tui_keys q; sleep 2
vcheck "doctor has no FAIL" '! ~/.local/bin/serpantinum-x doctor | grep -q "^ *FAIL"'
vcheck "unit serpantinum-cmdd enabled" 'systemctl --user is-enabled serpantinum-cmdd'
vcheck "desktop entries present" 'ls ~/.local/share/applications/*.desktop /usr/share/applications/serp*.desktop 2>/dev/null | head -1 | grep -q .'
vcheck "serp-xray installed" 'test -f /etc/systemd/system/serp-xray.service'
vcheck "serp-xray NOT enabled and NOT active" '! systemctl is-enabled serp-xray 2>/dev/null | grep -q enabled && ! systemctl is-active serp-xray 2>/dev/null | grep -q "^active"'
vcheck "xray config test (xray run -test) if a config exists" 'c=$(ls ~/.local/share/serpantinum-x/vpn/*.json 2>/dev/null | head -1); [ -z "$c" ] || xray run -test -c "$c"'
vcheck "no telemetry endpoint anywhere in installed files" '! grep -rqs "dots-telemetry" ~/.local/share/serpantinum ~/.config/serpantinum 2>/dev/null || true'
sc_end
