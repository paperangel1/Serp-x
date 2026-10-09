#!/usr/bin/env bash
# x_cmd.sh: command line of the Commands engine (visual programming, headless stage 1).
#
#   x_cmd.sh [--json] [--local] list | validate <name|file> | run <name> [--dry-run] [--yes] [--arg TEXT] [--steps]
#   x_cmd.sh run <name> [--rehearse [--answer JSON] [--sim-event TYPE=JSON]] [--event TYPE [--event-data JSON]] | trace <run|name> | traces [name]
#   x_cmd.sh log [-n N] | docs [--lang ru|en] [--out DIR] | status | pause|resume [name] | enable|disable <name>
#   x_cmd.sh pin|unpin <name> | pinned
#   x_cmd.sh approve <name> [--yes] | import <file> | install|uninstall [--print] | daemon | schema-check | doctor
#
# Entry points: `serpantinum-x cmd <sub>`, `serpantinum-x run "Name"`, `serpantinum run "Name"` (hook in bin/serpantinum).
# Test overrides: XCMD_COMMANDS_DIR XCMD_STATE_DIR XCMD_SOCKET XCMD_UNIT_DIR XCMD_SYSTEMCTL XCMD_SERPANTINUM_BIN XCMD_BIN_X.
DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1
exec python3 -m xcmd "$@"
