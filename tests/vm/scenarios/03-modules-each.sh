#!/usr/bin/env bash
# Scenario 3: every module on its own on top of after-core, add then remove (modules mode);
# the diff of packages and files must match the manifest.
. "$(dirname "$0")/../lib.sh"
sc_begin 03 modules-each
build_dist
ensure_after_core
MODS=${MODS:-"hotkeys emoji tools ocr ai-gemini commands commands-media servers vpn"}
man=$repo/installer/manifests
toml_list() { # toml_list <file> <key>  -> items of a one-line or multi-line array
	awk -v k="$2" '$0 ~ "^"k" *= *\\[" {on=1} on {print} on && /\]/ {exit}' "$1" | grep -o '"[^"]*"' | tr -d '"'
}
for m in $MODS; do
	echo "-- module $m"
	VMN=$SC-$m vm_fresh after-core
	vrun 'pacman -Qq | sort > pk0; (cd ~ && find . -xdev \( -type f -o -type l \) -not -path "./.local/state/serpantinum-installer/*" -not -path "./.cache/*" | sort) > f0'
	need=$(grep -E '^requires *=' "$man/$m.toml" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ',')
	list=core,$need$m
	vrun "$INST modules --yes --modules ${list%,} --payload $PAY </dev/null >add.log 2>&1; echo \$? >rc"
	vcheck "$m: modules add exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 add.log; false; }'
	vcheck "$m: listed in modules.json" "jq -e '.enabled|index(\"$m\")' ~/.config/serpantinum-x/modules.json >/dev/null"
	for p in $(toml_list "$man/$m.toml" packages); do
		vcheck "$m: package $p installed" "pacman -Q $p"
	done
	for p in $(toml_list "$man/$m.toml" aur); do
		vcheck "$m: AUR package $p installed" "pacman -Q $p"
	done
	for f in $(toml_list "$man/$m.toml" root_files); do
		case $f in /etc/pacman.conf|/var/lib/pacman/db.lck) continue ;; esac
		vcheck "$m: root file $f exists" "sudo test -e $f -o -L $f"
	done
	vrun 'pacman -Qq | sort > pk1; (cd ~ && find . -xdev \( -type f -o -type l \) -not -path "./.local/state/serpantinum-installer/*" -not -path "./.cache/*" | sort) > f1; comm -13 f0 f1 > fnew; comm -13 pk0 pk1 > pnew'
	vrun 'cat fnew' > "$OUT/$m.files-added.txt"; vrun 'cat pnew' > "$OUT/$m.pkgs-added.txt"
	# nothing outside the shell's own dirs / the manifest's user_files may appear in $HOME
	vcheck "$m: new files only in known locations" 'bad=$(grep -vE "^\./(add\.log|rm\.log|rc|f[0-9]|pk[0-9]|fnew|pnew|serp-installer|serp-x-vmtest\.tar\.zst)$|^\./(\.config/(serpantinum|serpantinum-x|hypr|kitty|cava|fastfetch|systemd|quickshell|environment\.d)|\.local/(share|bin|state)|Notes|serpantinum-backups|\.bash|\.cache|\.gnupg|\.config/yay|\.config/pulse|\.config/pipewire|\.config/dconf|\.config/gtk|\.config/Mutagen|\.config/matugen|\.config/fontconfig|\.config/qt)" fnew); [ -z "$bad" ] || { echo "$bad"; false; }'
	# remove: modules mode with only core
	vrun "$INST modules --yes --modules core --payload $PAY </dev/null >rm.log 2>&1; echo \$? >rc"
	vcheck "$m: modules remove exit 0" '[ "$(cat rc)" = 0 ] || { tail -15 rm.log; false; }'
	vcheck "$m: dropped from modules.json" "! jq -e '.enabled|index(\"$m\")' ~/.config/serpantinum-x/modules.json >/dev/null"
	for f in $(toml_list "$man/$m.toml" root_files); do
		case $f in /etc/pacman.conf|/var/lib/pacman/db.lck|/usr/share/fonts/*) continue ;; esac
		vcheck "$m: root file $f removed" "! sudo test -e $f"
	done
	vrun '(cd ~ && find . -xdev \( -type f -o -type l \) -not -path "./.local/state/serpantinum-installer/*" -not -path "./.cache/*" | sort) > f2; comm -13 f0 f2' > "$OUT/$m.files-left-after-remove.txt"
	collect_logs; mkdir -p "$OUT/$m"; mv "$OUT/serpantinum-installer" "$OUT/$m/" 2>/dev/null
	$VM down
done
KEEP_VM=1 sc_end
