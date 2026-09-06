"""The upload pump against a scripted server.

These tests exist to answer one question in many shapes: can this appliance lose
a recording? Every failure mode the plan calls out — server down for a day, a
process killed mid-PUT, an expired key, a corrupted file — appears here.
"""

from datetime import UTC, datetime, timedelta

import pytest

from neorecall_desk import ledger as L
from neorecall_desk.config import ConfigStore, ServerLimits
from neorecall_desk.ingest.client import DeclaredSession, IngestError, TransportError
from neorecall_desk.ingest.pump import MAX_REUPLOAD_ATTEMPTS, UploadPump

SERVER_CHUNK_ID = "33333333-3333-4333-8333-333333333333"


def terminal_receipt(chunk_id=SERVER_CHUNK_ID, state="transcribed"):
    return {
        "chunkId": chunk_id,
        "state": state,
        "persistedAt": "2026-08-26T09:00:00.000Z",
        "serverAudioDeletedAt": "2026-08-26T09:00:01.000Z",
        "transcriptSha256": "b" * 64,
    }


def pending_receipt(chunk_id=SERVER_CHUNK_ID):
    return {"chunkId": chunk_id, "state": "uploaded"}


class FakeClient:
    """A server that does exactly what a test tells it to."""

    def __init__(self, config):
        self.config = config
        self.uploads = []
        self.released = []
        self.gaps = []
        self.closed = []
        self.heartbeats = 0
        self.registrations = 0
        self.upload_result = terminal_receipt()
        self.upload_error = None
        self.status_result = []
        self.heartbeat_error = None
        self.register_id = "44444444-4444-4444-8444-444444444444"

    def meta(self):
        return ServerLimits()

    def register_device(self, *, firmware):
        self.registrations += 1
        return self.register_id

    def heartbeat(self, device_id, *, client_sent_at):
        if self.heartbeat_error is not None:
            error, self.heartbeat_error = self.heartbeat_error, None
            raise error
        self.heartbeats += 1
        return {}

    def create_session(self, **kw):
        return DeclaredSession(session_id="server-session", source_id="server-source")

    def close_session(self, session_id, *, ended_at, status, source_id, final_sequence):
        self.closed.append((session_id, status, final_sequence))

    def declare_gaps(self, session_id, gaps):
        self.gaps.append((session_id, gaps))

    def upload_chunk(self, **kw):
        if self.upload_error is not None:
            error, self.upload_error = self.upload_error, None
            raise error
        self.uploads.append(kw)
        return self.upload_result

    def chunk_statuses(self, chunk_ids):
        return self.status_result

    def release_chunks(self, chunk_ids):
        self.released.extend(chunk_ids)
        return len(chunk_ids)


@pytest.fixture()
def configured(state_dir):
    store = ConfigStore()
    store.update(
        backend_url="https://recall.example.com",
        api_key="nrk_test_key",
        device_id="44444444-4444-4444-8444-444444444444",
    )
    return store


@pytest.fixture()
def rig(ledger, configured):
    client = FakeClient(configured.get())
    clock = {"now": datetime(2026, 8, 26, 9, 0, tzinfo=UTC)}
    pump = UploadPump(
        ledger=ledger,
        config_store=configured,
        client_factory=lambda config: client,
        now=lambda: clock["now"],
    )
    return pump, client, clock


def make_chunk(ledger, sequence=0, payload=b"\x11\x22" * 200):
    session = ledger.active_session() or ledger.open_session(
        device_started_at=L.utc_now_iso(), timezone="Europe/Berlin"
    )
    return session, ledger.append_chunk(
        session_id=session.id,
        sequence=sequence,
        payload=payload,
        duration_ms=30000,
        overlap_ms=0 if sequence == 0 else 2000,
        monotonic_offset_ms=sequence * 28000,
    )


# ------------------------------------------------------------------ happy path


def test_a_recording_reaches_the_server_and_the_local_copy_disappears(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)

    pump.run_once()

    assert len(client.uploads) == 1
    assert client.uploads[0]["idempotency_key"] == row.id
    assert client.uploads[0]["sha256"] == row.sha256
    assert not row.path.exists(), "audio should be gone once the receipt proved it is safe"
    assert client.released == [SERVER_CHUNK_ID]
    assert ledger.chunk(row.id) is None, "a reported release should leave no bookkeeping behind"


def test_a_silent_chunk_also_releases(ledger, rig):
    pump, client, _ = rig
    client.upload_result = terminal_receipt(state="silent")
    _, row = make_chunk(ledger)

    pump.run_once()

    assert not row.path.exists()
    assert client.released == [SERVER_CHUNK_ID]


def test_the_session_is_declared_before_any_chunk_goes_out(ledger, rig):
    pump, _, _ = rig
    session, _ = make_chunk(ledger)

    pump.run_once()

    declared = ledger.session(session.id)
    assert declared.declared
    assert declared.server_session_id == "server-session"
    assert declared.server_source_id == "server-source"


def test_nothing_happens_at_all_before_the_appliance_is_set_up(ledger, state_dir):
    store = ConfigStore()
    client = FakeClient(store.get())
    pump = UploadPump(ledger=ledger, config_store=store, client_factory=lambda c: client)
    make_chunk(ledger)

    status = pump.run_once()

    assert client.uploads == []
    assert client.registrations == 0
    assert status.pending_chunks == 1


# --------------------------------------------------------- deferred receipts


def test_audio_is_kept_while_the_receipt_is_still_pending(ledger, rig):
    pump, client, _ = rig
    client.upload_result = pending_receipt()
    _, row = make_chunk(ledger)

    pump.run_once()

    assert row.path.exists(), "audio must survive until the transcript is proven stored"
    assert ledger.chunk(row.id).state == L.STATE_UPLOADED
    assert client.released == []


def test_a_later_poll_finishes_what_the_upload_left_open(ledger, rig):
    pump, client, _ = rig
    client.upload_result = pending_receipt()
    _, row = make_chunk(ledger)
    pump.run_once()

    client.status_result = [terminal_receipt()]
    pump.run_once()

    assert not row.path.exists()
    assert client.released == [SERVER_CHUNK_ID]


# ----------------------------------------------------------------- resilience


def test_a_server_that_is_down_for_a_day_loses_nothing(ledger, rig):
    pump, client, clock = rig
    _, row = make_chunk(ledger)

    for _ in range(40):
        client.upload_error = TransportError("network is unreachable")
        pump.run_once()
        clock["now"] += timedelta(hours=1)

    assert row.path.exists()
    assert ledger.pending_count() == 1
    assert ledger.needs_attention_count() == 0

    pump.run_once()

    assert not row.path.exists()
    assert client.released == [SERVER_CHUNK_ID]


def test_a_failed_chunk_waits_out_its_backoff_before_being_retried(ledger, rig):
    pump, client, clock = rig
    _, row = make_chunk(ledger)
    client.upload_error = TransportError("timed out")
    pump.run_once()

    assert ledger.chunk(row.id).state == L.STATE_FAILED
    assert ledger.uploadable(now=L.iso(clock["now"])) == []

    clock["now"] += timedelta(minutes=10)
    assert [r.id for r in ledger.uploadable(now=L.iso(clock["now"]))] == [row.id]


def test_a_server_error_is_retried_but_a_rejected_request_is_not(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)

    client.upload_error = IngestError(503, "UNAVAILABLE", "Service unavailable.")
    pump.run_once()
    assert ledger.chunk(row.id).state == L.STATE_FAILED

    client.upload_error = IngestError(
        400, "INVALID_DURATION", "Chunk duration is outside the configured range."
    )
    ledger.set_state(row.id, L.STATE_READY)
    pump.run_once()
    assert ledger.chunk(row.id).state == L.STATE_NEEDS_ATTENTION
    assert row.path.exists(), "a parked chunk keeps its audio"


def test_an_expired_key_pauses_uploading_instead_of_burning_through_it(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)
    client.upload_error = IngestError(401, "UNAUTHORIZED", "Authentication required.")

    status = pump.run_once()

    assert status.authentication_failed
    assert ledger.chunk(row.id).state == L.STATE_READY
    assert row.path.exists()


def test_a_revoked_appliance_says_so_in_plain_terms(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)
    client.upload_error = IngestError(403, "DEVICE_REVOKED", "This device has been revoked.")

    status = pump.run_once()

    assert status.device_revoked
    assert "removed from the account" in status.last_error
    # The recording is untouched: it is the account link that broke, not the audio.
    assert ledger.chunk(row.id).state == L.STATE_READY
    assert row.path.exists()


def test_audio_that_no_longer_matches_its_checksum_is_never_uploaded(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)
    row.path.write_bytes(b"bit rot")

    pump.run_once()

    assert client.uploads == []
    assert ledger.chunk(row.id).state == L.STATE_NEEDS_ATTENTION


def test_a_chunk_the_server_keeps_asking_for_is_eventually_parked(ledger, rig):
    pump, client, _ = rig
    client.upload_result = {"chunkId": SERVER_CHUNK_ID, "state": "reupload_required"}
    _, row = make_chunk(ledger)

    for _ in range(MAX_REUPLOAD_ATTEMPTS):
        pump.run_once()
        assert ledger.chunk(row.id).state == L.STATE_READY

    pump.run_once()

    assert ledger.chunk(row.id).state == L.STATE_NEEDS_ATTENTION
    assert row.path.exists(), "parking a chunk must not throw its audio away"


def test_an_upload_killed_mid_flight_is_retried_after_recovery(ledger, rig):
    pump, client, _ = rig
    _, row = make_chunk(ledger)
    ledger.set_state(row.id, L.STATE_UPLOADING)  # the process died here

    ledger.recover()
    pump.run_once()

    assert len(client.uploads) == 1
    assert client.uploads[0]["idempotency_key"] == row.id, "the retry must be idempotent"
    assert not row.path.exists()


# -------------------------------------------------------------------- devices


def test_the_appliance_registers_itself_when_it_has_no_identity_yet(ledger, configured, rig):
    pump, client, _ = rig
    configured.update(device_id="")
    make_chunk(ledger)

    pump.run_once()

    assert client.registrations == 1
    assert configured.get().device_id == client.register_id


def test_a_forgotten_device_row_is_re_registered_rather_than_fatal(ledger, configured, rig):
    pump, client, _ = rig
    client.heartbeat_error = IngestError(404, "NOT_FOUND", "Device not found.")
    make_chunk(ledger)

    pump.run_once()

    assert client.registrations == 1
    assert configured.get().device_id == client.register_id


def test_the_heartbeat_is_not_sent_on_every_cycle(ledger, rig):
    pump, client, clock = rig
    make_chunk(ledger)

    pump.run_once()
    pump.run_once()
    assert client.heartbeats == 1

    clock["now"] += timedelta(minutes=6)
    pump.run_once()
    assert client.heartbeats == 2


# ------------------------------------------------------------- gaps and close


def test_a_capture_hole_is_declared_to_the_server(ledger, rig):
    pump, client, _ = rig
    session, _ = make_chunk(ledger)
    ledger.record_gap(
        session_id=session.id,
        reason=L.GAP_CAPTURE_ERROR,
        start_offset_ms=28000,
        end_offset_ms=56000,
        start_sequence=1,
        end_sequence=2,
    )

    pump.run_once()

    assert client.gaps == [
        (
            "server-session",
            [
                {
                    "sourceId": "server-source",
                    "startOffsetMs": 28000,
                    "endOffsetMs": 56000,
                    "reason": "capture_error",
                    "startSequence": 1,
                    "endSequence": 2,
                }
            ],
        )
    ]
    assert ledger.undeclared_gaps(session.id) == []


def test_a_finished_recording_is_closed_on_the_server_exactly_once(ledger, rig):
    pump, client, _ = rig
    session, _ = make_chunk(ledger)
    ledger.close_session(
        session.id, ended_at=L.utc_now_iso(), status=L.SESSION_ENDED, final_sequence=0
    )

    pump.run_once()
    pump.run_once()

    assert client.closed == [("server-session", "ended", 0)]
    assert ledger.session(session.id).closed_on_server


def test_a_session_cut_short_by_power_loss_is_closed_as_interrupted(ledger, rig):
    pump, client, _ = rig
    make_chunk(ledger)
    ledger.recover()

    pump.run_once()

    assert client.closed == [("server-session", "interrupted", 0)]
