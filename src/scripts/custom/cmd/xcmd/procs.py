"""External processes: one async runner (stub-able through PATH in tests), a trimmed environment for scripts and
discovery of the graphical session when the daemon runs under systemd --user."""
import asyncio
import glob
import os
import signal

from . import paths

KEEP_ENV = ("PATH", "HOME", "USER", "LANG", "LC_ALL", "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "DISPLAY",
            "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE")


class ProcResult:
    def __init__(self, rc, out="", err="", timed_out=False):
        self.rc, self.out, self.err, self.timed_out = rc, out, err, timed_out


def session_env(base=None):
    """Environment with the graphical session variables, found by scanning XDG_RUNTIME_DIR when missing."""
    env = dict(os.environ if base is None else base)
    rt = env.get("XDG_RUNTIME_DIR") or paths.runtime_dir()
    env.setdefault("XDG_RUNTIME_DIR", rt)
    if not env.get("WAYLAND_DISPLAY"):
        socks = sorted(p for p in glob.glob(os.path.join(rt, "wayland-*")) if not p.endswith(".lock"))
        if socks:
            env["WAYLAND_DISPLAY"] = os.path.basename(socks[0])
    if not env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        sigs = sorted(glob.glob(os.path.join(rt, "hypr", "*")), key=os.path.getmtime)
        if sigs:
            env["HYPRLAND_INSTANCE_SIGNATURE"] = os.path.basename(sigs[-1])
    if not env.get("DBUS_SESSION_BUS_ADDRESS") and os.path.exists(os.path.join(rt, "bus")):
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=" + os.path.join(rt, "bus")
    return env


def clean_env(base=None, extra=None):
    full = session_env(base)
    env = {k: full[k] for k in KEEP_ENV if k in full}
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    env.update(extra or {})
    return env


class ProcessRunner:
    def __init__(self, env_fn=session_env):
        self.env_fn = env_fn

    async def run(self, argv, timeout=30.0, stdin=None, env=None, cwd=None, capture=True):
        """Run argv. `capture=False` discards output (daemonising tools such as wl-copy keep pipes open)."""
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE if capture else asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE if capture else asyncio.subprocess.DEVNULL,
                env=env if env is not None else self.env_fn(), cwd=cwd, start_new_session=True)
        except FileNotFoundError:
            return ProcResult(127, "", "%s: команда не найдена" % argv[0])
        except OSError as e:
            return ProcResult(126, "", "%s: %s" % (argv[0], e))
        try:
            out, err = await asyncio.wait_for(proc.communicate(stdin.encode() if stdin is not None else None), timeout)
        except asyncio.TimeoutError:
            self._kill(proc)
            await proc.wait()
            return ProcResult(124, "", "таймаут %.0f с" % timeout, True)
        except asyncio.CancelledError:
            self._kill(proc)
            raise
        return ProcResult(proc.returncode, (out or b"").decode("utf-8", "replace"), (err or b"").decode("utf-8", "replace"))

    @staticmethod
    def _kill(proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
