"""Wi-Fi radio policy.

The Pi Zero 2 W puts Wi-Fi and Bluetooth on one chip behind one antenna, and
running Bluetooth audio next to an active Wi-Fi upload is the classic source of
dropouts. Rather than tune around that, the appliance sidesteps it: while a
recording is running the Wi-Fi interface is down and the audio has the air to
itself; when the recording ends the interface comes back up and the queue drains.

That is only acceptable because the recording is durable first and uploaded
second. Nothing is lost by staying offline for the length of a meeting.
"""

from __future__ import annotations

import logging
import shutil
import subprocess

LOG = logging.getLogger(__name__)

INTERFACE = "wlan0"
_NMCLI = "nmcli"
_COMMAND_TIMEOUT_S = 20


def _run(argv: list[str]) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=_COMMAND_TIMEOUT_S, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        LOG.warning("%s failed: %s", argv[0], error)
        return 1, str(error)
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def available() -> bool:
    return shutil.which(_NMCLI) is not None


def enable() -> bool:
    """Bring the radio back up. Safe to call when it is already up."""
    code, _ = _run([_NMCLI, "radio", "wifi", "on"])
    return code == 0


def disable() -> bool:
    """Silence the radio for the duration of a recording."""
    code, _ = _run([_NMCLI, "radio", "wifi", "off"])
    return code == 0


def online() -> bool:
    """Whether the appliance currently has a usable network path."""
    code, output = _run([_NMCLI, "-t", "-f", "STATE", "general"])
    return code == 0 and "connected" in output and "disconnected" not in output


def known_networks() -> list[str]:
    code, output = _run([_NMCLI, "-t", "-f", "NAME", "connection", "show"])
    if code != 0:
        return []
    return [line.strip() for line in output.splitlines() if line.strip()]


def scan() -> list[dict]:
    """Networks in range, strongest first, ready to show in the app."""
    _run([_NMCLI, "device", "wifi", "rescan"])
    code, output = _run([_NMCLI, "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"])
    if code != 0:
        return []
    seen: dict[str, dict] = {}
    for line in output.splitlines():
        parts = line.split(":")
        if len(parts) < 3 or not parts[0]:
            continue
        ssid = parts[0]
        try:
            signal = int(parts[1])
        except ValueError:
            signal = 0
        entry = {"ssid": ssid, "signal": signal, "secured": bool(parts[2].strip())}
        if ssid not in seen or seen[ssid]["signal"] < signal:
            seen[ssid] = entry
    return sorted(seen.values(), key=lambda item: item["signal"], reverse=True)


def _existing_profile(ssid: str) -> str | None:
    """The name of a saved profile for this network, if there is one.

    A device that has been on a network before — every device that shipped with
    Wi-Fi details, and every device set up twice — already has a profile for it.
    """
    code, output = _run([_NMCLI, "-t", "-f", "NAME", "connection", "show"])
    if code != 0:
        return None
    for name in (line.strip() for line in output.splitlines()):
        if not name:
            continue
        found, saved = _run([_NMCLI, "-g", "802-11-wireless.ssid", "connection", "show", name])
        if found == 0 and saved.strip() == ssid:
            return name
    return None


def join(ssid: str, password: str | None) -> tuple[bool, str]:
    """Join a network with credentials the app supplied over Bluetooth.

    NetworkManager keeps the credentials; the appliance deliberately does not
    store a second copy of a password it would then have to protect.

    Saved profiles are updated rather than worked around. ``nmcli device wifi
    connect`` reuses whatever profile it finds for the network and ignores the
    password it was handed, so on a device that had seen the network before it
    failed with "802-11-wireless-security.key-mgmt: property is missing" — and
    the app told the owner their correct password was wrong.
    """
    enable()
    profile = _existing_profile(ssid)
    if profile is not None:
        settings = ["802-11-wireless-security.key-mgmt", "wpa-psk" if password else "none"]
        if password:
            settings += ["802-11-wireless-security.psk", password]
        code, output = _run([_NMCLI, "connection", "modify", profile, *settings])
        if code == 0:
            code, output = _run([_NMCLI, "connection", "up", profile])
    else:
        argv = [_NMCLI, "device", "wifi", "connect", ssid]
        if password:
            argv += ["password", password]
        code, output = _run(argv)
    if code == 0:
        return True, ""
    return False, _why_it_failed(output)


def _why_it_failed(output: str) -> str:
    """Plain words for the owner, and never the wrong diagnosis.

    "Secrets were required" is the only output that actually means the password
    was refused. Matching the looser "802-11-wireless-security" blamed the owner
    for a configuration fault on the device itself.
    """
    if "Secrets were required" in output:
        return "That password was not accepted."
    if "No network with SSID" in output or "not found" in output:
        return "That network is not in range."
    return "Could not join that network."
