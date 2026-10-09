"""Locations used by the commands engine. Every one can be overridden by an environment variable (tests)."""
import os

PKG_DIR = os.path.dirname(os.path.abspath(__file__))
CMD_DIR = os.path.dirname(PKG_DIR)                      # .../scripts/custom/cmd


def _home():
    return os.path.expanduser("~")


def commands_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")
    return os.environ.get("XCMD_COMMANDS_DIR") or os.path.join(base, "serpantinum", "commands")


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(_home(), ".local", "state")
    return os.environ.get("XCMD_STATE_DIR") or os.path.join(base, "serpantinum", "commands")


def runtime_dir():
    return os.environ.get("XDG_RUNTIME_DIR") or "/tmp/serpantinum-%d" % os.getuid()


def socket_path():
    return os.environ.get("XCMD_SOCKET") or os.path.join(runtime_dir(), "serpantinum", "cmdd.sock")


def nodes_dirs():
    dirs = [os.path.join(CMD_DIR, "nodes")]
    extra = os.environ.get("XCMD_EXTRA_NODES", "")
    dirs += [d for d in extra.split(os.pathsep) if d]
    return dirs


def unit_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")
    return os.environ.get("XCMD_UNIT_DIR") or os.path.join(base, "systemd", "user")


def desktop_dir():
    """Where the launcher entries go (XDG applications dir)."""
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(_home(), ".local", "share")
    return os.environ.get("XCMD_DESKTOP_DIR") or os.path.join(base, "applications")


def desktop_templates_dir():
    return os.environ.get("XCMD_DESKTOP_TPL_DIR") or os.path.normpath(os.path.join(CMD_DIR, "..", "..", "..", "assets", "custom-desktop"))


def examples_dir():
    return os.path.join(CMD_DIR, "examples")


def unit_template():
    return os.path.join(CMD_DIR, "systemd", "serpantinum-cmdd.service")


def serpantinum_bin():
    return os.environ.get("XCMD_SERPANTINUM_BIN") or "serpantinum"


def systemctl_bin():
    return os.environ.get("XCMD_SYSTEMCTL") or "systemctl"


def install_dir():
    return os.environ.get("SERPANTINUM_INSTALL_DIR") or os.path.join(_home(), ".local", "share", "serpantinum")


def bin_x():
    """Absolute path of serpantinum-x for the unit file: the installed copy, never a working checkout.
    Order: XCMD_BIN_X, ~/.local/bin/serpantinum-x, <install>/bin/serpantinum-x, and only then (nothing installed,
    e.g. running straight from a checkout) the copy this module lives in."""
    if os.environ.get("XCMD_BIN_X"):
        return os.environ["XCMD_BIN_X"]
    for cand in (os.path.join(_home(), ".local", "bin", "serpantinum-x"),
                 os.path.join(install_dir(), "bin", "serpantinum-x")):
        if os.path.exists(cand):
            return cand
    return os.path.normpath(os.path.join(CMD_DIR, "..", "..", "..", "..", "bin", "serpantinum-x"))


def assets_dir():
    """src/assets/custom-commands: gallery, docs and the tutorial (ours; mirrored by the update flow together with src/)."""
    return os.environ.get("XCMD_ASSETS_DIR") or os.path.normpath(os.path.join(CMD_DIR, "..", "..", "..", "assets", "custom-commands"))


def gallery_dir():
    return os.path.join(assets_dir(), "gallery")


def docs_src_dir(lang):
    return os.path.join(assets_dir(), "docs", lang)


def tutorial_file():
    return os.path.join(assets_dir(), "tutorial.json")
