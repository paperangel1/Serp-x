#!/usr/bin/env bash
# Scenario 7: non-interactive install --config --restore --yes (my-setup.toml, file: secrets).
. "$(dirname "$0")/../lib.sh"
sc_begin 07 noninteractive-config
build_dist
vm_fresh
mk_config cfg.toml '["core","hotkeys","tools","ai-gemini"]' secrets
vrun "$INST install --config cfg.toml --yes --payload $PAY </dev/null >run1.log 2>&1; echo \$? >rc1"
vcheck "install --config --yes: exit 0" '[ "$(cat rc1)" = 0 ] || { tail -15 run1.log; false; }'
vrun 'mkdir -p ~/Notes && echo note-one > ~/Notes/a.md'
data_sums > "$OUT/sums-before.txt"
vrun "$INST backup export --out ~/exp </dev/null >exp.log 2>&1; echo \$? >rce"
vcheck "backup export exit 0, archive exists" '[ "$(cat rce)" = 0 ] && ls ~/exp/*.tar.zst'
vrun "$INST uninstall --yes --remove-data </dev/null >un.log 2>&1; echo \$? >rcu"
vcheck "uninstall --remove-data --yes: exit 0" '[ "$(cat rcu)" = 0 ] || { tail -15 un.log; false; }'
vcheck "user data really gone" '! test -e ~/Notes/a.md'
ARCH=$(vrun 'ls ~/exp/*.tar.zst | head -1')
vrun "$INST install --config cfg.toml --restore $ARCH --yes --payload $PAY </dev/null >run2.log 2>&1; echo \$? >rc2"
vcheck "install --config --restore --yes: exit 0" '[ "$(cat rc2)" = 0 ] || { tail -15 run2.log; false; }'
data_sums > "$OUT/sums-after.txt"
check "restored data sha256 equal" cmp "$OUT/sums-before.txt" "$OUT/sums-after.txt"
vcheck "secret from file: ref stored, value not in logs" 'test -s ~/.config/serpantinum/secrets/gemini_key && ! grep -rq AIzaSyFAKE ~/.local/state/serpantinum-installer ~/.local/state/serpantinum/logs run1.log run2.log'
vcheck "a literal secret in the config is refused" 'sed "s|file:~/keys/gemini|AIzaSyLITERAL1234567890|" cfg.toml > bad.toml; ! '"$INST"' install --config bad.toml --yes --payload '"$PAY"' </dev/null >bad.log 2>&1; ! grep -q AIzaSyLITERAL bad.log'
vcheck "an unknown key in the config is refused" 'printf "schema = 1\nbogus = 1\n" > bad2.toml; ! '"$INST"' install --config bad2.toml --yes --payload '"$PAY"' </dev/null >/dev/null 2>&1'
sc_end
