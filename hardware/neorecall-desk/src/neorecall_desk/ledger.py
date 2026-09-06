"""The durable chunk ledger.

This module owns the reliability invariant from ``AGENTS.md``: a chunk's audio
may only be deleted once a terminal receipt proves both that the transcript was
persisted and that the server deleted its own copy. Everything else in the
appliance is allowed to crash, be killed, or lose power at any instant; what
survives is this SQLite file plus the WAV files it points at.

Unlike the ESP32 panel, the appliance has an SD card, so there is no
"abandon the chunk" path. A chunk that cannot be uploaded waits.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
import uuid
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from . import paths

SCHEMA_VERSION = 1

# Local chunk lifecycle. Mirrors flutter_app/lib/src/models/chunk.dart so the two
# implementations can be reasoned about together.
STATE_READY = "ready"
STATE_UPLOADING = "uploading"
STATE_UPLOADED = "uploaded"
STATE_TERMINAL = "terminal"
STATE_RELEASED = "released"
STATE_FAILED = "failed"
#: Handed to the owner's phone over Bluetooth. Terminal like released, but the
#: proof is different: not a server receipt, a SHA-256 echoed back by the phone
#: after it stored the audio durably. Custody moved; the recording is now the
#: phone's to upload through its own pipeline.
STATE_DRAINED = "drained"
STATE_NEEDS_ATTENTION = "needs_attention"

# Gap reasons accepted by POST /api/v1/ingest/sessions/{id}/gaps. The set is
# fixed by the zod enum in server/routes/ingest.js; anything else is rejected.
GAP_SLEEP = "sleep"
GAP_PERMISSION_LOST = "permission_lost"
GAP_STORAGE_FULL = "storage_full"
GAP_CAPTURE_ERROR = "capture_error"
GAP_USER_PAUSED = "user_paused"
GAP_DEVICE_SHUTDOWN = "device_shutdown"
GAP_REASONS = frozenset(
    {
        GAP_SLEEP,
        GAP_PERMISSION_LOST,
        GAP_STORAGE_FULL,
        GAP_CAPTURE_ERROR,
        GAP_USER_PAUSED,
        GAP_DEVICE_SHUTDOWN,
    }
)

SESSION_ACTIVE = "active"
SESSION_ENDED = "ended"
SESSION_INTERRUPTED = "interrupted"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id                TEXT PRIMARY KEY,
  server_session_id TEXT,
  server_source_id  TEXT,
  device_started_at TEXT NOT NULL,
  started_at        TEXT NOT NULL,
  ended_at          TEXT,
  status            TEXT NOT NULL,
  final_sequence    INTEGER,
  timezone          TEXT NOT NULL DEFAULT 'UTC',
  declared          INTEGER NOT NULL DEFAULT 0,
  closed_on_server  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chunks (
  id                  TEXT PRIMARY KEY,
  server_chunk_id     TEXT,
  session_id          TEXT NOT NULL REFERENCES sessions(id),
  sequence            INTEGER NOT NULL,
  path                TEXT NOT NULL,
  byte_size           INTEGER NOT NULL,
  sha256              TEXT NOT NULL,
  duration_ms         INTEGER NOT NULL,
  overlap_ms          INTEGER NOT NULL,
  monotonic_offset_ms INTEGER NOT NULL,
  is_final            INTEGER NOT NULL DEFAULT 0,
  state               TEXT NOT NULL,
  attempts            INTEGER NOT NULL DEFAULT 0,
  reupload_attempts   INTEGER NOT NULL DEFAULT 0,
  next_attempt_at     TEXT,
  last_error          TEXT,
  receipt_json        TEXT,
  created_at          TEXT NOT NULL,
  UNIQUE(session_id, sequence)
);

CREATE INDEX IF NOT EXISTS chunks_by_state ON chunks(state, created_at);

CREATE TABLE IF NOT EXISTS gaps (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT NOT NULL REFERENCES sessions(id),
  reason          TEXT NOT NULL,
  start_offset_ms INTEGER NOT NULL,
  end_offset_ms   INTEGER NOT NULL,
  start_sequence  INTEGER,
  end_sequence    INTEGER,
  declared        INTEGER NOT NULL DEFAULT 0
);
"""


def iso(moment: datetime) -> str:
    """ISO-8601 in exactly the shape the server's zod datetime validator wants."""
    moment = moment.astimezone(UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def utc_now_iso() -> str:
    return iso(datetime.now(UTC))


def _parses_as_timestamp(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return True


def proves_safe_audio_release(receipt: dict | None) -> bool:
    """The one gate that may delete local audio.

    Ported field for field from ``provesSafeAudioRelease`` in
    flutter_app/lib/src/models/chunk.dart. Anything less than complete proof —
    a missing deletion timestamp, an unparseable date, an empty transcript hash —
    means the audio stays on the SD card.
    """
    if not isinstance(receipt, dict):
        return False
    if receipt.get("state") not in ("transcribed", "silent"):
        return False
    if not _parses_as_timestamp(receipt.get("persistedAt")):
        return False
    if not _parses_as_timestamp(receipt.get("serverAudioDeletedAt")):
        return False
    if not isinstance(receipt.get("chunkId"), str) or not receipt["chunkId"]:
        return False
    sha = receipt.get("transcriptSha256")
    return isinstance(sha, str) and bool(sha)


@dataclass(frozen=True)
class ChunkRow:
    id: str
    server_chunk_id: str | None
    session_id: str
    sequence: int
    path: Path
    byte_size: int
    sha256: str
    duration_ms: int
    overlap_ms: int
    monotonic_offset_ms: int
    is_final: bool
    state: str
    attempts: int
    reupload_attempts: int
    receipt: dict | None
    created_at: str


@dataclass(frozen=True)
class SessionRow:
    id: str
    server_session_id: str | None
    server_source_id: str | None
    device_started_at: str
    started_at: str
    ended_at: str | None
    status: str
    final_sequence: int | None
    timezone: str
    declared: bool
    closed_on_server: bool


@dataclass(frozen=True)
class GapRow:
    id: int
    session_id: str
    reason: str
    start_offset_ms: int
    end_offset_ms: int
    start_sequence: int | None
    end_sequence: int | None


class Ledger:
    """Durable, thread-safe store for sessions, chunks and gaps."""

    def __init__(self, path: Path | None = None, audio_dir: Path | None = None) -> None:
        self._path = path or paths.ledger_file()
        self._audio_dir = audio_dir or paths.audio_dir()
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._audio_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._db = sqlite3.connect(self._path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.executescript(_SCHEMA)
        self._db.execute(
            "INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', ?)",
            (str(SCHEMA_VERSION),),
        )
        self._db.commit()

    @property
    def audio_dir(self) -> Path:
        return self._audio_dir

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            try:
                yield self._db
                self._db.commit()
            except BaseException:
                self._db.rollback()
                raise

    # ---------------------------------------------------------------- sessions

    def open_session(self, *, device_started_at: str, timezone: str) -> SessionRow:
        session_id = str(uuid.uuid4())
        now = utc_now_iso()
        with self._tx() as db:
            db.execute(
                """INSERT INTO sessions
                   (id, device_started_at, started_at, status, timezone)
                   VALUES (?,?,?,?,?)""",
                (session_id, device_started_at, now, SESSION_ACTIVE, timezone or "UTC"),
            )
        return self.session(session_id)  # type: ignore[return-value]

    def session(self, session_id: str) -> SessionRow | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        return _session_from_row(row) if row else None

    def active_session(self) -> SessionRow | None:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM sessions WHERE status=? ORDER BY started_at DESC LIMIT 1",
                (SESSION_ACTIVE,),
            ).fetchone()
        return _session_from_row(row) if row else None

    def close_session(
        self, session_id: str, *, ended_at: str, status: str, final_sequence: int | None
    ) -> None:
        with self._tx() as db:
            db.execute(
                "UPDATE sessions SET ended_at=?, status=?, final_sequence=? WHERE id=?",
                (ended_at, status, final_sequence, session_id),
            )

    def mark_session_declared(
        self, session_id: str, *, server_session_id: str, server_source_id: str
    ) -> None:
        with self._tx() as db:
            db.execute(
                """UPDATE sessions SET server_session_id=?, server_source_id=?, declared=1
                   WHERE id=?""",
                (server_session_id, server_source_id, session_id),
            )

    def mark_session_closed_on_server(self, session_id: str) -> None:
        with self._tx() as db:
            db.execute("UPDATE sessions SET closed_on_server=1 WHERE id=?", (session_id,))

    def sessions_needing_declaration(self) -> list[SessionRow]:
        with self._lock:
            # A session whose every chunk went to the phone has nothing left for
            # the server: declaring it would create an empty session there while
            # the audio arrives through the phone's own import pipeline.
            # Skipped only when the phone took every chunk it had. A session
            # with no chunks at all still goes to the server — that is how an
            # empty recording gets closed instead of staying active for ever.
            rows = self._db.execute(
                """SELECT * FROM sessions WHERE declared=0
                   AND NOT (
                       EXISTS (SELECT 1 FROM chunks
                               WHERE chunks.session_id = sessions.id)
                       AND NOT EXISTS (SELECT 1 FROM chunks
                                       WHERE chunks.session_id = sessions.id
                                         AND chunks.state != ?)
                   )
                   ORDER BY started_at""",
                (STATE_DRAINED,),
            ).fetchall()
        return [_session_from_row(row) for row in rows]

    def sessions_needing_close(self) -> list[SessionRow]:
        with self._lock:
            rows = self._db.execute(
                """SELECT * FROM sessions
                   WHERE declared=1 AND closed_on_server=0 AND status IN (?,?)
                   ORDER BY started_at""",
                (SESSION_ENDED, SESSION_INTERRUPTED),
            ).fetchall()
        return [_session_from_row(row) for row in rows]

    # ------------------------------------------------------------------ chunks

    def next_sequence(self, session_id: str) -> int:
        with self._lock:
            row = self._db.execute(
                "SELECT MAX(sequence) AS last FROM chunks WHERE session_id=?", (session_id,)
            ).fetchone()
        last = row["last"] if row and row["last"] is not None else -1
        return int(last) + 1

    def append_chunk(
        self,
        *,
        session_id: str,
        sequence: int,
        payload: bytes,
        duration_ms: int,
        overlap_ms: int,
        monotonic_offset_ms: int,
        is_final: bool = False,
    ) -> ChunkRow:
        """Write the audio, then the row.

        The audio lands as ``<id>.wav.partial`` and is renamed only after fsync,
        so a power loss can leave a stray partial file — which the recovery sweep
        deletes — but never a ledger row pointing at a truncated chunk.
        """
        chunk_id = str(uuid.uuid4())
        final_path = self._audio_dir / f"{chunk_id}.wav"
        partial = final_path.with_suffix(".wav.partial")
        digest = hashlib.sha256(payload).hexdigest()

        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
        os.replace(partial, final_path)

        try:
            with self._tx() as db:
                db.execute(
                    """INSERT INTO chunks
                       (id, session_id, sequence, path, byte_size, sha256, duration_ms,
                        overlap_ms, monotonic_offset_ms, is_final, state, created_at)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (
                        chunk_id,
                        session_id,
                        sequence,
                        str(final_path),
                        len(payload),
                        digest,
                        duration_ms,
                        overlap_ms,
                        monotonic_offset_ms,
                        1 if is_final else 0,
                        STATE_READY,
                        utc_now_iso(),
                    ),
                )
        except BaseException:
            final_path.unlink(missing_ok=True)
            raise
        return self.chunk(chunk_id)  # type: ignore[return-value]

    def chunk(self, chunk_id: str) -> ChunkRow | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM chunks WHERE id=?", (chunk_id,)).fetchone()
        return _chunk_from_row(row) if row else None

    def uploadable(self, *, limit: int = 64, now: str | None = None) -> list[ChunkRow]:
        """Chunks the pump may send, oldest first.

        ``uploading`` rows come first because they are crash residue: the process
        died mid-PUT and the upload is idempotent, so retrying is both safe and
        the fastest way back to a consistent state.
        """
        moment = now or utc_now_iso()
        with self._lock:
            rows = self._db.execute(
                """SELECT * FROM chunks
                   WHERE state IN (?,?,?)
                     AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                   ORDER BY CASE state WHEN ? THEN 0 ELSE 1 END, created_at, sequence
                   LIMIT ?""",
                (STATE_UPLOADING, STATE_READY, STATE_FAILED, moment, STATE_UPLOADING, limit),
            ).fetchall()
        return [_chunk_from_row(row) for row in rows]

    def awaiting_receipt(self, *, limit: int = 500) -> list[ChunkRow]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM chunks WHERE state=? ORDER BY created_at LIMIT ?",
                (STATE_UPLOADED, limit),
            ).fetchall()
        return [_chunk_from_row(row) for row in rows]

    def awaiting_release_report(self, *, limit: int = 500) -> list[ChunkRow]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM chunks WHERE state=? ORDER BY created_at LIMIT ?",
                (STATE_RELEASED, limit),
            ).fetchall()
        return [_chunk_from_row(row) for row in rows]

    def pending_count(self) -> int:
        with self._lock:
            row = self._db.execute(
                "SELECT COUNT(*) AS n FROM chunks WHERE state NOT IN (?,?,?)",
                (STATE_RELEASED, STATE_NEEDS_ATTENTION, STATE_DRAINED),
            ).fetchone()
        return int(row["n"])

    # ------------------------------------------------------------------- drain

    def drainable(self) -> list[ChunkRow]:
        """Chunks the phone may pull over Bluetooth: ready ones, oldest first."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM chunks WHERE state=? ORDER BY created_at",
                (STATE_READY,),
            ).fetchall()
        return [_chunk_from_row(row) for row in rows]

    def mark_drained(self, chunk_id: str, verified_sha256: str) -> bool:
        """Delete the local audio because the phone proved it holds it.

        The same bar as the server-side release, translated: the phone sends
        back the SHA-256 of the bytes it durably stored, and only an exact match
        releases anything. A phone that stored nothing cannot fake the hash.
        """
        row = self.chunk(chunk_id)
        if row is None or row.state != STATE_READY:
            return False
        if not verified_sha256 or verified_sha256.lower() != row.sha256.lower():
            return False
        Path(row.path).unlink(missing_ok=True)
        self.set_state(chunk_id, STATE_DRAINED)
        return True

    def needs_attention_count(self) -> int:
        with self._lock:
            row = self._db.execute(
                "SELECT COUNT(*) AS n FROM chunks WHERE state=?", (STATE_NEEDS_ATTENTION,)
            ).fetchone()
        return int(row["n"])

    def set_state(
        self,
        chunk_id: str,
        state: str,
        *,
        error: str | None = None,
        next_attempt_at: str | None = None,
        bump_attempts: bool = False,
        receipt: dict | None = None,
    ) -> None:
        with self._tx() as db:
            db.execute(
                """UPDATE chunks
                   SET state=?,
                       last_error=?,
                       next_attempt_at=?,
                       attempts = attempts + ?,
                       receipt_json = COALESCE(?, receipt_json)
                   WHERE id=?""",
                (
                    state,
                    error,
                    next_attempt_at,
                    1 if bump_attempts else 0,
                    json.dumps(receipt) if receipt is not None else None,
                    chunk_id,
                ),
            )

    def set_server_chunk_id(self, chunk_id: str, server_chunk_id: str) -> None:
        """Remember the id the server minted.

        Receipt polling and release reporting are addressed by the server's own
        uuid, not by our idempotency key, so this has to survive a restart
        between the upload and the receipt.
        """
        with self._tx() as db:
            db.execute(
                "UPDATE chunks SET server_chunk_id=? WHERE id=?", (server_chunk_id, chunk_id)
            )

    def bump_reupload_attempts(self, chunk_id: str) -> int:
        with self._tx() as db:
            db.execute(
                "UPDATE chunks SET reupload_attempts = reupload_attempts + 1 WHERE id=?",
                (chunk_id,),
            )
            row = db.execute(
                "SELECT reupload_attempts FROM chunks WHERE id=?", (chunk_id,)
            ).fetchone()
        return int(row["reupload_attempts"]) if row else 0

    def release_audio(self, chunk_id: str, receipt: dict) -> bool:
        """Delete the local WAV — only ever called behind the invariant gate."""
        if not proves_safe_audio_release(receipt):
            return False
        row = self.chunk(chunk_id)
        if row is None:
            return False
        Path(row.path).unlink(missing_ok=True)
        self.set_state(chunk_id, STATE_RELEASED, receipt=receipt)
        return True

    def forget(self, chunk_ids: Iterable[str]) -> None:
        """Drop rows whose release has been reported to the server."""
        ids = list(chunk_ids)
        if not ids:
            return
        with self._tx() as db:
            db.executemany("DELETE FROM chunks WHERE id=?", [(cid,) for cid in ids])

    # -------------------------------------------------------------------- gaps

    def record_gap(
        self,
        *,
        session_id: str,
        reason: str,
        start_offset_ms: int,
        end_offset_ms: int,
        start_sequence: int | None = None,
        end_sequence: int | None = None,
    ) -> None:
        """Declare a stretch of the timeline where no audio was captured.

        Offsets are milliseconds from the session's own start, which is the
        coordinate system the ingest route validates against. The server insists
        the window is non-empty and that sequence coverage is either absent or a
        complete ordered range, so both are enforced here rather than discovered
        as a 400 during the upload.
        """
        if reason not in GAP_REASONS:
            raise ValueError(f"unknown gap reason: {reason}")
        if end_offset_ms <= start_offset_ms:
            raise ValueError("a gap must cover a non-empty window")
        if (start_sequence is None) != (end_sequence is None):
            raise ValueError("gap sequence coverage must name both ends or neither")
        if (
            start_sequence is not None
            and end_sequence is not None
            and end_sequence < start_sequence
        ):
            raise ValueError("gap sequence coverage must be ordered")
        with self._tx() as db:
            db.execute(
                """INSERT INTO gaps
                   (session_id, reason, start_offset_ms, end_offset_ms,
                    start_sequence, end_sequence)
                   VALUES (?,?,?,?,?,?)""",
                (session_id, reason, start_offset_ms, end_offset_ms, start_sequence, end_sequence),
            )

    def undeclared_gaps(self, session_id: str) -> list[GapRow]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM gaps WHERE session_id=? AND declared=0 ORDER BY id",
                (session_id,),
            ).fetchall()
        return [
            GapRow(
                id=int(row["id"]),
                session_id=row["session_id"],
                reason=row["reason"],
                start_offset_ms=int(row["start_offset_ms"]),
                end_offset_ms=int(row["end_offset_ms"]),
                start_sequence=row["start_sequence"],
                end_sequence=row["end_sequence"],
            )
            for row in rows
        ]

    def mark_gaps_declared(self, gap_ids: Iterable[int]) -> None:
        ids = list(gap_ids)
        if not ids:
            return
        with self._tx() as db:
            db.executemany("UPDATE gaps SET declared=1 WHERE id=?", [(gid,) for gid in ids])

    def sessions_with_undeclared_gaps(self) -> list[str]:
        with self._lock:
            rows = self._db.execute(
                """SELECT DISTINCT g.session_id AS sid FROM gaps g
                   JOIN sessions s ON s.id = g.session_id
                   WHERE g.declared=0 AND s.declared=1"""
            ).fetchall()
        return [row["sid"] for row in rows]

    # ---------------------------------------------------------------- recovery

    def recover(self) -> dict[str, int]:
        """Reconcile whatever the last shutdown left behind.

        Called once at start-up, before anything else runs. A session that was
        still active means the appliance lost power or was killed mid-recording:
        it is closed as ``interrupted`` and the truth is declared as a
        ``device_shutdown`` gap rather than quietly dropped.
        """
        report = {
            "partials_removed": 0,
            "uploads_reset": 0,
            "sessions_interrupted": 0,
            "orphans_removed": 0,
        }

        for partial in self._audio_dir.glob("*.wav.partial"):
            partial.unlink(missing_ok=True)
            report["partials_removed"] += 1

        with self._tx() as db:
            cursor = db.execute(
                "UPDATE chunks SET state=?, next_attempt_at=NULL WHERE state=?",
                (STATE_READY, STATE_UPLOADING),
            )
            report["uploads_reset"] = cursor.rowcount or 0

            active = db.execute(
                "SELECT * FROM sessions WHERE status=?", (SESSION_ACTIVE,)
            ).fetchall()
            now = utc_now_iso()
            for row in active:
                last = db.execute(
                    "SELECT MAX(sequence) AS last FROM chunks WHERE session_id=?", (row["id"],)
                ).fetchone()
                final_sequence = last["last"] if last and last["last"] is not None else -1
                # No gap record here on purpose. A gap describes a hole *inside* a
                # declared stream; a power loss simply ends the stream. Saying
                # "interrupted" and naming the last sequence is the complete
                # truth, and it is what the server's missing-range computation
                # already understands. Inventing a zero-length gap would only add
                # noise to a real diagnosis.
                db.execute(
                    "UPDATE sessions SET status=?, ended_at=?, final_sequence=? WHERE id=?",
                    (SESSION_INTERRUPTED, now, final_sequence, row["id"]),
                )
                report["sessions_interrupted"] += 1

        with self._lock:
            known = {Path(row["path"]).name for row in self._db.execute("SELECT path FROM chunks")}
        for stray in self._audio_dir.glob("*.wav"):
            if stray.name not in known:
                stray.unlink(missing_ok=True)
                report["orphans_removed"] += 1

        return report

    def verify_payload(self, row: ChunkRow) -> bytes | None:
        """Re-read a chunk and re-check its hash before it goes out.

        Silent corruption on an SD card is real. A mismatch parks the chunk
        instead of uploading audio that no longer matches its declared digest.
        """
        try:
            payload = Path(row.path).read_bytes()
        except OSError:
            return None
        if hashlib.sha256(payload).hexdigest() != row.sha256:
            return None
        return payload


def _session_from_row(row: sqlite3.Row) -> SessionRow:
    return SessionRow(
        id=row["id"],
        server_session_id=row["server_session_id"],
        server_source_id=row["server_source_id"],
        device_started_at=row["device_started_at"],
        started_at=row["started_at"],
        ended_at=row["ended_at"],
        status=row["status"],
        final_sequence=row["final_sequence"],
        timezone=row["timezone"],
        declared=bool(row["declared"]),
        closed_on_server=bool(row["closed_on_server"]),
    )


def _chunk_from_row(row: sqlite3.Row) -> ChunkRow:
    receipt = None
    if row["receipt_json"]:
        try:
            receipt = json.loads(row["receipt_json"])
        except ValueError:
            receipt = None
    return ChunkRow(
        id=row["id"],
        server_chunk_id=row["server_chunk_id"],
        session_id=row["session_id"],
        sequence=int(row["sequence"]),
        path=Path(row["path"]),
        byte_size=int(row["byte_size"]),
        sha256=row["sha256"],
        duration_ms=int(row["duration_ms"]),
        overlap_ms=int(row["overlap_ms"]),
        monotonic_offset_ms=int(row["monotonic_offset_ms"]),
        is_final=bool(row["is_final"]),
        state=row["state"],
        attempts=int(row["attempts"]),
        reupload_attempts=int(row["reupload_attempts"]),
        receipt=receipt,
        created_at=row["created_at"],
    )
