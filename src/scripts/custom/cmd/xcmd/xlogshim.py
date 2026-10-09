"""Bridge to the shared serpantinum-x logging layer (custom/xlog/xlog.py), module name "cmd".
Missing or broken xlog must never break the engine: everything degrades to no-ops."""
import logging
import os
import sys

_XLOG = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "xlog"))
try:
    if _XLOG not in sys.path:
        sys.path.insert(0, _XLOG)
    import xlog as _xlog
    log = _xlog.get("cmd")
except Exception:                                            # pragma: no cover
    _xlog = None

    class _Null:
        def __getattr__(self, _name):
            return lambda *a, **k: None
    log = _Null()

_LEVEL = {logging.DEBUG: "debug", logging.INFO: "info", logging.WARNING: "warn", logging.ERROR: "error", logging.CRITICAL: "error"}


class XlogHandler(logging.Handler):
    """stdlib logging (daemon, triggers, sources use it) -> module log file."""

    def emit(self, record):
        try:
            msg = "%s: %s" % (record.name.replace("xcmd.", "", 1), record.getMessage())
            if record.exc_info:
                import traceback
                msg += "\n" + "".join(traceback.format_exception(*record.exc_info)).rstrip()
            _xlog.write_line("cmd", _LEVEL.get(record.levelno, "info"), msg)
        except Exception:
            pass


def install_bridge():
    """Idempotent: attach the handler to the "xcmd" logger tree."""
    if _xlog is None:
        return
    lg = logging.getLogger("xcmd")
    if not any(isinstance(h, XlogHandler) for h in lg.handlers):
        lg.addHandler(XlogHandler(level=logging.INFO))
        if lg.level == logging.NOTSET or lg.level > logging.INFO:
            lg.setLevel(logging.INFO)
