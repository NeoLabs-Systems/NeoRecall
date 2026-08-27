"""Choosing where sound goes.

The relay itself is not built here — it is two ``pw-loopback`` units that run
independently of this process, so laptop audio keeps flowing even if the
recorder or the control service is restarted. Both loopbacks follow the *default*
sink and source, which means switching outputs is one small operation rather than
a rewiring.

WirePlumber already moves the default sink to a Bluetooth device when one
connects. What it cannot know is when the user wants to go back to the speaker
while headphones are still connected, which is the one case this module exists
for.
"""

from __future__ import annotations

import json
import logging
import subprocess

LOG = logging.getLogger(__name__)

PW_DUMP = "pw-dump"
WPCTL = "wpctl"
_COMMAND_TIMEOUT_S = 15

#: Node name of the WM8960 playback device as the ALSA monitor names it. The
#: substring is matched rather than the whole name so a kernel that renames the
#: card between releases does not silently break routing.
SPEAKER_NODE_HINT = "wm8960"
BLUETOOTH_NODE_HINT = "bluez_output"


def _run(argv: list[str]) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=_COMMAND_TIMEOUT_S, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        LOG.warning("%s failed: %s", argv[0], error)
        return 1, str(error)
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def nodes() -> list[dict]:
    """Every PipeWire node, reduced to the fields routing cares about."""
    code, output = _run([PW_DUMP])
    if code != 0:
        return []
    try:
        dump = json.loads(output)
    except ValueError:
        LOG.warning("could not read the PipeWire graph")
        return []
    found = []
    for entry in dump:
        if entry.get("type") != "PipeWire:Interface:Node":
            continue
        props = (entry.get("info") or {}).get("props") or {}
        found.append(
            {
                "id": entry.get("id"),
                "name": props.get("node.name", ""),
                "description": props.get("node.description", ""),
                "media_class": props.get("media.class", ""),
            }
        )
    return found


def find_sink(hint: str) -> dict | None:
    for node in nodes():
        if "Audio/Sink" not in node["media_class"]:
            continue
        if hint.lower() in node["name"].lower():
            return node
    return None


def set_default_sink(hint: str) -> bool:
    """Point playback at the first sink whose name contains ``hint``."""
    node = find_sink(hint)
    if node is None or node["id"] is None:
        LOG.warning("no playback device matching %r", hint)
        return False
    code, _ = _run([WPCTL, "set-default", str(node["id"])])
    return code == 0


def use_speaker() -> bool:
    return set_default_sink(SPEAKER_NODE_HINT)


def use_bluetooth() -> bool:
    return set_default_sink(BLUETOOTH_NODE_HINT)


def speaker_available() -> bool:
    return find_sink(SPEAKER_NODE_HINT) is not None


def bluetooth_available() -> bool:
    return find_sink(BLUETOOTH_NODE_HINT) is not None
