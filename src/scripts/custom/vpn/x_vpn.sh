#!/usr/bin/env bash
# x_vpn.sh: command line of the Serpantinum VPN module (Xray core). Every command prints one JSON document.
#
#   x_vpn.sh status | nodes | connect [id] | disconnect | toggle | switch <id> | select <id> | next
#   x_vpn.sh refresh [--if-due] | set-subscription (URL on stdin) | clear-subscription | geo-update
#   x_vpn.sh ping | speed | watchdog [--loop] | validate | gen-config [--secrets] | doctor
#   x_vpn.sh install --print | --check | --apply [--root PREFIX]   (root layer; --apply is guarded)
#
# Test overrides: XVPN_STATE_DIR / XVPN_SECRETS_DIR / XVPN_DATA_DIR / XVPN_SETTINGS / XVPN_XRAY / XVPN_SYSTEMCTL.
DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}"
exec python3 -m xvpn "$@"
