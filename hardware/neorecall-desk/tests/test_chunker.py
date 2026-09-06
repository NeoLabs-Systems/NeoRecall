"""The chunk timeline: overlap arithmetic, the tail, and a vanished far side."""

import numpy as np
import pytest

from neorecall_desk.audio import wav
from neorecall_desk.audio.chunker import Chunker, ReferenceBuffer, mix
from neorecall_desk.config import SAMPLE_RATE

BYTES_PER_MS = SAMPLE_RATE * 2 // 1000


def pcm(ms: int, value: int = 1000) -> bytes:
    return np.full(SAMPLE_RATE * ms // 1000, value, dtype=np.int16).tobytes()


def test_chunks_advance_by_target_minus_overlap():
    chunker = Chunker(target_ms=1000, overlap_ms=200)
    produced = chunker.feed(pcm(2600))

    assert [c.duration_ms for c in produced] == [1000, 1000, 1000]
    # First chunk has nothing before it to overlap with.
    assert [c.overlap_ms for c in produced] == [0, 200, 200]
    assert [c.monotonic_offset_ms for c in produced] == [0, 800, 1600]


def test_consecutive_chunks_share_exactly_the_declared_overlap():
    chunker = Chunker(target_ms=1000, overlap_ms=200)
    ramp = np.arange(SAMPLE_RATE * 3, dtype=np.int32).astype(np.int16).tobytes()
    first, second = chunker.feed(ramp)[:2]

    tail = wav.payload_of(first.payload)[-200 * BYTES_PER_MS :]
    head = wav.payload_of(second.payload)[: 200 * BYTES_PER_MS]
    assert tail == head


def test_final_chunk_keeps_a_tail_shorter_than_the_minimum():
    # The server allows a final chunk down to 1 ms, so the end of a recording is
    # uploaded rather than dropped for being short.
    chunker = Chunker(target_ms=1000, overlap_ms=200)
    chunker.feed(pcm(1000))
    chunker.feed(pcm(300))

    tail = chunker.finish()
    assert tail is not None
    assert tail.is_final
    assert tail.duration_ms == 500  # 200 ms retained overlap + 300 ms new
    assert len(wav.payload_of(tail.payload)) == 500 * BYTES_PER_MS


def test_finish_on_an_empty_stream_produces_nothing():
    assert Chunker(target_ms=1000, overlap_ms=200).finish() is None


def test_feeding_after_finish_is_refused():
    chunker = Chunker(target_ms=1000, overlap_ms=200)
    chunker.finish()
    with pytest.raises(RuntimeError):
        chunker.feed(pcm(10))


def test_overlap_must_be_shorter_than_the_chunk():
    with pytest.raises(ValueError):
        Chunker(target_ms=1000, overlap_ms=1000)


def test_payload_is_a_valid_wav_of_the_right_length():
    chunk = Chunker(target_ms=1000, overlap_ms=200).feed(pcm(1000))[0]
    assert chunk.payload[:4] == b"RIFF"
    assert chunk.payload[8:12] == b"WAVE"
    assert len(chunk.payload) == wav.HEADER_BYTES + 1000 * BYTES_PER_MS


def test_reference_buffer_pads_with_silence_when_the_laptop_is_quiet():
    buffer = ReferenceBuffer(capacity_ms=1000)
    buffer.push(np.full(100, 500, dtype=np.int16))

    taken, shortfall = buffer.take(160)
    assert shortfall == 60
    assert list(taken[:100]) == [500] * 100
    # The missing part is silence, never a repeat: repeating would put words into
    # the transcript that were never spoken.
    assert list(taken[100:]) == [0] * 60


def test_reference_buffer_drops_oldest_when_the_laptop_runs_ahead():
    buffer = ReferenceBuffer(sample_rate=1000, capacity_ms=10)  # 10 samples
    buffer.push(np.arange(1, 16, dtype=np.int16))

    assert buffer.buffered_samples == 10
    assert buffer.dropped_samples == 5
    taken, shortfall = buffer.take(10)
    assert shortfall == 0
    assert list(taken) == list(range(6, 16))


def test_mix_saturates_instead_of_wrapping():
    near = np.array([30000, -30000, 0], dtype=np.int16)
    far = np.array([30000, -30000, 5], dtype=np.int16)

    mixed = mix(near, far)
    assert list(mixed) == [32767, -32768, 5]
