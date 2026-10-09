"""Root-layer files: render, read-only drift check, and (explicitly guarded) install.

`print` and `check` never write anything. `apply` refuses unless XVPN_ALLOW_ROOT_INSTALL=1 is set, and
with --root PREFIX it writes into PREFIX instead of / (used by the tests). Nothing here is run by the
shell UI automatically.
"""
import getpass
import hashlib
import inspect
import os
import shutil
import subprocess
import re
import tempfile
from pathlib import Path

from . import config, core, paths, system

SYSTEM_DIR = Path(__file__).resolve().parent.parent / "system"

HELPER_DEST = "usr/local/lib/serpantinum-xray/serp-xray-helper"
UNIT_DEST = "etc/systemd/system/serp-xray.service"
UNBLOCK_DEST = "etc/systemd/system/serp-xray-unblock.service"
POLKIT_DEST = "etc/polkit-1/rules.d/49-serpantinum-xray.rules"


def _lit(items):
    """Deterministic set literal (set repr order depends on the hash seed, which made every render differ)."""
    return "{" + ", ".join(repr(x) for x in sorted(items)) + "}"


def _allowlist_source():
    """The root helper gets a verbatim copy of the allowlist from config.py (single source of truth)."""
    parts = [
        "class ConfigRejected(ValueError):\n    pass\n",
        f"ALLOWED_TOP = {_lit(config.ALLOWED_TOP)}\n",
        f"ALLOWED_INBOUND_PROTOCOLS = {_lit(config.ALLOWED_INBOUND_PROTOCOLS)}\n",
        f"_FILE_KEYS = {_lit(config._FILE_KEYS)}\n",
        inspect.getsource(config._walk),
        inspect.getsource(config.check_root_safe).replace("paths.TUN_NAME", "TUN"),
    ]
    return "\n".join(parts)


def render(user=None, home=None, xray=None):
    """-> {dest relative to root: (content, mode)}"""
    user = user or getpass.getuser()
    home = home or os.path.expanduser("~")
    xray = xray or core.xray_path()
    helper = "/" + HELPER_DEST
    sub = {"@USER@": user, "@HOME@": home, "@HELPER@": helper, "@XRAY@": xray}

    def tpl(name):
        t = (SYSTEM_DIR / name).read_text(encoding="utf-8")
        for k, v in sub.items():
            t = t.replace(k, v)
        return t

    helper_src = (SYSTEM_DIR / "serp-xray-helper.py").read_text(encoding="utf-8").replace("# @@ALLOWLIST@@", _allowlist_source())
    return {
        HELPER_DEST: (helper_src, 0o755),
        UNIT_DEST: (tpl("serp-xray.service.tpl"), 0o644),
        UNBLOCK_DEST: (tpl("serp-xray-unblock.service.tpl"), 0o644),
        POLKIT_DEST: (tpl("49-serpantinum-xray.rules.tpl"), 0o644),
    }


def _sha(data):
    return hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest()


_SETLIT = re.compile(r"^(ALLOWED_TOP|ALLOWED_INBOUND_PROTOCOLS|_FILE_KEYS) = (\{.*\})$", re.M)


def _canon(text):
    """Set literals printed by an older render had hash-random order: compare them as sorted sets."""
    import ast

    def fix(m):
        try:
            return f"{m.group(1)} = {sorted(ast.literal_eval(m.group(2)))!r}"
        except (ValueError, SyntaxError):
            return m.group(0)
    return _SETLIT.sub(fix, text)


def check(root=None, **kw):
    """Read-only. -> list of {"name","ok","detail"} comparing installed files with what render() produces."""
    root = Path(root or system.etc_root())
    rows = []
    for dest, (content, _mode) in render(**kw).items():
        p = root / dest
        try:
            data = p.read_bytes()
        except FileNotFoundError:
            rows.append({"name": "/" + dest, "ok": False, "detail": "missing"})
            continue
        except OSError:
            # e.g. /etc/polkit-1/rules.d is root:polkitd 0750: the user cannot look inside. Not "missing".
            rows.append({"name": "/" + dest, "ok": True, "unknown": True,
                         "detail": "не удалось проверить: нет прав на чтение каталога (это нормально для обычного пользователя)"})
            continue
        same = _sha(_canon(data.decode("utf-8", "replace"))) == _sha(_canon(content))
        rows.append({"name": "/" + dest, "ok": same, "detail": "ok" if same else "differs from the shipped template"})
    return rows


def print_all(**kw):
    out = []
    for dest, (content, mode) in render(**kw).items():
        out.append(f"===== /{dest} (mode {mode:o}) =====\n{content}")
    return "\n".join(out)


def apply(root=None, runner=subprocess.run, **kw):
    """Install the root layer. With `root` writes below that prefix (tests); otherwise through sudo."""
    files = render(**kw)
    if root:
        for dest, (content, mode) in files.items():
            p = Path(root) / dest
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
            os.chmod(p, mode)
        return {"ok": True, "root": str(root)}
    if os.environ.get("XVPN_ALLOW_ROOT_INSTALL") != "1":
        raise PermissionError("set XVPN_ALLOW_ROOT_INSTALL=1 to install the root layer (do this only when you are at the machine)")
    td = tempfile.mkdtemp(prefix="xvpn-install-")
    try:
        for dest, (content, mode) in files.items():
            sp = Path(td) / dest
            sp.parent.mkdir(parents=True, exist_ok=True)
            sp.write_text(content, encoding="utf-8")
        for dest, (_c, mode) in files.items():
            r = runner(["sudo", "-n", "install", "-D", "-o", "root", "-g", "root", "-m", f"{mode:o}", str(Path(td) / dest), "/" + dest],
                       capture_output=True, text=True)
            if r.returncode != 0:
                return {"ok": False, "error": f"install failed for /{dest}: {r.stderr.strip()[:120]}"}
        runner(["sudo", "-n", "systemctl", "daemon-reload"], capture_output=True, text=True)
    finally:
        shutil.rmtree(td, ignore_errors=True)
    return {"ok": True, "root": "/"}
