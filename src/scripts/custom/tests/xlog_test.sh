#!/usr/bin/env bash
# Unit tests of the shared logging layer (python lib, bash helper, redaction, rotation, CLI, report).
set -u
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B "$HERE/xlog/test_xlog.py" 2>&1 | tail -25
exit "${PIPESTATUS[0]}"
