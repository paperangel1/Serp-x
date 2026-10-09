"""Event sources of stage 9c: Bluetooth devices (BlueZ over D-Bus) and the VPN module (its event log). Read-only:
nothing is connected, scanned, started or stopped. Logs carry the kind and the state only, never names or addresses."""
import json
import os
import re

from .procs import session_env
from .sources_b import ServersSource, StreamSource, run_text
from .xlogshim import log as xlog


# --------------------------------------------------------------------------------------------------- Bluetooth
DEV_PATH_RE = re.compile(r"path=/org/bluez/hci\d+/dev_([0-9A-Fa-f_]{17})[;\s]")
SIGNAL_RE = re.compile(r"^signal .*interface=org\.freedesktop\.DBus\.Properties; member=PropertiesChanged")
STR_RE = re.compile(r'^\s*string "([^"]*)"\s*$')
BOOL_RE = re.compile(r"^\s*variant\s+boolean (true|false)\s*$")


def bt_kind(icon):
    """BlueZ Icon property -> audio | input | other."""
    icon = (icon or "").lower()
    if icon.startswith("audio-"):
        return "audio"
    if icon.startswith("input-"):
        return "input"
    return "other"


class BluetoothParser:
    """State machine over `dbus-monitor --system` text lines: yields (mac, connected) for every
    PropertiesChanged of org.bluez.Device1 that carries `Connected`."""

    def __init__(self):
        self.mac = None
        self.iface_ok = False
        self.key = None

    def feed(self, line):
        if line.startswith("signal "):
            m = DEV_PATH_RE.search(line)
            self.mac = m.group(1).replace("_", ":") if m and SIGNAL_RE.match(line) else None
            self.iface_ok, self.key = False, None
            return None
        if self.mac is None:
            return None
        s = STR_RE.match(line)
        if s:
            v = s.group(1)
            if not self.iface_ok and v.startswith("org.bluez."):
                self.iface_ok = v == "org.bluez.Device1"
                self.key = None
            else:
                self.key = v
            return None
        b = BOOL_RE.match(line)
        if b and self.iface_ok and self.key == "Connected":
            self.key = None
            return self.mac, b.group(1) == "true"
        return None


class BluetoothSource(StreamSource):
    name = "bluetooth"
    types = ("bluetooth.device",)
    tool = "dbus-monitor"
    argv = ("dbus-monitor", "--system", "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'")
    missing_hint = " (пакет dbus)"

    def __init__(self):
        super().__init__()
        self.parser = BluetoothParser()
        self._last = {}

    async def lookup(self, mac):
        """Name and kind of a device (read-only BlueZ properties); '' / other when BlueZ does not answer."""
        path = "/org/bluez/hci0/dev_" + mac.replace(":", "_")
        out = {}
        for prop in ("Alias", "Icon"):
            raw = await run_text(["busctl", "--system", "--json=short", "get-property", "org.bluez", path, "org.bluez.Device1", prop], env=self.env())
            try:
                out[prop] = str(json.loads(raw).get("data") or "")
            except ValueError:
                out[prop] = ""
        return out["Alias"], bt_kind(out["Icon"])

    async def on_record(self, rec):
        hit = self.parser.feed(rec)
        if not hit:
            return
        mac, connected = hit
        if self._last.get(mac) == connected:
            return
        self._last[mac] = connected
        name, kind = await self.lookup(mac)
        xlog.info("bluetooth device", kind=kind, connected=connected)                # no name, no MAC
        await self.fire("bluetooth.device", {"name": name or mac, "mac": mac, "kind": kind, "connected": connected})


# ------------------------------------------------------------------------------------------------------- VPN
VPN_EVENTS = {"vpn.connected": "connected", "vpn.node_changed": "connected", "vpn.disconnected": "disconnected", "vpn.failed": "failed"}


def vpn_events_file():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.environ.get("XCMD_VPN_EVENTS") or os.environ.get("XVPN_EVENTS") or os.path.join(base, "serpantinum", "events.jsonl")


class VpnSource(ServersSource):
    """Tails the shared events bus (the VPN module appends vpn.connected / vpn.disconnected / vpn.failed / vpn.node_changed)."""
    name = "vpn"
    types = ("vpn.changed",)

    def __init__(self, path=None):
        super().__init__(path)
        self.node = ""

    def events_path(self):
        return self.path or vpn_events_file()

    def parse(self, line):
        try:
            ev = json.loads(line)
        except ValueError:
            return None
        state = VPN_EVENTS.get(ev.get("event")) if isinstance(ev, dict) else None
        if not state:
            return None
        if state == "connected":
            self.node = str(ev.get("node") or "")
        node = self.node if state != "failed" else str(ev.get("node") or "")
        data = {"state": state, "node": node, "connected": state == "connected", "reason": str(ev.get("reason") or "")}
        if state == "disconnected":
            self.node = ""
        return "vpn.changed", data

    def log_event(self, parsed):
        xlog.info("vpn event", state=parsed[1]["state"])
