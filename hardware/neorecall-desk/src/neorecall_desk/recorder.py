"""Turning two live streams into durable chunks.

The microphone is the clock. Every tick reads one block from it, pulls an equally
long block from whatever the laptop has sent, mixes the two, and hands the result
to the chunker. The ledger is written before anything is acknowledged, so the
worst a crash can cost is the block currently in flight.

When the microphone itself fails, the recorder keeps the timeline honest by
padding the outage with silence *and* declaring a capture gap over those
milliseconds. Padding alone would claim the room went quiet; a gap alone would
make every later chunk's offset drift away from wall-clock time. Doing both says
exactly what happened: this much time passed, and we could not hear it.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from datetime import UTC, datetime

import numpy as np

from .audio.chunker import Chunker, ReferenceBuffer, mix
from .audio.streams import AudioStream
from .config import CHANNELS, SAMPLE_RATE, SAMPLE_WIDTH_BYTES, ConfigStore
from .ledger import (
    GAP_CAPTURE_ERROR,
    SESSION_ENDED,
    Ledger,
    iso,
)

LOG = logging.getLogger(__name__)

#: How much audio one tick moves. Small enough that a crash costs little, large
#: enough that the loop is not the thing burning the battery.
BLOCK_MS = 100

#: How long the microphone may be missing before the recording is abandoned.
#: Below this the outage is padded and declared; beyond it, something is wrong
#: that recording through will not fix.
MAX_MIC_OUTAGE_MS = 60_000

#: How long to wait between attempts to bring the microphone back.
MIC_RESTART_INTERVAL_MS = 500


class Recorder:
    """One recording: opens a session, emits chunks, closes the session."""

    def __init__(
        self,
        *,
        ledger: Ledger,
        config_store: ConfigStore,
        near: AudioStream,
        far: AudioStream | None,
        block_ms: int = BLOCK_MS,
        timezone: str = "UTC",
        on_chunk_stored: Callable[[], None] | None = None,
        on_fault: Callable[[str], None] | None = None,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._ledger = ledger
        self._config = config_store
        self._near = near
        self._far = far
        self._timezone = timezone
        self._on_chunk_stored = on_chunk_stored
        self._on_fault = on_fault
        self._now = now

        self._bytes_per_ms = SAMPLE_RATE * CHANNELS * SAMPLE_WIDTH_BYTES // 1000
        self._block_bytes = self._bytes_per_ms * block_ms
        self._block_ms = block_ms
        self._reference = ReferenceBuffer()

        limits = config_store.get().limits
        self._chunker = Chunker(
            target_ms=limits.chunk_target_ms,
            overlap_ms=limits.chunk_overlap_ms,
        )

        self._session = None
        self._sequence = 0
        self._elapsed_ms = 0
        self._outage_started_ms: int | None = None
        self._outage_total_ms = 0
        self._stop = threading.Event()
        self._close_lock = threading.Lock()
        self._fault: str | None = None

    # ---------------------------------------------------------------- lifecycle

    @property
    def elapsed_ms(self) -> int:
        return self._elapsed_ms

    @property
    def session_id(self) -> str | None:
        return self._session.id if self._session else None

    @property
    def fault(self) -> str | None:
        return self._fault

    def open(self) -> None:
        self._session = self._ledger.open_session(
            device_started_at=iso(self._now()), timezone=self._timezone
        )
        self._near.start()
        if self._far is not None:
            self._far.start()

    def close(self, *, status: str = SESSION_ENDED) -> None:
        """Flush the tail, then close the session with a truthful final sequence.

        Holds a lock because this is public and ``run`` also calls it on the way
        out. Two callers used to be able to pass the None check together and
        then race, and the loser died on a session the winner had already
        cleared — a crash instead of a closed recording.
        """
        with self._close_lock:
            if self._session is None:
                return
            tail = self._chunker.finish()
            if tail is not None:
                self._store(tail)
            self._near.stop()
            if self._far is not None:
                self._far.stop()
            self._ledger.close_session(
                self._session.id,
                ended_at=iso(self._now()),
                status=status,
                final_sequence=self._sequence - 1,
            )
            self._session = None

    def request_stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        self.open()
        try:
            while not self._stop.is_set():
                if not self.tick():
                    break
        finally:
            self.close()

    # --------------------------------------------------------------------- tick

    def tick(self) -> bool:
        """Move one block. Returns False when the recording cannot continue."""
        near = self._near.read(self._block_bytes) if self._near.alive else None

        if near is None:
            if not self._handle_mic_outage():
                return False
            near = b"\x00" * self._block_bytes
        else:
            self._end_mic_outage()

        if self._far is not None:
            far_bytes = self._far.read_available(self._block_bytes * 4)
            if far_bytes:
                usable = len(far_bytes) - (len(far_bytes) % SAMPLE_WIDTH_BYTES)
                if usable:
                    self._reference.push(np.frombuffer(far_bytes[:usable], dtype=np.int16))

        near_samples = np.frombuffer(near, dtype=np.int16)
        far_samples, _ = self._reference.take(near_samples.size)
        mixed = mix(near_samples, far_samples)

        for chunk in self._chunker.feed(mixed.tobytes()):
            self._store(chunk)

        self._elapsed_ms += self._block_ms
        return True

    # ------------------------------------------------------------------ faults

    def _handle_mic_outage(self) -> bool:
        if self._outage_started_ms is None:
            self._outage_started_ms = self._elapsed_ms
            LOG.warning("microphone stream stopped delivering audio")
            if self._on_fault is not None:
                self._on_fault("The microphone stopped responding.")

        outage_ms = self._elapsed_ms - self._outage_started_ms
        if outage_ms >= MAX_MIC_OUTAGE_MS:
            self._fault = "The microphone stopped responding."
            self._declare_outage_gap()
            return False

        if outage_ms % MIC_RESTART_INTERVAL_MS < self._block_ms:
            try:
                self._near.start()
            except OSError:
                LOG.debug("microphone restart attempt failed", exc_info=True)
        return True

    def _end_mic_outage(self) -> None:
        if self._outage_started_ms is None:
            return
        self._declare_outage_gap()

    def _declare_outage_gap(self) -> None:
        if self._outage_started_ms is None or self._session is None:
            self._outage_started_ms = None
            return
        start = self._outage_started_ms
        end = self._elapsed_ms
        self._outage_started_ms = None
        if end <= start:
            return
        self._outage_total_ms += end - start
        # Offsets only, no sequence coverage: those sequences *were* produced —
        # they carry the padded silence — so claiming they are missing would
        # contradict the chunks the server is about to receive.
        self._ledger.record_gap(
            session_id=self._session.id,
            reason=GAP_CAPTURE_ERROR,
            start_offset_ms=start,
            end_offset_ms=end,
        )

    # ------------------------------------------------------------------ storage

    def _store(self, chunk) -> None:
        if self._session is None:
            return
        self._ledger.append_chunk(
            session_id=self._session.id,
            sequence=self._sequence,
            payload=chunk.payload,
            duration_ms=chunk.duration_ms,
            overlap_ms=chunk.overlap_ms,
            monotonic_offset_ms=chunk.monotonic_offset_ms,
            is_final=chunk.is_final,
        )
        self._sequence += 1
        if self._on_chunk_stored is not None:
            self._on_chunk_stored()
