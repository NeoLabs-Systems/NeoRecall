"""The audio relay, as a supervised process rather than a configuration file.

This started life as two `libpipewire-module-loopback` entries in a PipeWire
drop-in. On real hardware they silently did nothing: the files were in the right
place, the modules were installed, PipeWire logged no complaint, and no nodes
appeared. A configuration that is ignored looks exactly like one that works —
right up until nothing comes out of the speakers.

So the relay is a process now. If it cannot find the hardware it says so and
exits non-zero, `systemctl status` shows it failed, and the diagnostics report
carries the reason. That is worth more than the elegance of a config file.

It also discovers the real node names instead of assuming them, because the
WirePlumber rules that were supposed to rename them turned out not to apply
either — and the names PipeWire generates for an ALSA card are not something to
guess at.
"""

from __future__ import annotations

import json
import logging
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time

from . import echo_cancel

LOG = logging.getLogger(__name__)

PW_DUMP = "pw-dump"
PW_LOOPBACK = "pw-loopback"
WPCTL = "wpctl"
AMIXER = "amixer"
ALSACTL = "/usr/sbin/alsactl"

#: Substrings that identify the two cards. Matched against the node name and its
#: ALSA card name, so a kernel that renames a card between releases does not
#: silently break routing.
WM8960_HINTS = ("wm8960",)
GADGET_HINTS = ("uac2", "gadget")

#: Bluetooth headphones, when a pair is connected. Optional by nature.
BLUETOOTH_HINTS = ("bluez_output",)

# One second, because this loop is also the replug detector: somebody has just
# plugged a cable in and is waiting for sound. Five seconds of polling plus ten
# of restart delay reads as "it does not work", not as "it is starting".
RESTART_DELAY_S = 1.0

#: ALSA cards whose absence from the graph is worth trying to fix rather than
#: merely reporting.
ALSA_CARDS = "/proc/asound/cards"
ALSA_CARD_ROOT = "/proc/asound"

# The direction looks backwards because this is the gadget's ALSA view: audio
# played by the laptop is captured by Linux. The kernel publishes host speaker
# volume and mute under these controls but deliberately does not scale the PCM
# samples; this relay applies them to its own speaker stream instead.
HOST_PLAYBACK_VOLUME = "PCM Capture Volume"
HOST_PLAYBACK_SWITCH = "PCM Capture Switch"
SPEAKER_RELAY_OUT = "neorecall.speakers.out"

_INTEGER_RANGE = re.compile(r"type=INTEGER.*\bmin=(-?\d+),max=(-?\d+)")
_INTEGER_VALUE = re.compile(r"^\s*:\s*values=(-?\d+)", re.MULTILINE)
_SWITCH_VALUE = re.compile(r"^\s*:\s*values=(on|off)\s*$", re.MULTILINE)


class RelayError(RuntimeError):
    """The relay cannot be built, with a reason worth putting in a log."""


def _nodes() -> list[dict]:
    try:
        output = subprocess.run(
            [PW_DUMP], capture_output=True, text=True, timeout=20, check=True
        ).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise RelayError(f"could not read the PipeWire graph: {error}") from error
    try:
        dump = json.loads(output)
    except ValueError as error:
        raise RelayError("the PipeWire graph was unreadable") from error

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
                "card": props.get("alsa.card_name", "") or props.get("api.alsa.card.name", ""),
            }
        )
    return found


def _matches(node: dict, hints: tuple[str, ...]) -> bool:
    haystack = f"{node['name']} {node['description']} {node['card']}".lower()
    return any(hint in haystack for hint in hints)


def find_endpoints(nodes: list[dict]) -> dict[str, str]:
    """Work out which node is which.

    Four endpoints matter, and their roles are the opposite of what their names
    suggest on the gadget side: what the laptop *plays* arrives here as a capture
    device, and what we play to the gadget is what the laptop *records*.
    """

    def pick(hints: tuple[str, ...], media_class: str) -> str | None:
        for node in nodes:
            if media_class in node["media_class"] and _matches(node, hints):
                return node["name"]
        return None

    endpoints = {
        "speaker": pick(WM8960_HINTS, "Audio/Sink"),
        "headphones": pick(BLUETOOTH_HINTS, "Audio/Sink") or "",
        "microphone": pick(WM8960_HINTS, "Audio/Source"),
        "from_computer": pick(GADGET_HINTS, "Audio/Source"),
        "to_computer": pick(GADGET_HINTS, "Audio/Sink"),
    }
    # Headphones are optional. Everything else has to be there.
    missing = [name for name, value in endpoints.items() if not value and name != "headphones"]
    if not missing:
        return endpoints  # type: ignore[return-value]

    # Name the side that is actually absent. "The HAT or the gadget did not come
    # up" was true but useless: the two have completely different causes, and
    # saying both sends whoever reads it looking in the wrong place half the time.
    hat = {"speaker", "microphone"} & set(missing)
    gadget = {"from_computer", "to_computer"} & set(missing)
    if hat and not gadget:
        blame = (
            "The WM8960 HAT is not in the audio graph. Its driver is the usual "
            "cause — check that the card appears in /proc/asound/cards."
        )
    elif gadget and not hat:
        blame = (
            "The USB sound card the laptop sees is not in the audio graph. The "
            "gadget can be bound and visible to the laptop while PipeWire has "
            "not picked it up — restarting PipeWire after the gadget is built is "
            "what links the two."
        )
    else:
        blame = "Neither the WM8960 HAT nor the USB gadget is in the audio graph."
    raise RelayError("missing: " + ", ".join(sorted(missing)) + ". " + blame)


#: Never let a relay node suspend. PipeWire parks an idle node after a few
#: seconds, and on a Bluetooth sink parking it tears down the A2DP transport.
#: The next sample has to rebuild it, which is audible as a gap and, when the
#: headset does not come back cleanly, as silence — the appliance had been
#: playing a moment earlier, so nothing about it looks broken.
NEVER_SUSPEND = "session.suspend-timeout-seconds=0"

#: Buffer for a Bluetooth playback leg, in frames at 48 kHz — about 85 ms.
#: The wired path runs happily on PipeWire's default quantum; a Bluetooth sink
#: on a Pi Zero 2 W does not, because the same chip and the same antenna are
#: carrying Wi-Fi. Too small a buffer there is a stream that underruns on every
#: retransmission, which is heard as stutter rather than as a dropout.
BLUETOOTH_LATENCY_FRAMES = 4096
BLUETOOTH_LATENCY = f"node.latency={BLUETOOTH_LATENCY_FRAMES}/48000"


def loopback_command(
    *,
    capture: str,
    playback: str | None = None,
    name: str,
    publish_as_source: bool = False,
    bluetooth: bool = False,
) -> list[str]:
    """One leg of the relay.

    With ``publish_as_source`` the far end is not a device but a virtual source
    that other programs can record from. That is how the laptop's own audio
    becomes something ``pw-record`` can open: a sink would let us play it, and
    what the recorder needs is to listen to it.

    With ``bluetooth`` the playback leg is given a buffer sized for a radio link
    rather than a wire. See [BLUETOOTH_LATENCY_FRAMES].
    """
    if not name:
        # pw-loopback answers `node.name=` with a parse error and exit 255, and
        # systemd answers that by restarting the relay for ever. Refuse here,
        # where the caller is, rather than in a crash loop that also takes the
        # speakers and the microphones down.
        raise ValueError("a loopback needs a node name")

    if publish_as_source:
        playback_props = (
            f'node.name={name} media.class=Audio/Source/Virtual node.description="{name}"'
        )
    else:
        playback_props = f"node.name={name}.out"
    playback_props += f" {NEVER_SUSPEND}"
    if bluetooth:
        playback_props += f" {BLUETOOTH_LATENCY}"

    command = [PW_LOOPBACK, "--capture", capture]
    if playback is not None:
        command += ["--playback", playback]
    command += [
        "--capture-props",
        f"node.name={name}.in node.passive=false {NEVER_SUSPEND}",
        "--playback-props",
        playback_props,
    ]
    return command


#: Exit code for "the host replugged": distinct so the unit can restart fast.
REPLUG_EXIT = 75

#: Where the kernel reports what the USB cable is doing.
UDC_STATE_GLOB = "/sys/class/udc/*/state"


def _udc_state() -> str:
    import glob

    for path in glob.glob(UDC_STATE_GLOB):
        try:
            return pathlib.Path(path).read_text().strip()
        except OSError:
            continue
    return ""


def replug_happened(previous: str, current: str) -> bool:
    """Whether the host just (re)attached, judged from two UDC state readings.

    Found by measurement, not reasoning: after a cable replug the relay's
    long-open ALSA handle to the gadget stays "running" and delivers silence
    for ever. The Mac plays, the graph hums, and 117 000 captured frames come
    back RMS 0. Reopening everything is the only cure, so the moment to do it
    is the moment the state file returns to "configured" from anything else —
    which also covers the host waking from sleep.
    """
    return current == "configured" and previous not in ("", "configured")


def _card_exists_but_is_not_in_the_graph(message: str) -> bool:
    """Whether ALSA has a card that the PipeWire graph is missing.

    Only then is a restart the right answer. If the card is not in ALSA either,
    the driver is the problem and restarting anything just hides it.
    """
    try:
        cards = pathlib.Path(ALSA_CARDS).read_text().lower()
    except OSError:
        return False
    if ("from_computer" in message or "to_computer" in message) and "uac2" in cards:
        return True
    return ("speaker" in message or "microphone" in message) and "wm8960" in cards


def _restart_wireplumber() -> bool:
    result = subprocess.run(
        ["systemctl", "--user", "restart", "wireplumber"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        LOG.error("could not restart WirePlumber: %s", result.stderr.strip()[:200])
        return False
    return True


def _use_unity_gain(endpoints: dict[str, str]) -> None:
    """Pass audio through at the level it arrived — except where somebody listens.

    A fresh PipeWire node defaults to 40 % volume. On a box whose whole job is
    relaying, that is a hidden attenuation on every path: the laptop already
    controls its own volume, and the hardware mixer sets the rest. Stacking a
    third, invisible one only makes the appliance quieter than anything explains.

    The audible outputs are the exception, learned the loud way: forcing the
    speaker sink to 100 % on every relay start overrode whatever level — or
    mute — the owner had set, and a routine graph rebuild became a jump scare.
    Plumbing gets unity; ears get the configured volume.
    """
    audible = {"speaker", "headphones"}
    try:
        from ..config import ConfigStore

        listening_level = ConfigStore().get().volume
    except Exception:  # noqa: BLE001 - an unreadable preference must not stop audio
        listening_level = 0.7
    by_name = {node["name"]: node["id"] for node in _nodes()}
    for role, name in endpoints.items():
        node_id = by_name.get(name)
        if node_id is None:
            continue
        level = f"{listening_level:.2f}" if role in audible else "1.0"
        result = subprocess.run(
            ["wpctl", "set-volume", str(node_id), level],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            LOG.debug("could not set unity gain on %s (%s)", role, name)


def _gadget_alsa_card() -> str:
    """Return the ALSA card id for the USB gadget, independent of card number."""
    for path in sorted(pathlib.Path(ALSA_CARD_ROOT).glob("card[0-9]*/id")):
        try:
            card_id = path.read_text().strip()
        except OSError:
            continue
        lowered = card_id.lower()
        if any(hint in lowered for hint in GADGET_HINTS):
            return card_id
    raise RelayError("the UAC2 gadget has no ALSA control card")


def _read_mixer_control(card: str, name: str) -> str:
    try:
        return subprocess.run(
            [AMIXER, "-c", card, "cget", f"name={name}"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise RelayError(f"cannot read {name} on ALSA card {card}: {error}") from error


def host_playback_level(volume_control: str, switch_control: str) -> tuple[float, bool]:
    """Translate the host's UAC2 controls to PipeWire's normalized volume."""
    limits = _INTEGER_RANGE.search(volume_control)
    value = _INTEGER_VALUE.search(volume_control)
    switch = _SWITCH_VALUE.search(switch_control)
    if limits is None or value is None or switch is None:
        raise RelayError("the UAC2 playback volume controls are unreadable")

    minimum, maximum = (int(part) for part in limits.groups())
    if maximum <= minimum:
        raise RelayError(f"the UAC2 playback volume range {minimum}..{maximum} is invalid")
    current = min(max(int(value.group(1)), minimum), maximum)
    normalized = (current - minimum) / (maximum - minimum)
    return normalized, switch.group(1) == "off"


def _apply_host_playback_level(card: str, target_id: int) -> None:
    level, muted = host_playback_level(
        _read_mixer_control(card, HOST_PLAYBACK_VOLUME),
        _read_mixer_control(card, HOST_PLAYBACK_SWITCH),
    )
    for command in (
        [WPCTL, "set-volume", str(target_id), f"{level:.6f}"],
        [WPCTL, "set-mute", str(target_id), "1" if muted else "0"],
    ):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise RelayError(f"{' '.join(command)} failed: {error}") from error
        if result.returncode != 0:
            raise RelayError(result.stderr.strip() or f"{' '.join(command)} failed")
    LOG.info("host speaker volume is %.0f%%%s", level * 100, " (muted)" if muted else "")


def _resolve_node_id(name: str) -> int | None:
    node = next((node for node in _nodes() if node["name"] == name), None)
    return node["id"] if node else None


def _follow_host_playback_level(card: str, target_id: int, monitor: subprocess.Popen) -> None:
    """Apply the initial host volume and each subsequent ALSA control event.

    Volume is a convenience; audio is the product. This loop therefore treats
    its own failures as its own problem: a stale node id is re-resolved by name
    and the event retried, and an event that still fails is skipped with a log
    line. The first version raised instead — one stale id after a graph rebuild
    took the whole relay down, ten silent seconds, in the middle of a self-test.
    """

    def apply() -> None:
        nonlocal target_id
        try:
            _apply_host_playback_level(card, target_id)
        except RelayError:
            refreshed = _resolve_node_id(SPEAKER_RELAY_OUT)
            if refreshed is None:
                LOG.warning(
                    "skipping a host volume event: %s is not in the graph yet", SPEAKER_RELAY_OUT
                )
                return
            target_id = refreshed
            try:
                _apply_host_playback_level(card, target_id)
            except RelayError as error:
                LOG.warning("skipping a host volume event: %s", error)

    try:
        apply()
        if monitor.stdout is None:
            LOG.warning("the ALSA control monitor has no output; host volume stays fixed")
            return
        for _event in monitor.stdout:
            apply()
        LOG.info("the ALSA control monitor ended")
    except Exception:  # noqa: BLE001 - volume sync must never take the audio down
        LOG.exception("host volume synchronization stopped")


def _start_host_volume_monitor(processes: list) -> None:
    """Keep the speaker relay synchronized with the laptop's USB controls."""
    card = _gadget_alsa_card()
    if not _wait_for_nodes((SPEAKER_RELAY_OUT,), AEC_READY_TIMEOUT_S):
        raise RelayError(f"{SPEAKER_RELAY_OUT} did not appear for host volume control")
    target = next((node for node in _nodes() if node["name"] == SPEAKER_RELAY_OUT), None)
    if target is None or target["id"] is None:
        raise RelayError(f"{SPEAKER_RELAY_OUT} has no PipeWire node id")

    try:
        monitor = subprocess.Popen(
            [ALSACTL, "monitor", f"hw:{card}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except OSError as error:
        raise RelayError(f"cannot monitor host volume on ALSA card {card}: {error}") from error
    # Deliberately NOT in the supervised process list: the monitor's death
    # costs volume-key sync, not audio, and rebuilding the whole graph over it
    # is how a cosmetic failure became ten seconds of silence.
    threading.Thread(
        target=_follow_host_playback_level,
        args=(card, target["id"], monitor),
        name="host-volume",
        daemon=True,
    ).start()


#: How long the canceller may take to publish its nodes before we stop waiting.
AEC_READY_TIMEOUT_S = 15.0


def _wait_for_nodes(names: tuple[str, ...], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        present = {node["name"] for node in _nodes()}
        if set(names) <= present:
            return True
        time.sleep(0.5)
    return False


def _chosen_output(endpoints: dict[str, str]) -> str:
    """The sink the room should hear, honouring the owner's choice.

    Falls back to the built-in speakers whenever headphones are asked for but
    not there — silence would be the worse answer, and the app already shows
    which output is live.
    """
    from ..config import ConfigStore

    try:
        wanted = ConfigStore().get().output_target
    except Exception:  # noqa: BLE001 - an unreadable preference is not a reason to be silent
        LOG.warning("could not read the output preference; using the speakers", exc_info=True)
        return endpoints["speaker"]
    if wanted == "headphones" and endpoints.get("headphones"):
        return endpoints["headphones"]
    if wanted == "headphones":
        LOG.warning("headphones were chosen but none are connected; using the speakers")
    return endpoints["speaker"]


def _start_echo_canceller(
    endpoints: dict[str, str], processes: list, output: str
) -> tuple[str, str]:
    """Bring up cancellation, and say what the rest of the relay should use.

    Returns the node the near side is captured from and the node the laptop's
    audio should be played into. On a build without a WebRTC backend both fall
    back to the raw card — the appliance still records and still relays, it just
    records the echo too. Degrading loudly beats refusing to start.
    """
    to_bluetooth = bool(endpoints.get("headphones")) and output == endpoints["headphones"]
    if echo_cancel.is_available():
        path = echo_cancel.write_config(
            echo_cancel.config(
                microphone=endpoints["microphone"],
                speaker=output,
                # The canceller's playback stream is the one that actually
                # reaches the headset, so it is the one that has to be buffered
                # for a radio and kept from suspending.
                bluetooth=to_bluetooth,
            )
        )
        command = echo_cancel.command(path)
        LOG.info("starting %s", " ".join(command))
        processes.append(subprocess.Popen(command))
        ready = (echo_cancel.NODE_NEAR, echo_cancel.NODE_RELAY_OUT)
        if _wait_for_nodes(ready, AEC_READY_TIMEOUT_S):
            LOG.info("echo cancellation is active on %s", echo_cancel.NODE_NEAR)
            return echo_cancel.NODE_NEAR, echo_cancel.NODE_RELAY_OUT
        LOG.error(
            "the echo canceller did not publish its nodes within %.0fs; "
            "relaying without cancellation",
            AEC_READY_TIMEOUT_S,
        )
    else:
        LOG.error(
            "this PipeWire build has no WebRTC echo canceller; the microphone "
            "will hear the speakers"
        )

    # Whatever happened above, the recorder still opens NODE_NEAR by name, so
    # something has to publish it. A plain loopback does, uncancelled.
    fallback = loopback_command(
        capture=endpoints["microphone"],
        name=echo_cancel.NODE_NEAR,
        publish_as_source=True,
    )
    LOG.info("starting %s", " ".join(fallback))
    processes.append(subprocess.Popen(fallback))
    return echo_cancel.NODE_NEAR, output


def run() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s relay: %(message)s")
    for tool in (PW_DUMP, PW_LOOPBACK, WPCTL, AMIXER, ALSACTL):
        if shutil.which(tool) is None:
            LOG.error("%s is not installed; the relay cannot run", tool)
            return 1

    try:
        endpoints = find_endpoints(_nodes())
    except RelayError as error:
        if _card_exists_but_is_not_in_the_graph(str(error)):
            # A boot-order race, not a fault: the USB gadget is built as a system
            # service while PipeWire runs in a user session, and WirePlumber only
            # enumerates ALSA cards that exist when it starts. Restarting it is
            # what links the two, and doing that here means the box heals itself
            # instead of retrying against a graph that will never change.
            LOG.warning("%s", error)
            LOG.info("the card exists but WirePlumber has not picked it up; restarting it")
            if _restart_wireplumber():
                time.sleep(6)
                try:
                    endpoints = find_endpoints(_nodes())
                except RelayError as second:
                    LOG.error("%s", second)
                    return 1
            else:
                return 1
        else:
            LOG.error("%s", error)
            return 1

    _use_unity_gain(endpoints)

    # Where the room hears the far side. Changing the default sink is not enough:
    # the canceller plays at a *named* target, so a running relay keeps using the
    # speakers no matter what the default is. Selecting headphones in the app
    # therefore restarts this service, and the choice is read back here.
    output = _chosen_output(endpoints)

    LOG.info("laptop audio comes from %s", endpoints["from_computer"])
    LOG.info("it goes to           %s", output)
    LOG.info("the microphone is    %s", endpoints["microphone"])
    LOG.info("the laptop hears     %s", endpoints["to_computer"])

    processes: list = []
    try:
        near, speakers = _start_echo_canceller(endpoints, processes, output)

        headphones = endpoints.get("headphones") or None
        for label, capture, playback, as_source in (
            # Laptop audio goes through the canceller's sink, not straight at the
            # card. That detour is what gives cancellation a reference signal.
            ("neorecall.speakers", endpoints["from_computer"], speakers, False),
            # The laptop hears the room already cleaned up.
            ("neorecall.mic", near, endpoints["to_computer"], False),
            # No loopback for the computer's side: the recorder opens the
            # gadget's own capture node. The virtual source that used to sit
            # here was permanently suspended on real hardware and refused every
            # format, so recordings arrived with the microphone alone.
        ):
            command = loopback_command(
                capture=capture,
                playback=playback,
                name=label,
                publish_as_source=as_source,
                # Only the leg that actually ends at the headset gets the radio
                # buffer. Applying it to the wired legs would add latency the
                # wire does not need, and this same loop builds both.
                bluetooth=playback is not None and playback == headphones,
            )
            LOG.info("starting %s", " ".join(command))
            processes.append(subprocess.Popen(command))

        _start_host_volume_monitor(processes)

        # Supervise rather than exit: a loopback that dies takes half the relay
        # with it, and systemd only sees this process.
        udc_before = _udc_state()
        while True:
            for process in processes:
                if process.poll() is not None:
                    LOG.error(
                        "a relay process exited with %s; restarting the relay",
                        process.returncode,
                    )
                    return 1
            udc_now = _udc_state()
            if replug_happened(udc_before, udc_now):
                # The stale-handle bug: every open ALSA stream to the gadget is
                # now silence. Exit and let systemd rebuild the whole graph with
                # fresh handles — that is what makes plugging in just work.
                LOG.info("the computer (re)attached; rebuilding the audio graph")
                return REPLUG_EXIT
            udc_before = udc_now
            time.sleep(RESTART_DELAY_S)
    except KeyboardInterrupt:
        return 0
    finally:
        for process in processes:
            process.terminate()


def main() -> int:
    return run()


if __name__ == "__main__":
    sys.exit(main())
