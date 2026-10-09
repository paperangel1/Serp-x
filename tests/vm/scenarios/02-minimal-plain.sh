#!/usr/bin/env bash
# Scenario 2: Minimal preset, --plain, from a bare TTY system.
. "$(dirname "$0")/../lib.sh"
sc_begin 02 minimal-plain
build_dist
vm_fresh
vrun "$INST install --plain --yes --preset minimal --payload $PAY </dev/null >run.log 2>&1; echo \$? >rc"
vcheck "installer exit 0" '[ "$(cat rc)" = 0 ] || { tail -20 run.log; false; }'
vcheck "version file" 'cat ~/.local/state/serpantinum/version | grep -q vmtest'
vcheck "serpantinum-x on PATH" '~/.local/bin/serpantinum-x --help >/dev/null 2>&1 || ~/.local/bin/serpantinum-x help >/dev/null 2>&1'
vcheck "hyprland config deployed" 'test -f ~/.config/hypr/hyprland.lua'
vcheck "installed.toml lists core" 'grep -rq core ~/.config/serpantinum-x/installed.toml ~/.local/state/serpantinum-installer/installed.toml 2>/dev/null'
vcheck "no vpn/xray units" '! systemctl list-unit-files 2>/dev/null | grep -qi xray'
vcheck "no telemetry traffic artefacts" '! grep -rqi "workers.dev" ~/.local/state/serpantinum-installer/logs'
vcheck "doctor" '~/.local/bin/serpantinum-x doctor'
sc_end
