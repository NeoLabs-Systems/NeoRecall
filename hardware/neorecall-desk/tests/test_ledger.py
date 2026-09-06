"""The durability contract: nothing is deleted without proof, nothing is lost."""

import pytest

from neorecall_desk import ledger as L


def complete_receipt(chunk_id="11111111-1111-4111-8111-111111111111", **overrides):
    receipt = {
        "chunkId": chunk_id,
        "state": "transcribed",
        "persistedAt": "2026-08-26T09:00:00.000Z",
        "serverAudioDeletedAt": "2026-08-26T09:00:01.000Z",
        "transcriptSha256": "a" * 64,
    }
    receipt.update(overrides)
    return receipt


def add_chunk(store, session, sequence=0, payload=b"\x01\x02" * 100, **kw):
    return store.append_chunk(
        session_id=session.id,
        sequence=sequence,
        payload=payload,
        duration_ms=kw.pop("duration_ms", 30000),
        overlap_ms=kw.pop("overlap_ms", 0),
        monotonic_offset_ms=kw.pop("monotonic_offset_ms", 0),
        **kw,
    )


@pytest.fixture()
def session(ledger):
    return ledger.open_session(device_started_at=L.utc_now_iso(), timezone="Europe/Berlin")


# ------------------------------------------------------------------- invariant


def test_a_complete_receipt_proves_release():
    assert L.proves_safe_audio_release(complete_receipt())


@pytest.mark.parametrize(
    "override",
    [
        {"state": "uploaded"},
        {"state": "retryable_failed"},
        {"persistedAt": None},
        {"persistedAt": "not a date"},
        {"serverAudioDeletedAt": None},
        {"serverAudioDeletedAt": ""},
        {"transcriptSha256": ""},
        {"chunkId": ""},
    ],
)
def test_an_incomplete_receipt_never_proves_release(override):
    assert not L.proves_safe_audio_release(complete_receipt(**override))


def test_a_silent_chunk_is_still_a_terminal_receipt():
    assert L.proves_safe_audio_release(complete_receipt(state="silent"))


def test_non_receipts_prove_nothing():
    assert not L.proves_safe_audio_release(None)
    assert not L.proves_safe_audio_release({})


def test_release_refuses_to_delete_audio_without_proof(ledger, session):
    row = add_chunk(ledger, session)
    assert row.path.exists()

    assert ledger.release_audio(row.id, complete_receipt(serverAudioDeletedAt=None)) is False
    assert row.path.exists(), "audio was deleted without the server proving its own copy is gone"
    assert ledger.chunk(row.id).state == L.STATE_READY


def test_release_deletes_audio_once_proven(ledger, session):
    row = add_chunk(ledger, session)

    assert ledger.release_audio(row.id, complete_receipt()) is True
    assert not row.path.exists()
    assert ledger.chunk(row.id).state == L.STATE_RELEASED


# ---------------------------------------------------------------- write safety


def test_a_chunk_is_written_atomically_and_hashed(ledger, session):
    import hashlib

    payload = b"the quick brown fox" * 50
    row = add_chunk(ledger, session, payload=payload)

    assert row.path.read_bytes() == payload
    assert row.sha256 == hashlib.sha256(payload).hexdigest()
    assert not list(ledger.audio_dir.glob("*.partial"))


def test_corrupted_audio_is_refused_before_upload(ledger, session):
    row = add_chunk(ledger, session)
    row.path.write_bytes(b"corrupted")

    assert ledger.verify_payload(row) is None


def test_missing_audio_is_refused_before_upload(ledger, session):
    row = add_chunk(ledger, session)
    row.path.unlink()

    assert ledger.verify_payload(row) is None


def test_the_same_sequence_cannot_be_written_twice(ledger, session):
    import sqlite3

    add_chunk(ledger, session, sequence=3)
    with pytest.raises(sqlite3.IntegrityError):
        add_chunk(ledger, session, sequence=3)


def test_a_rejected_row_leaves_no_orphaned_audio(ledger, session):
    import sqlite3

    add_chunk(ledger, session, sequence=3)
    before = set(ledger.audio_dir.glob("*.wav"))
    with pytest.raises(sqlite3.IntegrityError):
        add_chunk(ledger, session, sequence=3)

    assert set(ledger.audio_dir.glob("*.wav")) == before


# -------------------------------------------------------------------- ordering


def test_crash_residue_is_retried_before_fresh_chunks(ledger, session):
    fresh = add_chunk(ledger, session, sequence=1)
    interrupted = add_chunk(ledger, session, sequence=0)
    ledger.set_state(interrupted.id, L.STATE_UPLOADING)

    order = [row.id for row in ledger.uploadable()]
    assert order[0] == interrupted.id
    assert fresh.id in order


def test_a_backed_off_chunk_is_not_offered_before_its_time(ledger, session):
    row = add_chunk(ledger, session)
    ledger.set_state(row.id, L.STATE_FAILED, next_attempt_at="2099-01-01T00:00:00.000Z")

    assert ledger.uploadable() == []


def test_next_sequence_continues_after_the_highest_written(ledger, session):
    assert ledger.next_sequence(session.id) == 0
    add_chunk(ledger, session, sequence=0)
    add_chunk(ledger, session, sequence=1)
    assert ledger.next_sequence(session.id) == 2


# -------------------------------------------------------------------- recovery


def test_recovery_reopens_uploads_that_died_mid_flight(ledger, session):
    row = add_chunk(ledger, session)
    ledger.set_state(row.id, L.STATE_UPLOADING)

    report = ledger.recover()

    assert report["uploads_reset"] == 1
    assert ledger.chunk(row.id).state == L.STATE_READY


def test_recovery_closes_a_session_that_lost_power_mid_recording(ledger, session):
    add_chunk(ledger, session, sequence=0)
    add_chunk(ledger, session, sequence=1)

    report = ledger.recover()

    recovered = ledger.session(session.id)
    assert report["sessions_interrupted"] == 1
    assert recovered.status == L.SESSION_INTERRUPTED
    assert recovered.final_sequence == 1
    # An interrupted stream is described by its final sequence, not by a gap:
    # a gap describes a hole inside a stream, not the end of one.
    assert ledger.undeclared_gaps(session.id) == []


def test_recovery_removes_half_written_audio(ledger, session):
    stray = ledger.audio_dir / "abc.wav.partial"
    stray.write_bytes(b"half a chunk")

    report = ledger.recover()

    assert report["partials_removed"] == 1
    assert not stray.exists()


def test_recovery_removes_audio_no_row_points_at(ledger, session):
    orphan = ledger.audio_dir / "22222222-2222-4222-8222-222222222222.wav"
    orphan.write_bytes(b"nobody's chunk")
    kept = add_chunk(ledger, session)

    report = ledger.recover()

    assert report["orphans_removed"] == 1
    assert not orphan.exists()
    assert kept.path.exists()


def test_recovery_is_safe_to_run_twice(ledger, session):
    add_chunk(ledger, session)
    ledger.recover()
    second = ledger.recover()

    assert second["sessions_interrupted"] == 0


# ------------------------------------------------------------------------ gaps


def test_a_gap_must_cover_a_real_window(ledger, session):
    with pytest.raises(ValueError):
        ledger.record_gap(
            session_id=session.id,
            reason=L.GAP_CAPTURE_ERROR,
            start_offset_ms=5000,
            end_offset_ms=5000,
        )


def test_a_gap_reason_the_server_would_reject_is_refused_here(ledger, session):
    with pytest.raises(ValueError):
        ledger.record_gap(
            session_id=session.id, reason="ran_out_of_coffee", start_offset_ms=0, end_offset_ms=10
        )


def test_gap_sequence_coverage_must_name_both_ends(ledger, session):
    with pytest.raises(ValueError):
        ledger.record_gap(
            session_id=session.id,
            reason=L.GAP_CAPTURE_ERROR,
            start_offset_ms=0,
            end_offset_ms=10,
            start_sequence=3,
        )


def test_gaps_are_only_offered_once_declared(ledger, session):
    ledger.record_gap(
        session_id=session.id,
        reason=L.GAP_CAPTURE_ERROR,
        start_offset_ms=1000,
        end_offset_ms=4000,
        start_sequence=2,
        end_sequence=3,
    )
    ledger.mark_session_declared(session.id, server_session_id="s", server_source_id="src")

    assert ledger.sessions_with_undeclared_gaps() == [session.id]
    gaps = ledger.undeclared_gaps(session.id)
    assert (gaps[0].start_offset_ms, gaps[0].end_offset_ms) == (1000, 4000)

    ledger.mark_gaps_declared([gaps[0].id])
    assert ledger.sessions_with_undeclared_gaps() == []


# ---------------------------------------------------------------------- counts


def test_pending_count_ignores_released_and_parked_chunks(ledger, session):
    add_chunk(ledger, session, sequence=0)
    released = add_chunk(ledger, session, sequence=1)
    parked = add_chunk(ledger, session, sequence=2)
    ledger.release_audio(released.id, complete_receipt())
    ledger.set_state(parked.id, L.STATE_NEEDS_ATTENTION)

    assert ledger.pending_count() == 1
    assert ledger.needs_attention_count() == 1
