"""Desktop notifications (notify-send; replaceable through XVPN_NOTIFY for tests). Never carries secrets."""
import os
import subprocess


def notify(title, body="", urgency="normal", icon="network-vpn"):
    cmd = [os.environ.get("XVPN_NOTIFY") or "notify-send", "-a", "Serpantinum VPN", "-u", urgency, "-i", icon, title, body]
    try:
        subprocess.run(cmd, capture_output=True, timeout=8)
        return True
    except (OSError, subprocess.SubprocessError):
        return False
