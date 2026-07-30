'use strict';

const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { sha256 } = require('../../utils/crypto');
const jobs = require('../jobs/job_service');
const receipts = require('./receipt_service');
const tempAudio = require('./temp_audio_service');

function ownedSession(userId, sessionId) {
  const row = getDatabase().prepare('SELECT * FROM recording_sessions WHERE id=? AND user_id=?').get(sessionId, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Recording session not found.');
  return row;
}

function ownedSource(userId, sessionId, sourceId) {
  const row = getDatabase().prepare(`SELECT s.* FROM recording_sources s JOIN recording_sessions r ON r.id=s.session_id
    WHERE s.id=? AND s.session_id=? AND r.user_id=?`).get(sourceId, sessionId, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Recording source not found.');
  return row;
}

function correctedTime(deviceIso, offsetMs) {
  const timestamp = Date.parse(deviceIso);
  if (!Number.isFinite(timestamp)) throw new HttpError(400, 'INVALID_TIMESTAMP', 'A device timestamp is invalid.');
  return new Date(timestamp - (offsetMs || 0)).toISOString();
}

function createSession(userId, input) {
  const db = getDatabase();
  const device = db.prepare('SELECT * FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL').get(input.deviceId, userId);
  if (!device) throw new HttpError(404, 'NOT_FOUND', 'Device not found.');
  const existing = db.prepare('SELECT * FROM recording_sessions WHERE user_id=? AND client_uuid=?').get(userId, input.clientUuid);
  if (existing) return { session: existing, sources: db.prepare('SELECT * FROM recording_sources WHERE session_id=?').all(existing.id) };
  const id = input.id || crypto.randomUUID();
  const offset = Number.isFinite(input.clockOffsetMs) ? input.clockOffsetMs : device.clock_offset_ms || 0;
  const sources = input.sources.map((source) => ({ ...source, id: source.id || crypto.randomUUID() }));
  db.transaction(() => {
    db.prepare(`INSERT INTO recording_sessions
      (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,initial_clock_offset_ms,consent_attested_at,status)
      VALUES (?,?,?,?,?,?,?,?,?,'active')`).run(id, userId, input.deviceId, input.clientUuid, input.startedAt,
        correctedTime(input.startedAt, offset), input.timezone, offset, input.consentAttestedAt);
    const insert = db.prepare(`INSERT INTO recording_sources
      (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,metadata_json)
      VALUES (?,?,?,?,?,?,?,?)`);
    for (const source of sources) insert.run(source.id, id, source.clientUuid, source.kind, source.channelLayout,
      source.sampleRate, source.sampleFormat, JSON.stringify(source.metadata || {}));
  })();
  return { session: db.prepare('SELECT * FROM recording_sessions WHERE id=?').get(id), sources };
}

function addSource(userId, sessionId, input) {
  const session = ownedSession(userId, sessionId);
  if (session.status !== 'active') throw new HttpError(409, 'SESSION_CLOSED', 'The recording session is closed.');
  const db = getDatabase();
  const existing = db.prepare('SELECT * FROM recording_sources WHERE session_id=? AND client_uuid=?').get(sessionId, input.clientUuid);
  if (existing) return existing;
  const id = input.id || crypto.randomUUID();
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,metadata_json)
    VALUES (?,?,?,?,?,?,?,?)`).run(id, sessionId, input.clientUuid, input.kind, input.channelLayout, input.sampleRate, input.sampleFormat, JSON.stringify(input.metadata || {}));
  return db.prepare('SELECT * FROM recording_sources WHERE id=?').get(id);
}

function closeSource(userId, sessionId, sourceId, finalSequence) {
  ownedSource(userId, sessionId, sourceId);
  getDatabase().prepare(`UPDATE recording_sources SET final_sequence=?,closed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(finalSequence, sourceId);
  return syncState(userId, sessionId);
}

function closeSession(userId, sessionId, input) {
  const session = ownedSession(userId, sessionId);
  const offset = session.initial_clock_offset_ms || 0;
  const status = input.status || 'ended';
  getDatabase().transaction(() => {
    for (const source of input.sources || []) closeSource(userId, sessionId, source.id, source.finalSequence);
    getDatabase().prepare(`UPDATE recording_sessions SET device_ended_at=?,corrected_ended_at=?,status=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(input.endedAt, correctedTime(input.endedAt, offset), status, sessionId);
  })();
  return ownedSession(userId, sessionId);
}

function addGaps(userId, sessionId, gaps) {
  ownedSession(userId, sessionId);
  const db = getDatabase();
  db.transaction(() => {
    const insert = db.prepare(`INSERT INTO recording_gaps
      (id,session_id,source_id,start_offset_ms,end_offset_ms,start_sequence,end_sequence,reason)
      VALUES (?,?,?,?,?,?,?,?)`);
    for (const gap of gaps) {
      ownedSource(userId, sessionId, gap.sourceId);
      insert.run(gap.id || crypto.randomUUID(), sessionId, gap.sourceId, gap.startOffsetMs, gap.endOffsetMs,
        gap.startSequence ?? null, gap.endSequence ?? null, gap.reason);
    }
  })();
}

function fileSha256(filename) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filename);
    stream.on('data', (data) => hash.update(data));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function metadataMatches(existing, input, actualHash, byteSize) {
  return existing.sha256 === actualHash && existing.byte_size === byteSize && existing.duration_ms === input.durationMs &&
    existing.overlap_ms === input.overlapMs && existing.channel_layout === input.channelLayout &&
    existing.monotonic_offset_ms === input.monotonicOffsetMs;
}

async function acceptChunk(userId, sessionId, sourceId, sequence, input, uploadedFile) {
  if (!uploadedFile) throw new HttpError(400, 'AUDIO_REQUIRED', 'The audio field is required.');
  try {
    const source = ownedSource(userId, sessionId, sourceId);
    if (source.closed_at && source.final_sequence !== null && sequence > source.final_sequence) throw new HttpError(409, 'SOURCE_CLOSED', 'The sequence is beyond the closed source.');
    const config = getConfig();
    if (input.durationMs > config.chunkMaxMs || input.durationMs < (input.isFinal ? 1 : config.chunkMinMs)) throw new HttpError(400, 'INVALID_DURATION', 'Chunk duration is outside the configured range.');
    const actualHash = await fileSha256(uploadedFile.path);
    if (actualHash !== input.sha256) throw new HttpError(422, 'HASH_MISMATCH', 'The uploaded audio does not match X-Chunk-Sha256.');
    const db = getDatabase();
    const bySequence = db.prepare('SELECT * FROM audio_chunks WHERE source_id=? AND sequence=?').get(sourceId, sequence);
    const byKey = db.prepare('SELECT * FROM audio_chunks WHERE user_id=? AND idempotency_key=?').get(userId, input.idempotencyKey);
    const existing = bySequence || byKey;
    if (existing) {
      if (existing.source_id !== sourceId || existing.sequence !== sequence || existing.idempotency_key !== input.idempotencyKey ||
          !metadataMatches(existing, input, actualHash, uploadedFile.size)) {
        throw new HttpError(409, 'IDEMPOTENCY_CONFLICT', 'This sequence or idempotency key was already used with different content or metadata.');
      }
      if (existing.state !== 'reupload_required') return { ...receipts.receipt(existing), duplicate: true };
      const destination = tempAudio.chunkPath(existing.id, input.container);
      fs.renameSync(uploadedFile.path, destination);
      try {
        db.transaction(() => {
          db.prepare(`UPDATE audio_chunks SET temporary_path=?,state='uploaded',error_code=NULL,error_message=NULL,
            uploaded_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(destination, existing.id);
          jobs.enqueue({ userId, resourceType: 'audio_chunk', resourceId: existing.id, type: 'transcribe_chunk', priority: 100 }, db);
        })();
      } catch (error) {
        // Mirror the new-chunk path: never leave the renamed audio orphaned if
        // the durable state transition fails.
        tempAudio.unlinkStrict(destination);
        throw error;
      }
      return receipts.findForUser(userId, existing.id);
    }
    const id = crypto.randomUUID();
    const destination = tempAudio.chunkPath(id, input.container);
    fs.renameSync(uploadedFile.path, destination);
    try {
      db.transaction(() => {
        db.prepare(`INSERT INTO audio_chunks
          (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
           device_started_at,monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'uploaded',?)`).run(id, userId, sessionId, sourceId, sequence, input.idempotencyKey,
          actualHash, uploadedFile.size, input.container, input.codec, input.channelLayout, input.deviceStartedAt,
          input.monotonicOffsetMs, input.durationMs, input.overlapMs, destination);
        jobs.enqueue({ userId, resourceType: 'audio_chunk', resourceId: id, type: 'transcribe_chunk', priority: 100 }, db);
        db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
          VALUES (?,'chunk.uploaded','audio_chunk',?,?,?)`).run(userId, id, JSON.stringify({ chunkId: id, sourceId, sequence, state: 'uploaded' }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
      })();
    } catch (error) {
      tempAudio.unlinkStrict(destination);
      throw error;
    }
    return receipts.findForUser(userId, id);
  } finally {
    if (uploadedFile.path && fs.existsSync(uploadedFile.path)) tempAudio.unlinkStrict(uploadedFile.path);
  }
}

function status(userId, chunkIds) {
  const select = getDatabase().prepare('SELECT * FROM audio_chunks WHERE id=? AND user_id=?');
  return chunkIds.map((id) => select.get(id, userId)).filter(Boolean).map(receipts.receipt);
}

function released(userId, chunkIds) {
  const db = getDatabase();
  return db.transaction(() => chunkIds.reduce((count, id) => count + db.prepare(`UPDATE audio_chunks SET
    client_released_at=COALESCE(client_released_at,strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE id=? AND user_id=? AND state IN ('transcribed','silent')`).run(id, userId).changes, 0))();
}

function missingRanges(rows, finalSequence, gaps = []) {
  if (finalSequence === null || finalSequence === undefined) return [];
  const known = new Set(rows.map((row) => row.sequence));
  for (const gap of gaps) {
    if (gap.start_sequence === null || gap.end_sequence === null) continue;
    for (let sequence = gap.start_sequence; sequence <= gap.end_sequence; sequence += 1) known.add(sequence);
  }
  const ranges = [];
  let start = null;
  for (let i = 0; i <= finalSequence; i += 1) {
    if (!known.has(i) && start === null) start = i;
    if ((known.has(i) || i === finalSequence) && start !== null) {
      const end = known.has(i) ? i - 1 : i;
      ranges.push({ start, end });
      start = null;
    }
  }
  return ranges;
}

function syncState(userId, sessionId) {
  ownedSession(userId, sessionId);
  const db = getDatabase();
  const sources = db.prepare('SELECT * FROM recording_sources WHERE session_id=? ORDER BY created_at').all(sessionId);
  return {
    sessionId,
    sources: sources.map((source) => {
      const chunks = db.prepare('SELECT * FROM audio_chunks WHERE source_id=? ORDER BY sequence').all(source.id);
      const gaps = db.prepare('SELECT * FROM recording_gaps WHERE source_id=? ORDER BY start_offset_ms').all(source.id);
      return { sourceId: source.id, finalSequence: source.final_sequence, missingRanges: missingRanges(chunks, source.final_sequence, gaps), gaps, receipts: chunks.map(receipts.receipt) };
    }),
  };
}

module.exports = { createSession, addSource, closeSource, closeSession, addGaps, acceptChunk, status, released, syncState };
