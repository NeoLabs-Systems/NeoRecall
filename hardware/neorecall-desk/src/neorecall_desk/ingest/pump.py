"""The upload pump.

One cycle walks the whole ledger from declaration to release. It is written as a
single synchronous pass (``run_once``) with the clock and the sleep injected, so
the interesting behaviour — a server that is down for a day, a receipt that never
turns terminal, a process killed mid-PUT — is testable without a network or a
wall clock.

The rule the whole file exists to serve: audio leaves this machine only after it
has been re-read and re-hashed, and it is deleted only after a receipt proves the
transcript is stored and the server's own copy is gone.
"""

from __future__ import annotations

import logging
import random
import threading
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from ..config import ConfigStore
from ..ledger import (
    SESSION_ACTIVE,
    STATE_FAILED,
    STATE_NEEDS_ATTENTION,
    STATE_READY,
    STATE_TERMINAL,
    STATE_UPLOADED,
    STATE_UPLOADING,
    ChunkRow,
    Ledger,
    iso,
    proves_safe_audio_release,
    utc_now_iso,
)
from .client import IngestClient, IngestError, TransportError

LOG = logging.getLogger(__name__)

# Cadence. The pump idles cheaply and only tightens up while a backlog is
# actually shrinking, which is what keeps an appliance that has nothing to do
# from waking the radio every second.
IDLE_INTERVAL_S = 30.0
DRAIN_INTERVAL_S = 1.0

# Per-chunk retry backoff.
BACKOFF_BASE_S = 2.0
BACKOFF_MAX_S = 300.0
BACKOFF_JITTER = 0.25

# How many times a server may ask for the same chunk again before it is parked
# for a human rather than retried forever. Matches the Flutter client.
MAX_REUPLOAD_ATTEMPTS = 3

HEARTBEAT_INTERVAL_S = 300.0
UPLOAD_BATCH = 8
RECEIPT_BATCH = 500


@dataclass
class PumpStatus:
    """What the control plane reports to the app. Plain facts, no jargon."""

    pending_chunks: int = 0
    needs_attention: int = 0
    uploading: bool = False
    last_success_at: str | None = None
    last_error: str | None = None
    authentication_failed: bool = False
    device_revoked: bool = False
    progressed: bool = field(default=False, repr=False)


class UploadPump:
    def __init__(
        self,
        *,
        ledger: Ledger,
        config_store: ConfigStore,
        client_factory=IngestClient,
        firmware: str = "0.0.0",
        now=lambda: datetime.now(UTC),
    ) -> None:
        self._ledger = ledger
        self._config = config_store
        self._client_factory = client_factory
        self._firmware = firmware
        self._now = now
        self._status = PumpStatus()
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._last_heartbeat: datetime | None = None
        self._limits_read = False
        self._paused = False

    # ------------------------------------------------------------------ status

    @property
    def status(self) -> PumpStatus:
        with self._lock:
            return PumpStatus(**vars(self._status))

    def _note(self, **changes) -> None:
        with self._lock:
            for key, value in changes.items():
                setattr(self._status, key, value)

    # -------------------------------------------------------------------- loop

    def wake(self) -> None:
        """Ask for a cycle now — used when a recording has just finished."""
        self._wake.set()

    def set_paused(self, paused: bool) -> None:
        """Hold the pump while the Wi-Fi radio is deliberately down.

        During a recording the radio is off so Bluetooth audio has the antenna to
        itself. Letting the pump keep trying would only produce a stream of
        transport failures and a growing backoff on chunks that are perfectly
        fine.
        """
        self._paused = paused
        if not paused:
            self._wake.set()

    @property
    def paused(self) -> bool:
        return self._paused

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()

    def run_forever(self) -> None:
        while not self._stop.is_set():
            try:
                status = self.run_once()
            except Exception:  # noqa: BLE001 - the pump must outlive any single cycle
                LOG.exception("upload cycle failed")
                status = self.status
            interval = (
                DRAIN_INTERVAL_S if status.progressed and status.pending_chunks else IDLE_INTERVAL_S
            )
            self._wake.wait(interval)
            self._wake.clear()

    # ------------------------------------------------------------------- cycle

    def run_once(self) -> PumpStatus:
        config = self._config.get()
        if self._paused or not config.configured:
            self._note(
                pending_chunks=self._ledger.pending_count(),
                needs_attention=self._ledger.needs_attention_count(),
                progressed=False,
                last_error=None,
            )
            return self.status

        client = self._client_factory(config)
        progressed = False
        try:
            if not self._limits_read:
                self._config.set_limits(client.meta())
                self._limits_read = True

            device_id = self._ensure_device(client)
            self._heartbeat(client, device_id)
            progressed |= self._declare_sessions(client, device_id)
            progressed |= self._declare_gaps(client)
            progressed |= self._close_sessions(client)
            progressed |= self._upload(client)
            progressed |= self._poll_receipts(client)
            progressed |= self._report_released(client)
            self._note(
                last_error=None,
                authentication_failed=False,
                device_revoked=False,
                last_success_at=iso(self._now()) if progressed else self._status.last_success_at,
            )
        except IngestError as error:
            if error.unauthorized:
                # Stop rather than hammer: a rejected key means the account link
                # is gone, and only re-provisioning from the app can fix it.
                self._note(authentication_failed=True, last_error="Authentication expired")
            elif error.code == "DEVICE_REVOKED":
                self._note(
                    device_revoked=True, last_error="This appliance was removed from the account"
                )
            else:
                self._note(last_error=error.message)
        except TransportError as error:
            self._note(last_error=str(error))

        self._note(
            pending_chunks=self._ledger.pending_count(),
            needs_attention=self._ledger.needs_attention_count(),
            uploading=False,
            progressed=progressed,
        )
        return self.status

    # ------------------------------------------------------------------ pieces

    def _ensure_device(self, client: IngestClient) -> str:
        config = self._config.get()
        if config.device_id:
            return config.device_id
        device_id = client.register_device(firmware=self._firmware)
        self._config.update(device_id=device_id)
        return device_id

    def _heartbeat(self, client: IngestClient, device_id: str) -> None:
        now = self._now()
        if self._last_heartbeat is not None and (now - self._last_heartbeat) < timedelta(
            seconds=HEARTBEAT_INTERVAL_S
        ):
            return
        try:
            client.heartbeat(device_id, client_sent_at=iso(now))
            self._last_heartbeat = now
        except IngestError as error:
            if error.status == 404:
                # The device row is gone. Re-register under the same clientUuid;
                # the server reconciles it back to whatever id it now holds.
                self._config.update(device_id="")
                self._config.update(device_id=client.register_device(firmware=self._firmware))
                self._last_heartbeat = now
                return
            raise

    def _declare_sessions(self, client: IngestClient, device_id: str) -> bool:
        progressed = False
        for session in self._ledger.sessions_needing_declaration():
            declared = client.create_session(
                device_id=device_id,
                client_uuid=session.id,
                source_client_uuid=f"{session.id}:mix",
                started_at=session.device_started_at,
                timezone=session.timezone,
                consent_attested_at=session.started_at,
            )
            self._ledger.mark_session_declared(
                session.id,
                server_session_id=declared.session_id,
                server_source_id=declared.source_id,
            )
            progressed = True
        return progressed

    def _declare_gaps(self, client: IngestClient) -> bool:
        progressed = False
        for session_id in self._ledger.sessions_with_undeclared_gaps():
            session = self._ledger.session(session_id)
            if session is None or not session.server_session_id or not session.server_source_id:
                continue
            gaps = self._ledger.undeclared_gaps(session_id)
            if not gaps:
                continue
            payload = []
            for gap in gaps:
                entry = {
                    "sourceId": session.server_source_id,
                    "startOffsetMs": gap.start_offset_ms,
                    "endOffsetMs": gap.end_offset_ms,
                    "reason": gap.reason,
                }
                if gap.start_sequence is not None and gap.end_sequence is not None:
                    entry["startSequence"] = gap.start_sequence
                    entry["endSequence"] = gap.end_sequence
                payload.append(entry)
            client.declare_gaps(session.server_session_id, payload)
            self._ledger.mark_gaps_declared([gap.id for gap in gaps])
            progressed = True
        return progressed

    def _close_sessions(self, client: IngestClient) -> bool:
        progressed = False
        for session in self._ledger.sessions_needing_close():
            if not session.server_session_id or not session.server_source_id:
                continue
            client.close_session(
                session.server_session_id,
                ended_at=session.ended_at or utc_now_iso(),
                status=session.status,
                source_id=session.server_source_id,
                final_sequence=session.final_sequence if session.final_sequence is not None else -1,
            )
            self._ledger.mark_session_closed_on_server(session.id)
            progressed = True
        return progressed

    def _upload(self, client: IngestClient) -> bool:
        progressed = False
        for row in self._ledger.uploadable(limit=UPLOAD_BATCH, now=iso(self._now())):
            session = self._ledger.session(row.session_id)
            if session is None or not session.server_session_id or not session.server_source_id:
                continue

            payload = self._ledger.verify_payload(row)
            if payload is None:
                # Either the file vanished or its bytes no longer match the digest
                # recorded when it was written. Uploading it anyway would push
                # audio that contradicts its own hash.
                self._ledger.set_state(
                    row.id,
                    STATE_NEEDS_ATTENTION,
                    error="Stored audio no longer matches its checksum",
                )
                progressed = True
                continue

            self._note(uploading=True)
            self._ledger.set_state(row.id, STATE_UPLOADING, bump_attempts=True)
            try:
                receipt = client.upload_chunk(
                    session_id=session.server_session_id,
                    source_id=session.server_source_id,
                    sequence=row.sequence,
                    payload=payload,
                    idempotency_key=row.id,
                    sha256=row.sha256,
                    duration_ms=row.duration_ms,
                    overlap_ms=row.overlap_ms,
                    monotonic_offset_ms=row.monotonic_offset_ms,
                    device_started_at=session.device_started_at,
                    is_final=row.is_final,
                )
            except IngestError as error:
                if error.unauthorized or error.code == "DEVICE_REVOKED":
                    # Nothing is wrong with this chunk — the account link is.
                    # Park the pump, not the recording.
                    self._ledger.set_state(row.id, STATE_READY, error=error.message)
                    raise
                if error.retryable:
                    self._ledger.set_state(
                        row.id,
                        STATE_FAILED,
                        error=error.message,
                        next_attempt_at=self._backoff_until(row.attempts + 1),
                    )
                    progressed = True
                    continue
                self._ledger.set_state(
                    row.id, STATE_NEEDS_ATTENTION, error=f"{error.code}: {error.message}"
                )
                progressed = True
                continue
            except TransportError as error:
                self._ledger.set_state(
                    row.id,
                    STATE_FAILED,
                    error=str(error),
                    next_attempt_at=self._backoff_until(row.attempts + 1),
                )
                progressed = True
                continue

            self._absorb_receipt(row.id, receipt)
            progressed = True
        return progressed

    def _absorb_receipt(self, chunk_id: str, receipt: dict) -> None:
        server_chunk_id = receipt.get("chunkId")
        if isinstance(server_chunk_id, str) and server_chunk_id:
            self._ledger.set_server_chunk_id(chunk_id, server_chunk_id)

        if proves_safe_audio_release(receipt):
            self._ledger.set_state(chunk_id, STATE_TERMINAL, receipt=receipt)
            self._ledger.release_audio(chunk_id, receipt)
            return

        if receipt.get("state") == "reupload_required":
            attempts = self._ledger.bump_reupload_attempts(chunk_id)
            if attempts > MAX_REUPLOAD_ATTEMPTS:
                self._ledger.set_state(
                    chunk_id,
                    STATE_NEEDS_ATTENTION,
                    error="The server asked for this recording again too many times",
                    receipt=receipt,
                )
            else:
                self._ledger.set_state(chunk_id, STATE_READY, receipt=receipt)
            return

        self._ledger.set_state(chunk_id, STATE_UPLOADED, receipt=receipt)

    def _poll_receipts(self, client: IngestClient) -> bool:
        rows = [
            row for row in self._ledger.awaiting_receipt(limit=RECEIPT_BATCH) if row.server_chunk_id
        ]
        if not rows:
            return False
        by_server_id: dict[str, ChunkRow] = {row.server_chunk_id: row for row in rows}  # type: ignore[misc]
        receipts = client.chunk_statuses(list(by_server_id))
        progressed = False
        for receipt in receipts:
            row = by_server_id.get(receipt.get("chunkId", ""))
            if row is None:
                continue
            self._absorb_receipt(row.id, receipt)
            progressed = True
        return progressed

    def _report_released(self, client: IngestClient) -> bool:
        rows = [
            row
            for row in self._ledger.awaiting_release_report(limit=RECEIPT_BATCH)
            if row.server_chunk_id
        ]
        if not rows:
            return False
        client.release_chunks([row.server_chunk_id for row in rows])  # type: ignore[misc]
        self._ledger.forget(row.id for row in rows)
        return True

    def _backoff_until(self, attempts: int) -> str:
        delay = min(BACKOFF_MAX_S, BACKOFF_BASE_S * (2 ** max(0, attempts - 1)))
        jittered = delay * (1.0 + random.uniform(-BACKOFF_JITTER, BACKOFF_JITTER))
        return iso(self._now() + timedelta(seconds=jittered))


__all__ = ["UploadPump", "PumpStatus", "SESSION_ACTIVE", "STATE_UPLOADING"]
