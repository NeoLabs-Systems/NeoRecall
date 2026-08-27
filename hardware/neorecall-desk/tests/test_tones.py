"""Acoustic feedback that never holds anything up.

Two facts from real hardware shape this file. Playing to the speaker sink blocks
indefinitely while the audio relay holds it, and the caller is usually the button
handler — so a tone played synchronously would freeze the one control the device
has. A box that stops responding to its own button because a sound would not play
is worse than a silent box.
"""

import subprocess
import threading
import time

from neorecall_desk.control import tones


class SlowRunner:
    """Stands in for a pw-play that never returns, which is the real behaviour."""

    def __init__(self):
        self.started = threading.Event()
        self.release = threading.Event()
        self.calls = []

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        self.started.set()
        if not self.release.wait(kwargs.get("timeout", 5)):
            raise subprocess.TimeoutExpired(argv, kwargs.get("timeout", 5))
        return None


def test_a_tone_that_will_not_play_does_not_hold_up_the_caller():
    runner = SlowRunner()
    player = tones.Toneplayer(runner=runner, deadline_s=0.3)

    started = time.monotonic()
    player.play(tones.RECORDING_STARTED)
    elapsed = time.monotonic() - started

    # The button handler has to stay responsive; the tone is fire-and-forget.
    assert elapsed < 0.2
    assert runner.started.wait(2), "the tone should still have been attempted"


def test_a_blocked_tone_is_dropped_rather_than_raised():
    runner = SlowRunner()
    player = tones.Toneplayer(runner=runner, deadline_s=0.2)

    # Waiting deliberately: a timeout inside must not escape as an exception.
    player.play_and_wait(tones.REFUSED)


def test_a_tone_is_played_without_a_target():
    # Passing a node name to pw-play makes it wait for a target it never
    # resolves. The default sink is the appliance's own output.
    recorded = []
    player = tones.Toneplayer(runner=lambda argv, **k: recorded.append(argv))

    player.play_and_wait(tones.READY)

    assert recorded, "the tone should have been attempted"
    assert "--target" not in recorded[0]
    assert recorded[0][0] == tones.PW_PLAY


def test_the_temporary_file_is_removed_even_when_playback_fails():
    from pathlib import Path

    seen = []

    def runner(argv, **kwargs):
        seen.append(Path(argv[-1]))
        raise OSError("pw-play is not installed")

    tones.Toneplayer(runner=runner).play_and_wait(tones.ATTENTION)

    assert seen and not seen[0].exists()


def test_every_tone_renders_to_audible_audio():
    for name, steps in (
        ("started", tones.RECORDING_STARTED),
        ("stopped", tones.RECORDING_STOPPED),
        ("setup", tones.SETUP_MODE),
        ("refused", tones.REFUSED),
        ("ready", tones.READY),
        ("attention", tones.ATTENTION),
    ):
        pcm = tones._render(steps)
        assert pcm, f"{name} produced nothing"
        assert len(pcm) % 2 == 0, f"{name} is not whole 16-bit samples"


def test_rising_and_falling_tones_are_distinguishable():
    # Without a screen these two carry the whole meaning of "started" and
    # "stopped", so they must not be the same sound.
    assert tones.RECORDING_STARTED != tones.RECORDING_STOPPED
    assert tones.RECORDING_STARTED[0][0] < tones.RECORDING_STARTED[-1][0]
    assert tones.RECORDING_STOPPED[0][0] > tones.RECORDING_STOPPED[-1][0]
