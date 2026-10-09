#!/usr/bin/env bash
# serpantinum-x backup: thin wrapper over the installer binary (serp-installer backup ...).
#
# usage: x_backup.sh export [--out DIR]     write serpantinum-backup-<host>-<date>.tar.zst (no secrets)
#        x_backup.sh import FILE            restore from such an archive
#
# env (mostly for tests): X_INSTALLER_BIN  path of the installer binary
# The binary is looked up in: $X_INSTALLER_BIN, ~/.local/share/serpantinum-x/installer/serp-installer, PATH.
# Exit codes: 0 ok, 2 usage, 3 installer binary not found, otherwise the installer's own code.
set -u

# shellcheck disable=SC1090
. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog/xlog.sh" 2>/dev/null || xlog() { :; }

DL="${X_LANG:-}"
[ -n "$DL" ] || DL="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
case "$DL" in ru*) DL=ru ;; *) DL=en ;; esac
tr_() { [ "$DL" = ru ] && printf '%s' "$1" || printf '%s' "$2"; }   # tr_ <ru> <en>

usage() {
    tr_ 'использование: serpantinum-x backup export [--out КАТАЛОГ] | import ФАЙЛ' 'usage: serpantinum-x backup export [--out DIR] | import FILE' >&2
    echo >&2
    return 2
}

find_installer() {
    local c
    for c in "${X_INSTALLER_BIN:-}" "${XDG_DATA_HOME:-$HOME/.local/share}/serpantinum-x/installer/serp-installer"; do
        [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    command -v serp-installer 2>/dev/null
}

case "${1:-}" in
    export|import) ;;
    *) usage; exit 2 ;;
esac
action="$1"; shift
if [ "$action" = import ] && { [ $# -ne 1 ] || [ ! -f "$1" ]; }; then
    [ $# -eq 1 ] && { tr_ "файл не найден: $1" "file not found: $1" >&2; echo >&2; xlog backup error "import: archive not found"; exit 2; }
    usage; exit 2
fi

bin="$(find_installer)" || bin=""
if [ -z "$bin" ]; then
    tr_ 'установщик не найден (serp-installer). Бэкап делает он; на этой установке его нет. Запусти установщик заново или положи бинарник в ~/.local/share/serpantinum-x/installer/.' \
        'installer not found (serp-installer). It performs backups and this install does not have it. Re-run the installer or put the binary in ~/.local/share/serpantinum-x/installer/.' >&2
    echo >&2
    xlog backup error "$action: installer binary not found"
    exit 3
fi

xlog backup info "$action: start"
"$bin" backup "$action" "$@"
rc=$?
if [ "$rc" -eq 0 ]; then xlog backup info "$action: finished rc=0"; else xlog backup error "$action: failed rc=$rc"; fi
exit "$rc"
