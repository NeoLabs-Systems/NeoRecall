"""What the recorder does when the room, the laptop, or the microphone misbehave."""

from datetime import UTC, datetime

import numpy as np

from neorecall_desk import ledger as L
from neorecall_desk.audio import wav
from neorecall_desk.config import SAMPLE_RATE, ConfigStore, ServerLimits
from neorecall_desk.recorder import MAX_MIC_OUTAGE_MS, Recorder

BLOCK_MS = 100
BLOCK_BYTES = SAMPLE_RATE * 2 * BLOCK_MS // 1000


class FakeStream:
    """A stream a test can silence, kill, or resurrect.

    ``start`` deliberately does *not* resurrect a dead stream — a restart attempt
    against genuinely broken hardware fails, and the recorder has to cope with
    that rather than with a fake that heals itself on the first try.
    """

    def __init__(self, value=1000, alive=True):
        self.value = value
        self._alive = alive
        self._dead = not alive
        self.started = 0
        self.stopped = 0
        self.pending = b""

    def start(self):
        self.started += 1
        if not self._dead:
            self._alive = True

    def stop(self):
        self.stopped += 1
        self._alive = False

    def die(self):
        self._alive = False
        self._dead = True

    def heal(self):
        self._dead = False
        self._alive = True

    @property
    def alive(self):
        return self._alive

    def read(self, size):
        if not self._alive:
            return None
        return np.full(size // 2, self.value, dtype=np.int16).tobytes()

    def read_available(self, limit):
        piece, self.pending = self.pending[:limit], self.pending[limit:]
        return piece


def build(ledger, state_dir, *, far=None, target_ms=1000, overlap_ms=200):
    store = ConfigStore()
    store.set_limits(ServerLimits(chunk_target_ms=target_ms, chunk_overlap_ms=overlap_ms))
    near = FakeStream()
    recorder = Recorder(
        ledger=ledger,
        config_store=store,
        near=near,
        far=far,
        block_ms=BLOCK_MS,
        timezone="Europe/Berlin",
        now=lambda: datetime(2026, 8, 26, 9, 0, tzinfo=UTC),
    )
    return recorder, near


def test_a_recording_opens_a_session_and_starts_its_inputs(ledger, state_dir):
    far = FakeStream()
    recorder, near = build(ledger, state_dir, far=far)

    recorder.open()

    assert ledger.active_session() is not None
    assert near.started == 1
    assert far.started == 1


def test_chunks_land_in_the_ledger_in_sequence(ledger, state_dir):
    recorder, _ = build(ledger, state_dir, target_ms=1000, overlap_ms=200)
    recorder.open()

    for _ in range(20):  # 2000 ms at 100 ms per tick
        assert recorder.tick()

    session = ledger.active_session()
    stored = ledger.uploadable(limit=100)
    assert [row.sequence for row in stored] == [0, 1]
    assert all(row.session_id == session.id for row in stored)
    assert [row.overlap_ms for row in stored] == [0, 200]


def test_stopping_flushes_the_tail_and_closes_the_session(ledger, state_dir):
    recorder, near = build(ledger, state_dir, target_ms=1000, overlap_ms=200)
    recorder.open()
    session_id = recorder.session_id
    for _ in range(13):  # 1300 ms: one full chunk plus a short tail
        recorder.tick()

    recorder.close()

    stored = ledger.uploadable(limit=100)
    assert [row.sequence for row in stored] == [0, 1]
    assert stored[1].is_final
    assert stored[1].duration_ms == 500  # retained overlap plus the new audio
    closed = ledger.session(session_id)
    assert closed.status == L.SESSION_ENDED
    assert closed.final_sequence == 1
    assert near.stopped == 1


def test_a_quiet_laptop_does_not_stall_the_recording(ledger, state_dir):
    # The far side delivers nothing at all; the microphone still drives the clock.
    far = FakeStream()
    recorder, _ = build(ledger, state_dir, far=far, target_ms=1000, overlap_ms=200)
    recorder.open()

    for _ in range(11):
        assert recorder.tick()

    stored = ledger.uploadable(limit=100)
    assert len(stored) == 1
    body = wav.payload_of(stored[0].path.read_bytes())
    assert set(np.frombuffer(body, dtype=np.int16).tolist()) == {1000}


def test_laptop_audio_is_mixed_into_the_same_track(ledger, state_dir):
    far = FakeStream()
    far.pending = np.full(SAMPLE_RATE, 500, dtype=np.int16).tobytes()  # 1 s of far side
    recorder, _ = build(ledger, state_dir, far=far, target_ms=1000, overlap_ms=200)
    recorder.open()

    for _ in range(11):
        recorder.tick()

    body = wav.payload_of(ledger.uploadable(limit=100)[0].path.read_bytes())
    samples = np.frombuffer(body, dtype=np.int16)
    assert samples[0] == 1500, "near and far should be summed into one track"


def test_a_microphone_outage_is_padded_and_declared(ledger, state_dir):
    recorder, near = build(ledger, state_dir, target_ms=1000, overlap_ms=200)
    recorder.open()
    session_id = recorder.session_id

    for _ in range(5):
        recorder.tick()
    near.die()
    for _ in range(3):  # 300 ms with no microphone
        assert recorder.tick()
    near.heal()
    for _ in range(5):
        assert recorder.tick()

    gaps = ledger.undeclared_gaps(session_id)
    assert len(gaps) == 1
    assert (gaps[0].start_offset_ms, gaps[0].end_offset_ms) == (500, 800)
    assert gaps[0].reason == L.GAP_CAPTURE_ERROR
    # No sequence coverage: those sequences carry the padded silence and really
    # are uploaded, so claiming they are missing would contradict them.
    assert gaps[0].start_sequence is None
    assert gaps[0].end_sequence is None


def test_padding_keeps_later_offsets_true_to_wall_clock(ledger, state_dir):
    recorder, near = build(ledger, state_dir, target_ms=1000, overlap_ms=200)
    recorder.open()
    near.die()
    for _ in range(5):  # 500 ms of outage right at the start
        recorder.tick()
    near.heal()
    for _ in range(13):
        recorder.tick()

    stored = ledger.uploadable(limit=100)
    # 1800 ms of elapsed time produced two chunks advancing by 800 ms each. The
    # outage was padded, so the second chunk still sits where wall-clock time
    # says it should rather than 500 ms earlier.
    assert [row.monotonic_offset_ms for row in stored] == [0, 800]
    assert ledger.undeclared_gaps(recorder.session_id)[0].end_offset_ms == 500


def test_a_microphone_that_never_returns_ends_the_recording(ledger, state_dir):
    recorder, near = build(ledger, state_dir)
    recorder.open()
    near.die()

    ticks = 0
    while recorder.tick():
        ticks += 1
        assert ticks < (MAX_MIC_OUTAGE_MS // BLOCK_MS) + 5

    assert recorder.fault == "The microphone stopped responding."
    gaps = ledger.undeclared_gaps(recorder.session_id)
    assert gaps and gaps[0].reason == L.GAP_CAPTURE_ERROR


def test_the_recorder_tries_to_bring_the_microphone_back(ledger, state_dir):
    recorder, near = build(ledger, state_dir)
    recorder.open()
    before = near.started
    near.die()

    for _ in range(20):  # 2 s of outage
        recorder.tick()

    assert near.started > before, "an outage should be met with restart attempts"


def test_a_recording_that_produced_nothing_still_closes_cleanly(ledger, state_dir):
    recorder, _ = build(ledger, state_dir)
    recorder.open()
    session_id = recorder.session_id

    recorder.close()

    closed = ledger.session(session_id)
    assert closed.status == L.SESSION_ENDED
    assert closed.final_sequence == -1, "a final sequence of -1 says 'this stream is empty'"


def test_closing_from_two_threads_closes_once_and_crashes_neither(ledger, state_dir):
    """Found by running the recorder on the appliance.

    ``run`` closes on its way out, and ``close`` is public, so a caller that
    stops a recording and then closes it can arrive at the same moment. Both
    used to pass the "already closed?" check, and the loser then dereferenced a
    session the winner had already cleared.

    The interleaving is forced rather than hoped for: two threads racing on
    their own pass this test every time even with the bug present, which makes
    that version of it worse than no test at all.
    """
    import threading

    recorder, _ = build(ledger, state_dir)
    recorder.open()

    first_is_inside = threading.Event()
    second_is_inside = threading.Event()
    first_is_done = threading.Event()
    calls: list[int] = []
    real_finish = recorder._chunker.finish

    def finish_but_wait_for_the_other_thread():
        calls.append(1)
        if len(calls) == 1:
            first_is_inside.set()
            # Park inside close(), past the "already closed?" check.
            second_is_inside.wait(timeout=2)
        else:
            second_is_inside.set()
            first_is_done.wait(timeout=2)
        return real_finish()

    recorder._chunker.finish = finish_but_wait_for_the_other_thread

    errors: list[BaseException] = []

    def close_it():
        try:
            recorder.close()
        except BaseException as error:  # noqa: BLE001
            errors.append(error)

    first = threading.Thread(target=close_it)
    first.start()
    assert first_is_inside.wait(timeout=5)

    second = threading.Thread(target=close_it)
    second.start()
    first.join(timeout=10)
    first_is_done.set()
    second.join(timeout=10)

    assert errors == []
    assert recorder.session_id is None
    # The second caller must have been kept out entirely, not merely survived.
    assert len(calls) == 1
