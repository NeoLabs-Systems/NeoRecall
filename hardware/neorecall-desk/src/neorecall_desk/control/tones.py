"""Acoustic feedback.

The appliance has no display, so every confirmation is a sound. The vocabulary is
kept tiny and directional on purpose: rising means something started, falling
means it stopped, a repeating chirp means the appliance wants attention, and a
low buzz means it refused.
"""

from __future__ import annotations

import logging
import math
import struct
import subprocess
import tempfile
import threading
from pathlib import Path

LOG = logging.getLogger(__name__)

PW_PLAY = "pw-play"
TONE_SAMPLE_RATE = 24000
_FADE_MS = 8


def _render(steps: list[tuple[float, int]], *, amplitude: float = 0.28) -> bytes:
    """Render a sequence of (frequency, milliseconds) into 16-bit mono PCM."""
    samples: list[int] = []
    for frequency, duration_ms in steps:
        count = TONE_SAMPLE_RATE * duration_ms // 1000
        fade = max(1, TONE_SAMPLE_RATE * _FADE_MS // 1000)
        for index in range(count):
            # Fading each step in and out keeps the speaker from clicking, which
            # on a small enclosure is louder than the tone itself.
            envelope = min(1.0, index / fade, max(0.0, (count - index) / fade))
            value = math.sin(2 * math.pi * frequency * index / TONE_SAMPLE_RATE)
            samples.append(int(max(-1.0, min(1.0, value * envelope * amplitude)) * 32767))
    return struct.pack(f"<{len(samples)}h", *samples)


def _wav(pcm: bytes) -> bytes:
    from ..audio import wav

    return wav.wrap(pcm, sample_rate=TONE_SAMPLE_RATE, channels=1)


RECORDING_STARTED = [(660.0, 90), (880.0, 130)]
RECORDING_STOPPED = [(880.0, 90), (660.0, 130)]
SETUP_MODE = [(880.0, 80), (0.0, 60), (880.0, 80), (0.0, 60), (880.0, 80)]
REFUSED = [(220.0, 220)]
READY = [(523.0, 70), (784.0, 110)]
ATTENTION = [(740.0, 120), (0.0, 80), (740.0, 120)]


class Toneplayer:
    """Plays short confirmations without ever making the caller wait.

    Two hard-won constraints shape this. Playback to the speaker sink *blocks
    indefinitely* while the audio relay holds it — measured, not assumed — so a
    tone played synchronously would freeze whatever asked for it. And the thing
    that asks is usually the button handler, which must stay responsive: a box
    that stops reacting to its own button because a sound would not play is worse
    than a silent one.

    So a tone is fired into a background thread with a hard deadline. If it plays,
    good. If it cannot, it is dropped and logged, and nothing upstream notices.
    """

    def __init__(
        self,
        *,
        target: str | None = None,
        runner=subprocess.run,
        deadline_s: float = 6.0,
    ) -> None:
        self._target = target
        self._runner = runner
        self._deadline = deadline_s

    def play(self, steps: list[tuple[float, int]]) -> None:
        thread = threading.Thread(target=self._play_now, args=(steps,), daemon=True)
        thread.start()

    def play_and_wait(self, steps: list[tuple[float, int]]) -> None:
        """For tests and for the rare caller that genuinely needs the tone first."""
        self._play_now(steps)

    def _play_now(self, steps: list[tuple[float, int]]) -> None:
        path: Path | None = None
        try:
            payload = _wav(_render(steps))
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
                handle.write(payload)
                path = Path(handle.name)
        except OSError:
            LOG.debug("could not stage a tone", exc_info=True)
            return

        # No --target. Passing a node name to pw-play makes it wait for a target
        # it never resolves; the default sink is the appliance's own output.
        argv = [PW_PLAY, str(path)]
        try:
            self._runner(argv, capture_output=True, timeout=self._deadline, check=False)
        except (OSError, subprocess.TimeoutExpired):
            # A tone that will not play is not a reason for anything else to stop.
            LOG.debug("could not play a tone", exc_info=True)
        finally:
            path.unlink(missing_ok=True)
