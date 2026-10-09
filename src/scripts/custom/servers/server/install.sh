#!/bin/sh
# Serpantinum server-side installer. Idempotent. Run as root (or via sudo) with the payload next to this file:
#   serp-run, serp-root, commands.d/*, serp.conf.example
# Required env: SERP_PUBKEY  one "ssh-ed25519 AAAA... comment" line (the widget's restricted key)
# Optional env: SERP_USER (default serp). Argument "remove" uninstalls (the account itself is kept).
# Test mode (unprivileged, only for the automated tests): SERP_TEST=1 with SERP_PREFIX and SERP_AUTH_KEYS.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

HERE=$(cd "$(dirname "$0")" && pwd)
SERP_USER=${SERP_USER:-serp}
PFX=${SERP_PREFIX:-}
TEST=${SERP_TEST:-}
SBIN="$PFX/usr/local/sbin"
CONFDIR="$PFX/etc/serpantinum"
CMDDIR="$CONFDIR/commands.d"
SUDOERS="$PFX/etc/sudoers.d/serpantinum"

say() { printf '%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

if [ -n "$TEST" ]; then
    [ "$(id -u)" != "0" ] || die "SERP_TEST разрешён только без root"
    [ -n "$PFX" ] || die "SERP_TEST требует SERP_PREFIX"
else
    [ "$(id -u)" = "0" ] || die "нужны права root (запустите через sudo)"
fi

auth_keys_path() {
    if [ -n "${SERP_AUTH_KEYS:-}" ]; then printf '%s' "$SERP_AUTH_KEYS"; return; fi
    home=$(getent passwd "$SERP_USER" | cut -d: -f6)
    [ -n "$home" ] || die "не найден домашний каталог пользователя $SERP_USER"
    printf '%s/.ssh/authorized_keys' "$home"
}

if [ "${1:-}" = "remove" ]; then
    rm -f "$SBIN/serp-run" "$SBIN/serp-root" "$SUDOERS"
    rm -rf "$CMDDIR"
    ak=$(auth_keys_path 2>/dev/null || true)
    [ -n "$ak" ] && rm -f "$ak"
    say "SERP_REMOVE_OK"
    exit 0
fi

KEY=${SERP_PUBKEY:-}
[ -n "$KEY" ] || die "не задан SERP_PUBKEY"
printf '%s\n' "$KEY" | grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( [A-Za-z0-9._@-]+)?$' || die "публичный ключ имеет неверный формат"
for f in serp-run serp-root commands.d; do [ -e "$HERE/$f" ] || die "в пакете нет $f"; done

# 1. account (no password, key login only)
if [ -z "$TEST" ]; then
    if ! id "$SERP_USER" >/dev/null 2>&1; then
        useradd --system --create-home --home-dir "/var/lib/$SERP_USER" --shell /bin/sh -p '*' "$SERP_USER" 2>/dev/null \
            || useradd -r -m -d "/var/lib/$SERP_USER" -s /bin/sh -p '*' "$SERP_USER" \
            || die "не удалось создать пользователя $SERP_USER"
        say "создан пользователь $SERP_USER"
    fi
fi

# 2. programs and allowlisted scripts (root-owned, not writable by others)
mkdir -p "$SBIN" "$CMDDIR"
install -m 0755 "$HERE/serp-run" "$SBIN/serp-run"
install -m 0755 "$HERE/serp-root" "$SBIN/serp-root"
if [ -n "$TEST" ]; then
    # unprivileged test mode: point the installed copies at the prefix and skip sudo
    sed -i -e "s|/usr/local/sbin/serp-root|$SBIN/serp-root|" -e 's|exec sudo -n "\$SERP_ROOT_HELPER"|exec "$SERP_ROOT_HELPER"|' "$SBIN/serp-run"
    sed -i -e "s|/etc/serpantinum/commands.d|$CMDDIR|" -e "s|/etc/serpantinum/serp.conf|$CONFDIR/serp.conf|" \
        -e 's|^umask 077$|umask 077\nSERP_TEST=1|' "$SBIN/serp-root"
fi
[ -f "$CONFDIR/serp.conf" ] || install -m 0644 "$HERE/serp.conf.example" "$CONFDIR/serp.conf"
for f in "$HERE"/commands.d/*; do
    [ -f "$f" ] || continue
    install -m 0755 "$f" "$CMDDIR/$(basename "$f")"
done
# drop scripts that are no longer part of the allowlist
for f in "$CMDDIR"/*; do
    [ -e "$f" ] || continue
    [ -e "$HERE/commands.d/$(basename "$f")" ] || rm -f "$f"
done
if [ -n "$TEST" ]; then
    # never let a test run a real action on the machine: replace every act-* script with a harmless stub
    for f in "$CMDDIR"/act-*; do
        [ -f "$f" ] || continue
        printf '#!/bin/sh\necho "TEST STUB %s"\n' "$(basename "$f")" > "$f"
        chmod 0755 "$f"
    done
fi
[ -n "$TEST" ] || { chown -R root:root "$CMDDIR" "$SBIN/serp-run" "$SBIN/serp-root"; chmod 0755 "$CMDDIR"; }

# 3. sudo: exactly one root helper, validated before it goes live
if [ -z "$TEST" ] || command -v visudo >/dev/null 2>&1; then
    mkdir -p "$(dirname "$SUDOERS")"
    tmp=$(mktemp)
    printf '%s ALL=(root) NOPASSWD: %s/serp-root\n' "$SERP_USER" "/usr/local/sbin" > "$tmp"
    if command -v visudo >/dev/null 2>&1; then
        visudo -cf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "sudoers не прошёл проверку visudo"; }
    elif [ -z "$TEST" ]; then
        rm -f "$tmp"; die "visudo не найден: нельзя безопасно настроить sudo"
    fi
    install -m 0440 "$tmp" "$SUDOERS"
    rm -f "$tmp"
fi

# 4. the restricted key
ak=$(auth_keys_path)
mkdir -p "$(dirname "$ak")"
RUNPATH=/usr/local/sbin/serp-run
[ -z "$TEST" ] || RUNPATH="$SBIN/serp-run"
printf 'restrict,command="%s" %s\n' "$RUNPATH" "$KEY" > "$ak"
if [ -z "$TEST" ]; then
    chown -R "$SERP_USER:$SERP_USER" "$(dirname "$ak")"
    chmod 0700 "$(dirname "$ak")"; chmod 0600 "$ak"
else
    chmod 0600 "$ak"
fi
say "SERP_INSTALL_OK"
