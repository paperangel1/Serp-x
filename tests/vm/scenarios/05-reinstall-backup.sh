#!/usr/bin/env bash
# Scenario 5: reinstall over an existing install (automatic backup), then restore from the
# archive after the data was lost: sha256 of user data must match, secrets listed as "enter again".
. "$(dirname "$0")/../lib.sh"
sc_begin 05 reinstall-backup
build_dist
vm_fresh
mk_config cfg.toml '["core","hotkeys","tools","ai-gemini"]' secrets
mk_config cfg0.toml '["core","hotkeys","tools","ai-gemini"]'
vrun "$INST install --config cfg.toml --yes --payload $PAY </dev/null >run1.log 2>&1; echo \$? >rc1"
vcheck "first install exit 0" '[ "$(cat rc1)" = 0 ] || { tail -15 run1.log; false; }'
vcheck "gemini key stored (600)" '[ "$(stat -c %a ~/.config/serpantinum/secrets/gemini_key)" = 600 ]'
vrun 'mkdir -p ~/Notes && echo "my precious note" > ~/Notes/n1.md && echo more > ~/Notes/n2.md && jq ".custom.marker=\"keepme\"" ~/.config/serpantinum/settings.json > /tmp/s.json && cp /tmp/s.json ~/.config/serpantinum/settings.json'
data_sums > "$OUT/sums-before.txt"; cat "$OUT/sums-before.txt"
vrun 'jq -S . ~/.config/serpantinum/settings.json > /tmp/orig-settings.json'
vrun "$INST install --config cfg.toml --reinstall --yes --payload $PAY </dev/null >run2.log 2>&1; echo \$? >rc2"
vcheck "reinstall over existing: exit 0" '[ "$(cat rc2)" = 0 ] || { tail -15 run2.log; false; }'
vcheck "automatic backup archive written" 'ls ~/serpantinum-backups/*.tar.zst | head -1 | grep -q .'
vcheck "local secrets copy kept (700/600)" 'f=$(ls ~/.local/share/serpantinum-installer/backups/*/secrets.tar 2>/dev/null | head -1); [ -n "$f" ] && [ "$(stat -c %a "$f")" = 600 ]'
data_sums > "$OUT/sums-after-reinstall.txt"
check "data unchanged by the reinstall" cmp "$OUT/sums-before.txt" "$OUT/sums-after-reinstall.txt"
vrun 'jq -S . ~/.config/serpantinum/settings.json | diff /tmp/orig-settings.json - ' > "$OUT/settings-diff-reinstall.txt" 2>&1; cat "$OUT/settings-diff-reinstall.txt"
ARCH=$(vrun 'ls -t ~/serpantinum-backups/*.tar.zst | head -1')
vcheck "archive has no secret values" '! zstd -dc '"$ARCH"' | tar -x -O 2>/dev/null | grep -q AIzaSyFAKE'
vrun 'rm -rf ~/Notes ~/.config/serpantinum'
vrun "$INST install --config cfg0.toml --restore $ARCH --yes --payload $PAY </dev/null >run3.log 2>&1; echo \$? >rc3"
vcheck "install with --restore: exit 0" '[ "$(cat rc3)" = 0 ] || { tail -15 run3.log; false; }'
data_sums > "$OUT/sums-restored.txt"
check "restored data sha256 equal to the original" cmp "$OUT/sums-before.txt" "$OUT/sums-restored.txt"
vcheck "\"enter again\" list mentions the Gemini key" 'grep -qiE "again|re-?enter|enter .* again" run3.log && grep -qi gemini run3.log'
sc_end
