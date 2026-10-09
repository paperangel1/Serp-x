#!/usr/bin/env bash
# Scenario 8: uninstall keeps user data; --remove-data removes it (after a backup).
. "$(dirname "$0")/../lib.sh"
sc_begin 08 uninstall
build_dist
ensure_after_core
VMN=$SC vm_fresh after-core
vrun "$INST modules --yes --modules core,hotkeys,tools,vpn,commands --payload $PAY </dev/null >mod.log 2>&1; echo \$? >rc"
vcheck "modules add: exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 mod.log; false; }'
vrun 'mkdir -p ~/Notes && echo keep-me > ~/Notes/keep.md; echo "{}" > /dev/null'
vcheck "before: serp-xray unit + root files present" 'test -f /etc/systemd/system/serp-xray.service; ls -d ~/.local/bin/serpantinum-x'
vrun 'ls /etc/systemd/system | grep -i -e serp -e xray; ls -la ~/.local/bin; systemctl --user list-unit-files | grep -i serp' >"$OUT/before-units.txt" 2>&1
vrun "$INST uninstall --yes </dev/null >un1.log 2>&1; echo \$? >rc"
vcheck "uninstall --yes: exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 un1.log; false; }'
vcheck "system units gone" '! ls /etc/systemd/system | grep -qiE "serp-xray|serpantinum"'
vcheck "root files gone (/usr/local/bin/serpantinum*, xray helper)" '! ls /usr/local/bin/serpantinum* /usr/local/lib/serpantinum-xray 2>/dev/null | grep -q .'
vcheck "user symlinks gone" '! ls ~/.local/bin/serpantinum* 2>/dev/null | grep -q .'
vcheck "user unit gone" '! systemctl --user list-unit-files 2>/dev/null | grep -q serpantinum-cmdd'
vcheck "~/.config/serpantinum kept" 'test -d ~/.config/serpantinum'
vcheck "~/Notes kept" 'test -f ~/Notes/keep.md'
vrun 'ls /etc/systemd/system | grep -i -e serp -e xray; ls -la ~/.local/bin; find ~/.config/serpantinum* ~/.local/share/serpantinum* -maxdepth 2' >"$OUT/after-units.txt" 2>&1
# second round: reinstall, then wipe data too
vrun "$INST install --yes --plain --preset custom --modules core,tools --payload $PAY </dev/null >in2.log 2>&1; echo \$? >rc"
vcheck "reinstall after uninstall: exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 in2.log; false; }'
# upstream location.sh (run by the install) leaves a background weather.sh that rewrites settings.json when it ends; let it finish
vrun 'for i in $(seq 90); do pgrep -f "weather.sh|location.sh" >/dev/null || break; sleep 1; done'
vrun "$INST uninstall --yes --remove-data </dev/null >un2.log 2>&1; echo \$? >rc"
vcheck "uninstall --remove-data: exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 un2.log; false; }'
vcheck "data removed (~/.config/serpantinum, ~/Notes)" '! test -e ~/.config/serpantinum && ! test -e ~/Notes/keep.md'
vcheck "a backup was taken before removing data" 'ls ~/serpantinum-backups/*.tar.zst'
sc_end
