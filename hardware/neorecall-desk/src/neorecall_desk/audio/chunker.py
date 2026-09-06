"""Mixing both conversation sides into one timeline, and cutting it into chunks.

Two signals arrive on two independent clocks: the microphone (always present,
free-running on the WM8960) and the audio the laptop is sending over USB (present
only while the laptop is actually playing something). Trying to treat them as
peers produces drift and stalls, so the microphone is the clock: every block of
microphone audio pulls an equally long block from the USB side, padding with
silence when the laptop is quiet or unplugged.

That padding is the deliberate answer to "what if the laptop side disappears":
the recording keeps its shape and its timeline, and the silence is truthful —
nothing was playing. A capture gap would be the wrong tool here, because the
mixed stream itself never stopped.

Everything in this module is pure: no PipeWire, no files, no clock. That is what
makes the overlap arithmetic and the crash behaviour testable on a workstation.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from ..config import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH_BYTES
from . import wav

# How much reference audio may queue up before the oldest is dropped. The USB
# side is only ever consumed at the microphone's rate, so a laptop that bursts
# ahead must not be allowed to grow this without bound.
DEFAULT_REFERENCE_BUFFER_MS = 2000


@dataclass(frozen=True)
class Chunk:
    """One independently decodable piece of the recording."""

    payload: bytes
    duration_ms: int
    overlap_ms: int
    monotonic_offset_ms: int
    is_final: bool


class ReferenceBuffer:
    """Bounded FIFO for the far-side (USB) audio."""

    def __init__(
        self, *, sample_rate: int = SAMPLE_RATE, capacity_ms: int = DEFAULT_REFERENCE_BUFFER_MS
    ) -> None:
        self._capacity = max(1, sample_rate * capacity_ms // 1000)
        self._data = np.zeros(0, dtype=np.int16)
        self.dropped_samples = 0

    def push(self, samples: np.ndarray) -> None:
        self._data = np.concatenate((self._data, samples.astype(np.int16, copy=False)))
        excess = self._data.size - self._capacity
        if excess > 0:
            self._data = self._data[excess:]
            self.dropped_samples += excess

    def take(self, count: int) -> tuple[np.ndarray, int]:
        """Return exactly ``count`` samples plus how many had to be invented.

        Missing samples are silence, never a repeat of earlier audio: a repeated
        block would put words into the transcript that were never spoken.
        """
        available = min(count, self._data.size)
        head = self._data[:available]
        self._data = self._data[available:]
        shortfall = count - available
        if shortfall:
            head = np.concatenate((head, np.zeros(shortfall, dtype=np.int16)))
        return head, shortfall

    @property
    def buffered_samples(self) -> int:
        return int(self._data.size)


def mix(
    near: np.ndarray, far: np.ndarray, *, near_gain: float = 1.0, far_gain: float = 1.0
) -> np.ndarray:
    """Sum two mono signals with saturation instead of wrap-around.

    Wrapping is what turns a loud moment into a burst of noise; saturating turns
    it into a slightly flattened peak that speech recognition still reads.
    """
    summed = near.astype(np.int32) * near_gain + far.astype(np.int32) * far_gain
    return np.clip(summed, -32768, 32767).astype(np.int16)


class Chunker:
    """Cuts a continuous mono stream into overlapping WAV chunks.

    The overlap arithmetic matches ``CapturePipeline`` in the Flutter client:
    each chunk covers ``target_ms``, consecutive chunks advance by
    ``target_ms - overlap_ms``, and the first chunk declares no overlap because
    there is nothing before it to overlap with.
    """

    def __init__(
        self,
        *,
        target_ms: int,
        overlap_ms: int,
        sample_rate: int = SAMPLE_RATE,
        channels: int = CHANNELS,
        on_chunk: Callable[[Chunk], None] | None = None,
    ) -> None:
        if overlap_ms >= target_ms:
            raise ValueError("overlap must be shorter than the chunk it overlaps")
        self._sample_rate = sample_rate
        self._channels = channels
        self._bytes_per_ms = sample_rate * channels * SAMPLE_WIDTH_BYTES // 1000
        self._target_bytes = self._bytes_per_ms * target_ms
        self._advance_bytes = self._bytes_per_ms * (target_ms - overlap_ms)
        self._target_ms = target_ms
        self._overlap_ms = overlap_ms
        self._advance_ms = target_ms - overlap_ms
        self._buffer = bytearray()
        self._emitted = 0
        self._on_chunk = on_chunk
        self._closed = False

    @property
    def emitted(self) -> int:
        return self._emitted

    @property
    def buffered_ms(self) -> int:
        return len(self._buffer) // self._bytes_per_ms if self._bytes_per_ms else 0

    def feed(self, pcm: bytes) -> list[Chunk]:
        if self._closed:
            raise RuntimeError("chunker already finished")
        self._buffer.extend(pcm)
        produced: list[Chunk] = []
        while len(self._buffer) >= self._target_bytes:
            body = bytes(self._buffer[: self._target_bytes])
            chunk = self._build(body, duration_ms=self._target_ms, is_final=False)
            del self._buffer[: self._advance_bytes]
            produced.append(chunk)
        return produced

    def finish(self) -> Chunk | None:
        """Emit whatever is left as the final chunk.

        The server accepts a final chunk down to one millisecond
        (``server/services/ingest/ingest_service.js``), so the tail of a
        recording is uploaded rather than discarded for being short.
        """
        if self._closed:
            return None
        self._closed = True
        if not self._buffer:
            return None
        body = bytes(self._buffer)
        duration_ms = max(1, len(body) // self._bytes_per_ms)
        self._buffer.clear()
        return self._build(body, duration_ms=duration_ms, is_final=True)

    def _build(self, body: bytes, *, duration_ms: int, is_final: bool) -> Chunk:
        chunk = Chunk(
            payload=wav.wrap(body, sample_rate=self._sample_rate, channels=self._channels),
            duration_ms=duration_ms,
            overlap_ms=0 if self._emitted == 0 else self._overlap_ms,
            monotonic_offset_ms=self._emitted * self._advance_ms,
            is_final=is_final,
        )
        self._emitted += 1
        if self._on_chunk is not None:
            self._on_chunk(chunk)
        return chunk
