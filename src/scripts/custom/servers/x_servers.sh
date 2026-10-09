#!/usr/bin/env bash
# serpantinum-x servers <subcommand> — thin wrapper around x_servers.py
exec python3 "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/x_servers.py" "$@"
