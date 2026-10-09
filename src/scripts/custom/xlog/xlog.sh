#!/usr/bin/env bash
# serpantinum-x logging for shell scripts. Source it, then:  xlog <module> <level> <message...>
#   xlog hotkeys info "apply finished rc=0"
# Writes through xlog.py (one redaction implementation); never fails the caller.
XLOG_PY="${XLOG_PY:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/xlog.py}"
xlog() {   # xlog <module> <debug|info|warn|error> <message...>
    local m="$1" l="$2"
    shift 2
    PYTHONDONTWRITEBYTECODE=1 python3 "$XLOG_PY" append "$m" "$l" "$*" >/dev/null 2>&1 || true
    return 0
}
# xlog_run <module> <cmd...>: run a command, log its name + exit code + duration (arguments are NOT logged).
xlog_run() {
    local m="$1" t0 rc
    shift
    t0=$(date +%s%3N)
    "$@"
    rc=$?
    xlog "$m" "$([ "$rc" -eq 0 ] && echo info || echo warn)" "exec cmd=$(basename "$1") rc=$rc ms=$(( $(date +%s%3N) - t0 ))"
    return $rc
}
