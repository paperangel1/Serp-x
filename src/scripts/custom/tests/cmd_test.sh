#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# cmd_test.sh: offline tests of the commands engine (schema, validator, engine, undo, loop guard, daemon protocol, CLI).
# Never touches the real desktop, network, systemd or ~/.config: fake notify-send/wl-copy/wl-paste/serpantinum/systemctl on
# PATH, temp dirs, a fake clock (see tests/cmd/common.py). UPDATE_GOLDEN=1 regenerates the golden files.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM="$(dirname "$DIR")"
fail=0
bash -n "$CUSTOM/cmd/x_cmd.sh" || { echo "bash -n failed: x_cmd.sh"; fail=1; }
for f in "$CUSTOM"/cmd/xcmd/*.py; do
    python3 - "$f" <<'PY' || { echo "does not compile: $f"; fail=1; }
import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")
PY
done
bash "$CUSTOM/cmd/x_cmd.sh" schema-check >/dev/null || { echo "schema-check failed"; fail=1; }
cd "$DIR" || exit 1
PYTHONDONTWRITEBYTECODE=1 python3 -W error::ResourceWarning -m unittest discover -s cmd -p 'test_*.py' 2>&1 | tail -n 6 || fail=1
[ "${PIPESTATUS[0]}" = 0 ] || fail=1
exit $fail
