"""Bluetooth headphones and headsets.

Two things happen here that look like one. Pairing and connecting are BlueZ's
job and go over D-Bus. Deciding whether a connected headset is used for playback
only (A2DP) or also for its microphone (HFP) is PipeWire's job and is a card
profile.

That second choice is not free, and the appliance refuses to hide it: switching
a headset into hands-free mode drops playback to narrowband, because that is what
the Bluetooth standard does, not because of anything this code could do better.
The default is therefore playback quality, with the headset microphone as an
explicit opt-in.
"""

from __future__ import annotations

import asyncio
import logging
import re
import subprocess
from dataclasses import dataclass
from typing import Any

from . import bluez

LOG = logging.getLogger(__name__)

PACTL = "pactl"
_COMMAND_TIMEOUT_S = 15

#: Card profile names as PipeWire's Bluetooth module exposes them.
PROFILE_PLAYBACK = "a2dp-sink"

#: Every hands-free profile PipeWire publishes starts with this. Matching the
#: prefix rather than a fixed list is deliberate: the exact names are a function
#: of the PipeWire version and the codecs the build was compiled with, and a
#: hard-coded pair of them is how real headsets ended up being told they had no
#: microphone. Measured on this appliance: a headset offering only
#: `headset-head-unit-cvsd` matched neither name in the old list, and the app
#: said "these headphones do not offer a microphone the appliance can use" about
#: a headset whose microphone works.
PROFILE_HEADSET_PREFIX = "headset-head-unit"

#: Known hands-free codecs, best first. Anything not listed still qualifies —
#: it simply sorts after the ones whose quality we know — so a future codec is
#: usable on the day PipeWire gains it rather than the day this tuple is edited.
HEADSET_CODEC_ORDER = ("lc3", "msbc", "cvsd")

#: Bluetooth class-of-device bits that mark a device as audio output. Used to
#: keep keyboards, phones and random beacons out of a list of headphones.
_AUDIO_MAJOR_CLASS = 0x04


@dataclass(frozen=True)
class Headphone:
    address: str
    name: str
    paired: bool = False
    connected: bool = False
    battery: int | None = None
    signal: int | None = None

    def as_entry(self) -> dict:
        entry = {
            "address": self.address,
            "name": self.name,
            "paired": self.paired,
            "connected": self.connected,
        }
        if self.battery is not None:
            entry["battery"] = self.battery
        if self.signal is not None:
            entry["signal"] = self.signal
        return entry


def _card_name(address: str) -> str:
    return "bluez_card." + address.replace(":", "_").upper()


def _run(argv: list[str]) -> tuple[int, str]:
    try:
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=_COMMAND_TIMEOUT_S, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        LOG.warning("%s failed: %s", argv[0], error)
        return 1, str(error)
    return completed.returncode, (completed.stdout or "") + (completed.stderr or "")


def available_profiles(address: str) -> dict[str, bool]:
    """Which profiles the card offers, and whether each is selectable now.

    Returns a mapping of profile name to availability. Availability is not a
    detail: `pactl` lists every profile the codec *could* do, and marks the ones
    the headset is not currently offering as `available: no`. Selecting one of
    those fails, so a profile list that ignores the flag is a list of choices
    that do not all work.
    """
    code, output = _run([PACTL, "list", "cards"])
    if code != 0:
        return {}
    card = _card_name(address)
    block = None
    for section in output.split("Card #"):
        if card in section:
            block = section
            break
    if block is None:
        return {}
    profiles: dict[str, bool] = {}
    in_profiles = False
    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("Profiles:"):
            in_profiles = True
            continue
        if not in_profiles:
            continue
        match = re.match(r"^([a-zA-Z0-9_+-]+):\s*(.*)$", stripped)
        if match:
            # "available: no" is the only form pactl uses for an unusable
            # profile; anything else (including no mention at all, on older
            # builds that omit the field) counts as usable.
            profiles[match.group(1)] = "available: no" not in match.group(2)
        elif stripped.startswith(("Active Profile:", "Ports:", "Properties:")):
            break
    return profiles


def _codec_rank(profile: str) -> tuple[int, str]:
    """Sort key for a hands-free profile: better codecs first."""
    suffix = profile[len(PROFILE_HEADSET_PREFIX) :].lstrip("-").lower()
    for rank, codec in enumerate(HEADSET_CODEC_ORDER):
        if suffix == codec:
            return rank, profile
    # An unrecognised codec sorts after every known one but ahead of the bare
    # legacy name, which PipeWire uses when it will not say what it negotiated.
    unknown = len(HEADSET_CODEC_ORDER)
    return (unknown, profile) if suffix else (unknown + 1, profile)


def headset_profiles(offered: dict[str, bool]) -> list[str]:
    """Every usable hands-free profile on a card, best first."""
    usable = [
        name
        for name, available in offered.items()
        if name.startswith(PROFILE_HEADSET_PREFIX) and available
    ]
    return sorted(usable, key=_codec_rank)


def set_profile(address: str, profile: str) -> bool:
    code, _ = _run([PACTL, "set-card-profile", _card_name(address), profile])
    return code == 0


def preferred_headset_profile(address: str) -> str | None:
    ranked = headset_profiles(available_profiles(address))
    return ranked[0] if ranked else None


class HeadphoneManager:
    """Pairs, connects and routes Bluetooth audio devices."""

    def __init__(
        self,
        runtime: bluez.BluezRuntime,
        *,
        adapter_path: str = bluez.DEFAULT_ADAPTER_PATH,
    ) -> None:
        self._runtime = runtime
        self._adapter_path = adapter_path

    # ---------------------------------------------------------------- discovery

    def scan(self, *, seconds: float = 8.0) -> list[Headphone]:
        """Look for headphones in range. Returns paired devices too, first."""
        try:
            return self._runtime.run(self._scan(seconds), timeout=seconds + 20)
        except bluez.BluetoothUnavailable:
            return []

    async def _scan(self, seconds: float) -> list[Headphone]:
        bus = self._runtime.bus
        adapter = await bluez.introspected(bus, self._adapter_path, bluez.ADAPTER_IFACE)
        if adapter is None:
            raise bluez.BluetoothUnavailable("no Bluetooth adapter")
        try:
            await adapter.call_set_discovery_filter({"Transport": _variant("s", "bredr")})
        except Exception:  # noqa: BLE001 - filtering is an optimisation, not a requirement
            LOG.debug("could not narrow the discovery filter", exc_info=True)
        try:
            await adapter.call_start_discovery()
        except Exception:  # noqa: BLE001 - already discovering is fine
            LOG.debug("discovery was already running", exc_info=True)
        await asyncio.sleep(seconds)
        try:
            await adapter.call_stop_discovery()
        except Exception:  # noqa: BLE001
            LOG.debug("could not stop discovery", exc_info=True)
        return await self._known(bus, include_unpaired=True)

    def known(self) -> list[Headphone]:
        try:
            return self._runtime.run(self._known_only())
        except bluez.BluetoothUnavailable:
            return []

    async def _known_only(self) -> list[Headphone]:
        return await self._known(self._runtime.bus, include_unpaired=False)

    async def _known(self, bus: Any, *, include_unpaired: bool) -> list[Headphone]:
        objects = await bluez.managed_objects(bus)
        found: list[Headphone] = []
        for path, interfaces in objects.items():
            device = interfaces.get(bluez.DEVICE_IFACE)
            if device is None or not path.startswith(self._adapter_path):
                continue
            paired = bool(device.get("Paired"))
            if not paired and not include_unpaired:
                continue
            # Every device is judged on what it is, paired or not. Skipping the
            # check for paired devices meant the phone that had just been used
            # to set the appliance up — paired by definition — was offered as a
            # pair of headphones, and the status said a headset was connected
            # when none was.
            if not _looks_like_audio(device):
                continue
            battery = interfaces.get(bluez.BATTERY_IFACE, {}).get("Percentage")
            found.append(
                Headphone(
                    address=str(device.get("Address", "")),
                    name=str(device.get("Alias") or device.get("Name") or "Headphones"),
                    paired=paired,
                    connected=bool(device.get("Connected")),
                    battery=int(battery) if isinstance(battery, int) else None,
                    signal=device.get("RSSI") if isinstance(device.get("RSSI"), int) else None,
                )
            )
        found.sort(key=lambda item: (not item.connected, not item.paired, -(item.signal or -120)))
        return found

    # --------------------------------------------------------------- connecting

    def connect(self, address: str) -> tuple[bool, str]:
        try:
            return self._runtime.run(self._connect(address), timeout=60)
        except bluez.BluetoothUnavailable:
            return False, "Bluetooth is not available on this device."
        except TimeoutError:
            return False, "Those headphones did not answer in time."

    async def _connect(self, address: str) -> tuple[bool, str]:
        bus = self._runtime.bus
        path = self._device_path(address)
        device = await bluez.introspected(bus, path, bluez.DEVICE_IFACE)
        if device is None:
            return False, "Those headphones are no longer in range."
        try:
            if not await device.get_paired():
                await device.call_pair()
            # Trusting the device is what lets it reconnect on its own after the
            # appliance reboots, which is the difference between "it just works"
            # and "open the app every morning".
            await device.set_trusted(True)
        except Exception:  # noqa: BLE001 - a device that is already paired is fine
            LOG.debug("pairing step reported an error", exc_info=True)
        try:
            await device.call_connect()
        except Exception as error:  # noqa: BLE001
            LOG.warning("could not connect %s: %s", address, error)
            return (
                False,
                "Those headphones would not connect. Try putting them back in pairing mode.",
            )
        return True, ""

    def disconnect(self, address: str) -> tuple[bool, str]:
        try:
            return self._runtime.run(self._simple(address, "call_disconnect"), timeout=30)
        except bluez.BluetoothUnavailable:
            return False, "Bluetooth is not available on this device."

    async def _simple(self, address: str, method: str) -> tuple[bool, str]:
        device = await bluez.introspected(
            self._runtime.bus, self._device_path(address), bluez.DEVICE_IFACE
        )
        if device is None:
            return True, ""
        try:
            await getattr(device, method)()
        except Exception:  # noqa: BLE001
            LOG.debug("%s failed for %s", method, address, exc_info=True)
            return False, "That did not work. Try again in a moment."
        return True, ""

    def forget(self, address: str) -> tuple[bool, str]:
        try:
            return self._runtime.run(self._forget(address), timeout=30)
        except bluez.BluetoothUnavailable:
            return False, "Bluetooth is not available on this device."

    async def _forget(self, address: str) -> tuple[bool, str]:
        bus = self._runtime.bus
        adapter = await bluez.introspected(bus, self._adapter_path, bluez.ADAPTER_IFACE)
        if adapter is None:
            return True, ""
        try:
            await adapter.call_remove_device(self._device_path(address))
        except Exception:  # noqa: BLE001 - forgetting something already gone is success
            LOG.debug("could not remove %s", address, exc_info=True)
        return True, ""

    def _device_path(self, address: str) -> str:
        return f"{self._adapter_path}/dev_" + address.replace(":", "_").upper()

    # ------------------------------------------------------------------ routing

    def use_headset_microphone(self, address: str, enabled: bool) -> tuple[bool, str]:
        """Switch the connected headset between playback-only and hands-free.

        Returns a message the app can show verbatim. The quality warning is part
        of the answer rather than a footnote, because the user is about to hear
        the difference.
        """
        if not enabled:
            if set_profile(address, PROFILE_PLAYBACK):
                return True, ""
            return False, "Could not switch those headphones back to full quality."

        offered = available_profiles(address)
        if not offered:
            # No card at all is a different problem from a card without a
            # hands-free profile, and saying "no microphone" for both sent
            # people looking at their headphones when the appliance had simply
            # not finished connecting them.
            return False, "Those headphones are not connected yet. Try again in a moment."

        candidates = headset_profiles(offered)
        if not candidates:
            # Some headsets only publish their hands-free profile as available
            # once something asks for it. Trying an unavailable one and letting
            # it fail is a better answer than refusing on the strength of a flag
            # that is only advisory.
            candidates = sorted(
                (name for name in offered if name.startswith(PROFILE_HEADSET_PREFIX)),
                key=_codec_rank,
            )
        if not candidates:
            return False, "These headphones do not offer a microphone the appliance can use."

        for profile in candidates:
            if set_profile(address, profile):
                return True, _headset_quality_note(profile)
        return False, "Could not switch those headphones to their microphone."


def _looks_like_audio(device: dict) -> bool:
    device_class = device.get("Class")
    if isinstance(device_class, int) and ((device_class >> 8) & 0x1F) == _AUDIO_MAJOR_CLASS:
        return True
    icon = device.get("Icon")
    return isinstance(icon, str) and icon in ("audio-headset", "audio-headphones", "audio-card")


def _variant(signature: str, value: Any) -> Any:
    from dbus_fast import Variant

    return Variant(signature, value)


def _headset_quality_note(profile: str) -> str:
    """What the owner is about to hear, named by the codec that decides it."""
    suffix = profile[len(PROFILE_HEADSET_PREFIX) :].lstrip("-").lower()
    if suffix == "lc3":
        return "Using the headset microphone. Sound quality is barely affected."
    if suffix == "msbc":
        return "Using the headset microphone. Sound quality drops a little while recording."
    return "Using the headset microphone. Sound quality drops while recording."
