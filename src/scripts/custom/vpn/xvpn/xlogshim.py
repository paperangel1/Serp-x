"""Bridge to the shared serpantinum-x logging layer (custom/xlog/xlog.py), module name "vpn".
Only node NAMES, states, reasons, counts and exit codes are logged: never URLs, UUIDs, addresses or configs.
A missing xlog degrades to no-ops."""
import os
import sys

_XLOG = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "xlog"))
try:
    if _XLOG not in sys.path:
        sys.path.insert(0, _XLOG)
    import xlog as _xlog
    log = _xlog.get("vpn")
except Exception:                                            # pragma: no cover
    class _Null:
        def __getattr__(self, _name):
            return lambda *a, **k: None
    log = _Null()
