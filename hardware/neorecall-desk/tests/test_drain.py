"""Handing recordings to the phone when there is no Wi-Fi.

The device's whole upload path assumes a network. A device that recorded a
meeting in a place with none — or whose Wi-Fi died — would otherwise hold the
audio hostage until somebody carried it home. The drain is the way out: the
owner's phone pulls the chunks over Bluetooth, stores them durably, and uploads
them through its own pipeline whenever its own settings allow.

Custody is the whole design. The device deletes nothing until the phone echoes
back the SHA-256 of the bytes it stored — the same bar as the server-side
release invariant, translated for a different receiver.
"""

import zlib

import cbor2
import pytest

from neorecall_desk import ledger as ledger_module
from neorecall_desk.control import protocol

# ------------------------------------------------------------------- protocol


def test_audio_pages_all_fit_one_notification():
    data = bytes(range(256)) * 40  # 10240 bytes
    pages = protocol.audio_pages("chunk-1234", data)

    assert len(pages) == -(-len(data) // protocol.AUDIO_PAGE_BYTES)
    for page in pages:
        # A page that does not fit is silently truncated by BlueZ; that failure
        # mode broke the discovery channel once and does not get a second go.
        assert len(page) <= protocol.STATUS_NOTIFICATION_LIMIT

    joined = b"".join(cbor2.loads(page)["d"] for page in pages)
    assert joined == data


def test_audio_pages_resume_from_a_later_page():
    data = b"x" * (protocol.AUDIO_PAGE_BYTES * 5)
    full = protocol.audio_pages("c", data)
    resumed = protocol.audio_pages("c", data, start_page=3)

    # Resume re-sends only what is missing, numbered exactly as before: at
    # Bluetooth speeds a restart is minutes, a resume is seconds.
    assert [cbor2.loads(p)["p"] for p in resumed] == [3, 4]
    assert resumed == full[3:]


def test_drain_commands_decode_with_their_arguments():
    pull = protocol.decode_command(cbor2.dumps({"c": "drain_pull", "ch": "abc", "fp": 7}))
    assert (pull.chunk, pull.page) == ("abc", 7)

    ack = protocol.decode_command(cbor2.dumps({"c": "drain_ack", "ch": "abc", "sh": "f" * 64}))
    assert (ack.chunk, ack.sha) == ("abc", "f" * 64)


def test_a_pull_without_a_chunk_id_is_refused():
    with pytest.raises(protocol.ProtocolError):
        protocol.decode_command(cbor2.dumps({"c": "drain_pull"}))


# --------------------------------------------------------------------- ledger


def _chunk_on(ledger, *, content=b"pcm" * 100):
    session = ledger.open_session(device_started_at="2026-08-30T10:00:00Z", timezone="UTC")
    row = ledger.append_chunk(
        session_id=session.id,
        sequence=0,
        payload=content,
        duration_ms=5000,
        overlap_ms=0,
        monotonic_offset_ms=0,
    )
    return session, row


def test_the_right_hash_releases_the_audio(ledger):
    from pathlib import Path

    _, row = _chunk_on(ledger)

    assert ledger.mark_drained(row.id, row.sha256)

    assert not Path(row.path).exists()
    assert ledger.chunk(row.id).state == ledger_module.STATE_DRAINED
    assert ledger.pending_count() == 0


def test_the_wrong_hash_releases_nothing(ledger):
    from pathlib import Path

    _, row = _chunk_on(ledger)
    path = Path(row.path)

    # A phone that stored nothing cannot fake the hash, and a phone that stored
    # corrupted bytes must not be able to destroy the only good copy.
    assert not ledger.mark_drained(row.id, "0" * 64)
    assert not ledger.mark_drained(row.id, "")

    assert path.exists()
    assert ledger.chunk(row.id).state == ledger_module.STATE_READY


def test_a_fully_drained_session_is_not_declared_to_the_server(ledger):
    session, row = _chunk_on(ledger)
    ledger.close_session(
        session.id, ended_at="2026-08-30T10:05:00Z", status="ended", final_sequence=0
    )
    ledger.mark_drained(row.id, row.sha256)

    # The audio now travels through the phone's import pipeline; declaring the
    # session here would create an empty twin of it on the server.
    assert session.id not in [s.id for s in ledger.sessions_needing_declaration()]


def test_an_empty_session_is_still_declared(ledger):
    session = ledger.open_session(device_started_at="2026-08-30T10:00:00Z", timezone="UTC")
    ledger.close_session(
        session.id, ended_at="2026-08-30T10:05:00Z", status="ended", final_sequence=None
    )

    # No chunks is not the same as drained: the server has to see the session
    # to close it, or it stays "active" in the account for ever.
    assert session.id in [s.id for s in ledger.sessions_needing_declaration()]


# ----------------------------------------------------------------- round trip


def test_compressed_pages_reassemble_to_the_exact_bytes():
    """The full wire trip: compress, page, join, inflate, hash-check."""
    audio = (b"\x00\x00\x10\x01" * 4000) + bytes(1000)  # speech-ish + silence
    packed = zlib.compress(audio, 6)
    pages = protocol.audio_pages("cafe0123", packed)

    received = b"".join(cbor2.loads(page)["d"] for page in pages)
    assert zlib.decompress(received) == audio
    # And the silence-heavy tail is why compression earns its place at all.
    assert len(packed) < len(audio) / 2
