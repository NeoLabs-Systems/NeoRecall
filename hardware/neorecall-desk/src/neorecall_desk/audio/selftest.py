"""Let the appliance check its own audio, so nobody has to be asked what they hear.

A device with no screen cannot ask "did that work?", and "does it sound right"
is not something a support conversation can settle. But this box has speakers
*and* microphones a few centimetres apart, so it can play a tone and listen for
it — an acoustic loopback that answers the question objectively and tests both
halves at once.

    neorecall-desk-selftest

Each check reports on its own. A device with working speakers and a dead
microphone is a different problem from one that is silent, and lumping them into
one verdict would hide exactly the distinction worth having.
"""

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import echo_cancel, relay

LOG = logging.getLogger(__name__)

PW_PLAY = "pw-play"
PW_RECORD = "pw-record"
MODINFO = "/usr/sbin/modinfo"

TONE_HZ = 1000.0
TONE_SECONDS = 2.0
TONE_AMPLITUDE = 0.5
SAMPLE_RATE = 48000

#: How far above the surrounding noise the tone has to stand before the speakers
#: count as working. Measured on this hardware with the input path configured, a
#: full-scale tone arrives around 49 dB above a quiet room — so six is a wide
#: margin below reality and still far above
#: than room noise drifts on its own, and far less than a real tone produces.
DETECTION_MARGIN_DB = 6.0


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    detail: str = ""


def _tone(path: Path) -> None:
    frames = []
    for index in range(int(SAMPLE_RATE * TONE_SECONDS)):
        value = int(TONE_AMPLITUDE * 32767 * np.sin(2 * np.pi * TONE_HZ * index / SAMPLE_RATE))
        frames.append(struct.pack("<hh", value, value))
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(b"".join(frames))


def tone_strength_db(
    samples: np.ndarray, *, sample_rate: int = SAMPLE_RATE, frequency: float = TONE_HZ
) -> float:
    """How far the tone stands above everything else in the recording.

    Deliberately a *relative* measurement. An absolute level would depend on
    speaker volume, microphone gain and how far apart they are — none of which
    this test can know, and all of which vary per unit.
    """
    if samples.size < sample_rate // 4:
        return float("-inf")
    windowed = samples.astype(np.float64) * np.hanning(samples.size)
    spectrum = np.abs(np.fft.rfft(windowed))
    freqs = np.fft.rfftfreq(samples.size, 1 / sample_rate)

    target = int(np.argmin(np.abs(freqs - frequency)))
    width = max(2, int(round(50 / (freqs[1] - freqs[0]))))
    band = slice(max(0, target - width), target + width + 1)

    peak = float(spectrum[band].max())
    elsewhere = np.delete(spectrum, np.s_[band])
    if elsewhere.size == 0 or peak <= 0:
        return float("-inf")

    # A high percentile, not the median. Against the median, a spectrum that is
    # mostly empty makes *any* bin look enormous — a 400 Hz hum in the room would
    # have passed as our 1 kHz tone. Measuring against the loudest thing that is
    # not the tone means a competing sound counts against the result, which is
    # what "did we hear our own tone" actually asks.
    floor = float(np.percentile(elsewhere, 99.0))
    if floor <= 0:
        return float("-inf")
    return 20.0 * float(np.log10(peak / floor))


def is_silent(samples: np.ndarray) -> bool:
    """A capture that never moves is a microphone that is not there."""
    return samples.size == 0 or int(np.abs(samples).max()) < 8


def _read_wav(path: Path) -> np.ndarray:
    try:
        with wave.open(str(path), "r") as handle:
            raw = handle.readframes(handle.getnframes())
            channels = handle.getnchannels()
    except (OSError, wave.Error):
        return np.zeros(0, dtype=np.int16)
    samples = np.frombuffer(raw, dtype=np.int16)
    if channels > 1:
        samples = samples[::channels]
    return samples


def _relay(action: str) -> None:
    subprocess.run(
        ["systemctl", "--user", action, "neorecall-desk-relay"],
        capture_output=True,
        check=False,
    )


def _play_and_record(speaker: str, microphone: str, workdir: Path) -> np.ndarray:  # noqa: ARG001
    tone = workdir / "tone.wav"
    recording = workdir / "heard.wav"
    _tone(tone)

    # The relay holds the speaker sink, and while it does, nothing else can play
    # to it: pw-play attaches and waits forever. Measured, not assumed — with the
    # relay running the tone never sounded and this check failed for reasons that
    # had nothing to do with the speakers. Stand it down for the few seconds the
    # test needs, and put it back afterwards.
    _relay("stop")
    time.sleep(1.5)
    try:
        return _tone_round_trip(tone, recording, microphone)
    finally:
        # Always, on every path. The relay owns the speakers and the microphone
        # nodes the recorder opens, so a check that raised between stopping it
        # and starting it again left the appliance silent — and left it that way
        # until somebody rebooted the box or restarted the unit by hand. A
        # diagnostic must not be able to break the thing it is diagnosing.
        _relay("start")


def _tone_round_trip(tone: Path, recording: Path, microphone: str) -> np.ndarray:
    recorder = subprocess.Popen(
        [
            PW_RECORD,
            "--target",
            microphone,
            "--rate",
            str(SAMPLE_RATE),
            "--channels",
            "2",
            "--format",
            "s16",
            str(recording),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    # Let the capture actually start before the tone does, or the beginning of
    # the tone is simply not in the recording.
    time.sleep(1.0)
    # pw-play can block well past the length of the file — a sink that is busy or
    # suspended keeps it waiting. Terminating it is fine: the tone has already
    # played by then, and a diagnostic that raises instead of reporting is worse
    # than no diagnostic at all.
    # No --target. Passing a node *name* here makes pw-play wait forever for a
    # target it never resolves — measured: it never returns for a two-second
    # file, so the tone never played and the speaker check failed for reasons
    # that had nothing to do with the speakers. Recording by name works; playing
    # by name does not. The default sink is the appliance's output anyway, and
    # when headphones are connected it is the output actually in use, which is
    # the one worth testing.
    player = subprocess.Popen(
        [PW_PLAY, str(tone)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        player.wait(timeout=TONE_SECONDS + 6)
    except subprocess.TimeoutExpired:
        LOG.debug("pw-play did not exit on its own; stopping it")
        player.terminate()
        try:
            player.wait(timeout=3)
        except subprocess.TimeoutExpired:
            player.kill()
    time.sleep(0.5)
    recorder.terminate()
    try:
        recorder.wait(timeout=5)
    except subprocess.TimeoutExpired:
        recorder.kill()
    return _read_wav(recording)


def codec_driver() -> Check:
    """Whether the codec has a driver that actually clocks it.

    The mainline `wm8960-soundcard` overlay enumerates the card and plays
    silence: `simple-audio-card` never configures the codec's PLL, so the DAC
    accepts samples and converts none of them. Nothing anywhere reports an
    error. This is the single check that would have saved the longest evening.
    """
    try:
        modules = pathlib.Path("/proc/modules").read_text()
    except OSError as error:
        return Check("codec driver", False, str(error))
    if "wm8960_soundcard" in modules:
        return Check("codec driver", True, "the WM8960 machine driver is loaded")
    return Check(
        "codec driver",
        False,
        "only the mainline overlay is in use, so the codec has no clock. The card "
        "will enumerate, accept audio and stay silent.",
    )


def usb_gadget() -> Check:
    """Whether the laptop sees a sound card with the configured function name."""
    root = pathlib.Path("/sys/kernel/config/usb_gadget/neorecall")
    if not root.is_dir():
        return Check("usb gadget", False, "the gadget has not been created")
    try:
        udc = (root / "UDC").read_text().strip()
    except OSError:
        udc = ""
    if not udc:
        return Check("usb gadget", False, "the gadget exists but is bound to no controller")

    function_name = root / "functions/uac2.usb0/function_name"
    try:
        configured_name = function_name.read_text().strip()
    except OSError as error:
        return Check(
            "usb gadget",
            False,
            f"bound to {udc}, but function_name cannot be read: {error}",
        )
    if configured_name != "NeoRecall Desk":
        return Check(
            "usb gadget",
            False,
            f"bound to {udc}, but function_name is {configured_name!r}",
        )
    return Check("usb gadget", True, f"bound to {udc} as {configured_name}")


def usb_audio_name_driver() -> Check:
    """Whether modprobe selects the persistent UAC2 naming override."""
    try:
        result = subprocess.run(
            [MODINFO, "-n", "usb_f_uac2"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as error:
        return Check("usb audio name", False, f"cannot resolve usb_f_uac2: {error}")

    module_path = result.stdout.strip()
    if "/updates/dkms/" not in module_path:
        return Check(
            "usb audio name",
            False,
            f"the stock module is selected at {module_path}; macOS may display inactive names",
        )
    return Check("usb audio name", True, f"DKMS override selected at {module_path}")


def audio_relay() -> Check:
    """Whether laptop audio is actually wired to the speakers and back."""
    try:
        nodes = relay._nodes()
        names = {node["name"] for node in nodes}
        # The same node the recorder will open for the computer's side, resolved
        # the same way. Checking a name nobody records from is how this check
        # once passed while half of every conversation was going missing.
        far = relay.find_endpoints(nodes)["from_computer"]
    except relay.RelayError as error:
        return Check("audio relay", False, str(error))
    # The last four are what the recorder itself opens. An earlier version of
    # this check listed only the relay's own nodes, so it went on reporting a
    # healthy relay while the two nodes pw-record aims at did not exist at all.
    wanted = {
        "neorecall.speakers.in",
        "neorecall.speakers.out",
        "neorecall.mic.in",
        "neorecall.mic.out",
        echo_cancel.NODE_RELAY_OUT,
        echo_cancel.NODE_NEAR,
        far,
    }
    missing = wanted - names
    if missing:
        return Check("audio relay", False, "missing relay nodes: " + ", ".join(sorted(missing)))
    return Check("audio relay", True, "laptop audio and the microphones are wired through")


def _safely(name: str, probe) -> Check:
    """Run one check. A check that raises reports a failure; it never aborts."""
    try:
        return probe()
    except Exception as error:  # noqa: BLE001 - a diagnostic must always answer
        LOG.debug("%s raised", name, exc_info=True)
        return Check(name, False, f"the check itself failed: {type(error).__name__}: {error}")


def run() -> list[Check]:
    checks: list[Check] = [
        _safely("codec driver", codec_driver),
        _safely("usb gadget", usb_gadget),
        _safely("usb audio name", usb_audio_name_driver),
        _safely("audio relay", audio_relay),
    ]

    for tool in (PW_PLAY, PW_RECORD):
        if shutil.which(tool) is None:
            checks.append(Check("audio tools", False, f"{tool} is not installed"))
            return checks

    try:
        endpoints = relay.find_endpoints(relay._nodes())
    except relay.RelayError as error:
        checks.append(Check("audio devices", False, str(error)))
        return checks

    checks.append(Check("audio devices", True, "the HAT and the USB gadget are both present"))

    try:
        with tempfile.TemporaryDirectory() as raw:
            heard = _play_and_record(endpoints["speaker"], endpoints["microphone"], Path(raw))
    except Exception as error:  # noqa: BLE001
        checks.append(Check("microphones", False, f"the loopback test could not run: {error}"))
        return checks

    if is_silent(heard):
        # One failure, two possible causes, and they are worth separating.
        checks.append(
            Check(
                "microphones",
                False,
                "the microphones recorded nothing at all — the capture path is dead",
            )
        )
        checks.append(
            Check(
                "speakers",
                False,
                "cannot tell: without a working microphone there is no way to listen",
            )
        )
        return checks

    checks.append(Check("microphones", True, "the microphones are picking up sound"))

    strength = tone_strength_db(heard)
    if strength >= DETECTION_MARGIN_DB:
        checks.append(
            Check(
                "speakers",
                True,
                f"the test tone came back {strength:.0f} dB above the noise",
            )
        )
    else:
        checks.append(
            Check(
                "speakers",
                False,
                f"the microphones heard the room but not the tone ({strength:.0f} dB). "
                "Either nothing is connected to the speaker terminals, or the output is muted",
            )
        )
    return checks


APPLIANCE_USER = "neorecall"


def session_problem(euid: int, appliance_uid: int | None) -> str | None:
    """Why this process cannot see the appliance's audio graph, if it cannot.

    PipeWire runs in the appliance account's own session. Asked from any other
    account it answers with an empty graph — and an empty graph looks exactly
    like broken hardware. This test reported four confident failures that way
    while the speakers were audibly working.
    """
    if appliance_uid is None or euid == appliance_uid:
        return None
    if euid != 0:
        return (
            f"Run this with sudo. The audio graph belongs to the {APPLIANCE_USER} "
            "account, and from anywhere else this test sees nothing and reports "
            "failures that are not real.\n\n    sudo neorecall-desk-selftest"
        )
    return ""  # root: re-exec rather than complain


def _appliance_uid() -> int | None:
    import pwd

    try:
        return pwd.getpwnam(APPLIANCE_USER).pw_uid
    except KeyError:
        return None


def _enter_appliance_session() -> None:
    uid = _appliance_uid()
    problem = session_problem(os.geteuid(), uid)
    if problem is None:
        return
    if problem:
        print(problem)
        raise SystemExit(2)
    os.execvp(
        "runuser",
        [
            "runuser",
            "-u",
            APPLIANCE_USER,
            "--",
            "env",
            f"XDG_RUNTIME_DIR=/run/user/{uid}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus",
            sys.executable,
            "-m",
            "neorecall_desk.audio.selftest",
            *sys.argv[1:],
        ],
    )


def main() -> int:
    _enter_appliance_session()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    logging.basicConfig(level=logging.WARNING)

    print("Playing a tone and listening for it. This takes a few seconds.\n")
    checks = run()
    for check in checks:
        print(f"  {'PASS' if check.ok else 'FAIL'}  {check.name:14} {check.detail}")
    failed = [check for check in checks if not check.ok]
    print()
    print("Everything works." if not failed else f"{len(failed)} of {len(checks)} checks failed.")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
