"""Echo cancellation, and the nodes the recorder actually records from.

The appliance plays the far side of a conversation out of its own speakers, a
few centimetres from its own microphones. Without cancellation the microphone
hears the other person twice — once through the room and once as an echo the
transcript attributes to whoever is sitting here. So the near side is captured
*after* a WebRTC canceller that uses the speaker feed as its reference.

This module also fixes something less obvious. ``streams.py`` has always read
from ``neorecall.capture.near`` and ``neorecall.capture.far``, and those names
were correct — but the drop-in configuration that created them was removed when
it turned out PipeWire was silently ignoring it. Nothing has created them since,
so ``pw-record`` was aiming at nodes that did not exist. The canceller creates
the near node, and the relay creates the far one, which is why they are built
together here rather than left to a configuration file nobody runs.

The graph this produces:

    laptop  ──▶ neorecall.relay.out ──▶ WM8960 speakers
                      │ (reference)
    WM8960 mic ──▶ [canceller] ──▶ neorecall.capture.near ──▶ recorder + laptop
    laptop  ──▶ neorecall.capture.far ────────────────────▶ recorder
"""

from __future__ import annotations

import pathlib
import shutil
import tempfile

PIPEWIRE = "pipewire"

#: The cleaned microphone. The recorder's clock and the signal the laptop hears.
NODE_NEAR = "neorecall.capture.near"

#: What the relay plays into. Feeding the speakers through the canceller's sink
#: instead of straight at the card is what gives it a reference signal at all.
NODE_RELAY_OUT = "neorecall.relay.out"

#: The library name is a path fragment under the SPA plugin directory, not a
#: file: PipeWire appends the platform's own suffix.
AEC_LIBRARY = "aec/libspa-aec-webrtc"

_CONFIG = """# Written by NeoRecall Desk. Edits are lost on the next update.
context.properties = {{
    log.level = 0
}}

context.spa-libs = {{
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}}

context.modules = [
    {{ name = libpipewire-module-rt
        args = {{ }}
        flags = [ ifexists nofail ]
    }}
    {{ name = libpipewire-module-protocol-native }}
    {{ name = libpipewire-module-client-node }}
    {{ name = libpipewire-module-adapter }}
    {{ name = libpipewire-module-echo-cancel
        args = {{
            library.name = {library}
            aec.args = {{
                # Every form of automatic gain is deliberately off. A recording
                # is not a phone call: gain that rides the level makes a quiet
                # speaker loud and a pause noisy, and a transcript reads the
                # result as confident speech that was never there. The capture
                # gain is set once, in the mixer, and left alone.
                webrtc.gain_control        = false
                webrtc.analog_gain_control = false
                webrtc.digital_gain_control = false

                # This codec drifts at DC — during bring-up its ADC recorded
                # almost nothing else — so the high-pass filter earns its place.
                webrtc.high_pass_filter    = true

                webrtc.noise_suppression   = true
                webrtc.extended_filter     = true

                # Voice detection only annotates the stream. The recorder decides
                # what silence means, and it does so with the whole chunk in hand.
                webrtc.voice_detection     = false
            }}
            capture.props = {{
                target.object    = "{microphone}"
                node.name        = "neorecall.aec.capture"
                node.passive     = false
            }}
            source.props = {{
                node.name        = "{near}"
                node.description = "NeoRecall Desk microphone"
                media.class      = "Audio/Source"
            }}
            playback.props = {{
                target.object    = "{speaker}"
                node.name        = "neorecall.aec.playback"
                node.passive     = false
{playback_tuning}            }}
            sink.props = {{
                node.name        = "{relay_out}"
                node.description = "NeoRecall Desk speakers"
                media.class      = "Audio/Sink"
            }}
        }}
    }}
]
"""


#: Applied to the canceller's playback stream when it ends at a Bluetooth sink.
#: Suspension there tears down the A2DP transport, and the default quantum
#: underruns on a board whose Wi-Fi and Bluetooth share one antenna. Both are
#: heard as the headphones cutting out shortly after they started working.
_BLUETOOTH_PLAYBACK_TUNING = """\
                node.latency     = "4096/48000"
                session.suspend-timeout-seconds = 0
"""


def config(*, microphone: str, speaker: str, bluetooth: bool = False) -> str:
    """The standalone PipeWire context that runs the canceller.

    It is a separate context, launched as its own process, for the same reason
    the relay is a process: a module that fails to load in somebody else's
    daemon is a log line nobody reads, while a process that exits is a service
    that failed.

    ``bluetooth`` says the speaker it plays into is a headset rather than the
    board's own codec, which needs a longer buffer and must never be parked.
    """
    return _CONFIG.format(
        library=AEC_LIBRARY,
        microphone=microphone,
        speaker=speaker,
        near=NODE_NEAR,
        relay_out=NODE_RELAY_OUT,
        playback_tuning=_BLUETOOTH_PLAYBACK_TUNING if bluetooth else "",
    )


def write_config(text: str, directory: str | None = None) -> pathlib.Path:
    """Put the context somewhere the canceller can read it back."""
    base = pathlib.Path(directory) if directory else pathlib.Path(tempfile.gettempdir())
    base.mkdir(parents=True, exist_ok=True)
    path = base / "neorecall-echo-cancel.conf"
    path.write_text(text, encoding="utf-8")
    return path


def command(config_path: pathlib.Path | str) -> list[str]:
    return [PIPEWIRE, "-c", str(config_path)]


def is_available(search_roots: tuple[str, ...] = ("/usr/lib", "/usr/local/lib")) -> bool:
    """Whether this PipeWire build actually has a WebRTC canceller.

    Checked rather than assumed: the module and the backend are separate
    packages, and a missing backend makes the module load and then cancel
    nothing at all — the failure mode that looks exactly like success.

    The first version of this dropped the ``aec/`` directory from the pattern
    and so reported "no canceller" on a machine that had one. It fell back
    silently, the appliance kept working, and nothing but a log line said the
    microphone was hearing the speakers. Hence the tests below it, which check
    that a canceller *present* is found — not only that an absent one is missed.
    """
    if shutil.which(PIPEWIRE) is None:
        return False
    for root in search_roots:
        for candidate in pathlib.Path(root).glob(f"*/spa-0.2/{AEC_LIBRARY}*"):
            if candidate.exists():
                return True
    return False
