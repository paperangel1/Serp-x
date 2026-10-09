#!/usr/bin/env bash
# Scenario 6: install over a real upstream 2.2.4 install (pinned a0d8292, telemetry call removed by
# tests/vm/upstream-no-telemetry.patch). The installer must detect it, back it up, convert it, keep user data.
. "$(dirname "$0")/../lib.sh"
sc_begin 06 over-upstream
UPSTREAM=a0d8292
build_dist
VMN=${VMN:-$SC} vm_fresh

echo "-- build the pinned upstream tree (telemetry patched out)"
U=$(mktemp -d); trap 'rm -rf "$U"' EXIT
git -C "$repo" archive --prefix=up/ "$UPSTREAM" | tar -x -C "$U"
(cd "$U/up" && patch -p1 -s <"$here/upstream-no-telemetry.patch") || { bad "patch applies"; sc_end; exit 1; }
! grep -rq "telemetry.sh --mode\|telemetry.sh\" --mode" "$U/up/install/install.sh" && ok "no telemetry call left in the upstream installer" || bad "telemetry call still present"
# non-interactive driver: the menu and the reboot prompt need a tty; choose hyprland and skip the big wallpaper pack
# (upstream's own telemetry id helper writes the version file while the modules are sourced, so on a clean box
# detect_install_state says "current" and nothing but src is deployed; force "fresh" to get a real first install)
sed -i 's/^run_installer_ui$/SELECTED_COMPOSITORS=(hyprland); INSTALL_FULL_WALLPAPERS=false/; s/^draw_completion_screen .*$/true/; s/^INSTALL_STATE=\$(detect_install_state)$/INSTALL_STATE=fresh/' "$U/up/install/install.sh"
grep -q '^INSTALL_STATE=fresh$' "$U/up/install/install.sh" || { bad "driver patch (INSTALL_STATE)"; sc_end; exit 1; }
tar -C "$U" -cf "$U/up.tar" up
$VM scp "$U/up.tar" /home/tester/ >/dev/null
vrun 'tar -xf up.tar && chmod +x up/install/install.sh'

echo "-- upstream install (network, slow)"
vrun "cd up && TERM=linux setsid bash install/install.sh </dev/null >~/up-install.log 2>&1; echo \$? >~/up-rc"
vrun 'echo up-rc=$(cat up-rc); tail -5 up-install.log' | sed 's/^/   | /'
vcheck "upstream install finished (exit 0)" '[ "$(cat up-rc)" = 0 ]'
vcheck "upstream marker: version 2.2.4, no fork marker" 'grep -q "SERPANTINUM_VERSION=\"2.2.4\"" ~/.local/state/serpantinum/version && ! grep -q FORK ~/.local/state/serpantinum/version'
vrun 'mkdir -p ~/Notes && echo "upstream era note" > ~/Notes/old.md && echo more > ~/Notes/old2.md && jq ".custom.marker=\"keepme\"" ~/.config/serpantinum/settings.json > /tmp/s.json && cp /tmp/s.json ~/.config/serpantinum/settings.json'
vcheck "upstream deployed the Hyprland config" 'test -f ~/.config/hypr/hyprland.lua'
vrun 'cd ~ && find .config/hypr .config/kitty .local/bin -maxdepth 2 | sort' >"$OUT/upstream-files.txt" 2>&1
data_sums >"$OUT/sums-before.txt"; cat "$OUT/sums-before.txt"
vrun 'cd ~ && find .config/serpantinum .config/hypr .local/bin -type f 2>/dev/null | sort | xargs sha256sum > /tmp/upstream-tree.sha'
vrun 'jq -S . ~/.config/serpantinum/settings.json > /tmp/orig-settings.json'

echo "-- our installer over it"
mk_config cfg.toml '["core","hotkeys","tools"]'
vrun "$INST install --config cfg.toml --yes --payload $PAY </dev/null >run1.log 2>&1; echo \$? >rc1"
vrun 'tail -25 run1.log' | sed 's/^/   | /'
vcheck "install over upstream: exit 0" '[ "$(cat rc1)" = 0 ]'
vcheck "Hyprland config redeployed (hyprland.lua + config/)" 'test -f ~/.config/hypr/hyprland.lua && test -d ~/.config/hypr/config'
vcheck "backup archive has the notes and no secrets" 'a=$(ls ~/serpantinum-backups/*.tar.zst | head -1); zstd -dc "$a" | tar -t | grep -q data/notes/old.md'
vcheck "automatic backup archive written" 'ls ~/serpantinum-backups/*.tar.zst | head -1 | grep -q .'
vcheck "version file converted (fork marker, no upstream telemetry id)" 'grep -q FORK_COMMIT ~/.local/state/serpantinum/version && ! grep -q TELEMETRY ~/.local/state/serpantinum/version'
vcheck "installed.json (modules) written" 'ls ~/.local/state/serpantinum-installer/ | grep -q . && ls ~/.config/serpantinum-x/modules.json'
data_sums >"$OUT/sums-after.txt"
check "user data unchanged (Notes + settings.json)" cmp "$OUT/sums-before.txt" "$OUT/sums-after.txt"
vcheck "settings.json custom key kept" '[ "$(jq -r .custom.marker ~/.config/serpantinum/settings.json)" = keepme ]'
vcheck "doctor ok" 'serpantinum-x doctor >doctor.log 2>&1 || ~/.local/bin/serpantinum-x doctor >doctor.log 2>&1; tail -5 doctor.log'
vcheck "upstream telemetry never contacted (no telemetry module run)" '! grep -qi telemetry up-install.log'
vcheck "rerun is idempotent: second install exit 0" "$INST install --config cfg.toml --yes --payload $PAY </dev/null >run2.log 2>&1"
sc_end
