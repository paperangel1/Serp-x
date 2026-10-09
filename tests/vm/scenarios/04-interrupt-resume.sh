#!/usr/bin/env bash
# Scenario 4: hard power-off (QMP quit) in the middle of pkg.repo and of deploy.code,
# boot again, --resume must finish, the journal must not contain a step done twice.
. "$(dirname "$0")/../lib.sh"
sc_begin 04 interrupt-resume
build_dist
for target in pkg.repo deploy.code; do
	echo "-- kill during $target"
	VMN=$SC-${target//./-}; vm_fresh
	# VM-side watcher: when the step starts, wait DELAY seconds and cut the power (sysrq 'o' = no sync, no
	# clean shutdown); this is the closest thing to pulling the plug and it is much more precise than a
	# kill from the host over ssh.
	delay=0.05; [ $target = pkg.repo ] && delay=25
	vrun "sudo sh -c 'echo 1 > /proc/sys/kernel/sysrq'; cat > cut.sh <<'W'
j=\$HOME/.local/state/serpantinum-installer/journal.jsonl
until grep -qs '\"step\":\"$target\",\"ev\":\"start\"' \$j; do sleep 0.02; done
sleep $delay
sync -f /dev/null; echo o | sudo tee /proc/sysrq-trigger >/dev/null
W
setsid nohup bash cut.sh </dev/null >/dev/null 2>&1 &
setsid nohup $INST install --plain --yes --preset minimal --payload $PAY </dev/null >run1.log 2>&1 &"
	for i in $(seq 1800); do $VM status | grep -q stopped && break; sleep 1; done
	$VM status | grep -q stopped && ok "VM lost power during $target" || { bad "VM lost power during $target"; $VM kill; }
	VM_REUSE=1 $VM up "$VM_NAME" >/dev/null
	[ $target = pkg.repo ] && vcheck "journal shows $target start without done" "! grep -q '\"step\":\"$target\",\"ev\":\"done\"' ~/.local/state/serpantinum-installer/journal.jsonl"
	vrun "$INST install --plain --yes --resume --preset minimal --payload $PAY </dev/null >run2.log 2>&1; echo \$? >rc2"
	vcheck "$target: --resume exit 0" '[ "$(cat rc2)" = 0 ] || { tail -15 run2.log; false; }'
	vcheck "$target: version state written" 'test -f ~/.local/state/serpantinum/version'
	vcheck "$target: no step is done twice in the journal" 'd=$(jq -r "select(.ev==\"done\")|.step" ~/.local/state/serpantinum-installer/journal.jsonl | sort | uniq -d); [ -z "$d" ] || { echo "dup: $d"; false; }'
	vcheck "$target: finish event present" 'grep -q "\"ev\":\"finish\"" ~/.local/state/serpantinum-installer/journal.jsonl || grep -q "\"step\":\"finish\"" ~/.local/state/serpantinum-installer/journal.jsonl'
	vcheck "$target: db.lck gone" '! test -e /var/lib/pacman/db.lck'
	vcheck "$target: pacman database consistent" 'sudo pacman -Dk'
	vcheck "$target: deployed code complete (hyprland config + shell)" 'test -f ~/.config/hypr/hyprland.lua && test -f ~/.local/share/serpantinum/src/scripts/custom/x_keybinds.sh'
	collect_logs; mkdir -p "$OUT/$target"; mv "$OUT/serpantinum-installer" "$OUT/$target/" 2>/dev/null
	$VM down
done
KEEP_VM=1 sc_end
