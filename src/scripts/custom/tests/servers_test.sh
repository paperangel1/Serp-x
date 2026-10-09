#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
# Runs the offline Servers backend tests (python unittest). Only 127.0.0.1 high ports; no real config/secrets/servers.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1
out=$(python3 servers_test.py 2>&1); rc=$?
printf '%s\n' "$out" | tail -n 25
n=$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) tests.*/\1/p')
f=$(printf '%s\n' "$out" | sed -n 's/^FAILED (\(.*\))$/\1/p')
if [ $rc -eq 0 ]; then echo "servers_test: ${n:-?} passed, 0 failed"; else echo "servers_test: FAILED ($f) of ${n:-?}"; fi
exit $rc
