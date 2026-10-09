#!/usr/bin/env bash
# keep test runs out of the real module logs
export SERPANTINUM_LOG_DIR="${SERPANTINUM_LOG_DIR:-$(mktemp -d /tmp/serp-testlogs.XXXXXX)}"
export XDG_STATE_HOME="$(mktemp -d /tmp/serp-testxdg.XXXXXX)" XDG_CONFIG_HOME="$(mktemp -d /tmp/serp-testxdg.XXXXXX)" XDG_CACHE_HOME="$(mktemp -d /tmp/serp-testxdg.XXXXXX)"
# vpn_test.sh: offline tests of the VPN module. Never touches the network, systemd, routes or Happ:
# fake systemctl/xray/notify-send, localhost fake servers, temp dirs (see tests/vpn/common.py).
#   XVPN_REAL_XRAY=1 additionally runs `xray run -test` on inbound-less configs (isolated user+net namespace).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM="$(dirname "$DIR")"
fail=0
for f in "$CUSTOM"/vpn/x_vpn.sh; do bash -n "$f" || { echo "bash -n failed: $f"; fail=1; }; done
python3 - "$CUSTOM/vpn/system/serp-xray-helper.py" <<'PY' || fail=1
import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec"); print("helper compiles")
PY
cd "$DIR" || exit 1
PYTHONDONTWRITEBYTECODE=1 python3 -W error::ResourceWarning -m unittest discover -s vpn -p 'test_*.py' 2>&1 | tail -n 6 || fail=1
[ "${PIPESTATUS[0]}" = 0 ] || fail=1
exit $fail
