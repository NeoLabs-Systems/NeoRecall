'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { sha256File } = require('../../utils/crypto');
const jobs = require('../../services/jobs/job_service');

// A whole day of audio decodes to thousands of segments, so nothing here may
// read a segment's samples: only the RIFF header is needed, and the header lives
// in the first few hundred bytes.
const WAV_HEADER_BYTES = 4096;
const WAV_HEADER_MAX_BYTES = 1024 * 1024;

function readHead(filename, length) {
  const buffer = Buffer.allocUnsafe(length);
  const handle = fs.openSync(filename, 'r');
  try {
    return buffer.subarray(0, fs.readSync(handle, buffer, 0, length, 0));
  } finally {
    fs.closeSync(handle);
  }
}

function parseWavHeader(bytes) {
  if (bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') throw Object.assign(new Error('Segmented import is not a WAV file.'), { code: 'IMPORT_SEGMENT_INVALID' });
  let offset = 12; let byteRate; let dataSize;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4); const size = bytes.readUInt32LE(offset + 4);
    // The head may end mid-chunk, so a field that is not fully present makes the
    // parse inconclusive rather than an out-of-range read.
    if (id === 'fmt ') {
      if (offset + 20 > bytes.length) return null;
      byteRate = bytes.readUInt32LE(offset + 16);
    }
    if (id === 'data') { dataSize = size; break; }
    offset += 8 + size + (size % 2);
  }
  return byteRate && dataSize !== undefined ? Math.round(dataSize / byteRate * 1000) : null;
}

function wavDurationMs(filename) {
  // Metadata chunks ahead of the samples are unusual but legal, so a short head
  // that did not reach the data chunk is retried with a larger one before the
  // file is rejected. Neither read is proportional to the audio length.
  for (const length of [WAV_HEADER_BYTES, WAV_HEADER_MAX_BYTES]) {
    const durationMs = parseWavHeader(readHead(filename, length));
    if (durationMs !== null) return durationMs;
  }
  throw Object.assign(new Error('WAV metadata is incomplete.'), { code: 'IMPORT_SEGMENT_INVALID' });
}

function importDevice(db, userId, deviceId) {
  if (deviceId) return deviceId;
  const existing = db.prepare("SELECT id FROM devices WHERE user_id=? AND kind='import' AND client_uuid='neorecall-import-service'").get(userId);
  if (existing) return existing.id;
  const id = crypto.randomUUID();
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,'neorecall-import-service','Audio imports','server','import')").run(id, userId);
  return id;
}

/// Places an import on the timeline, continuing the previous one when it is the
/// next stretch of the same recording.
///
/// A wearable with on-board storage is drained over and over — every few seconds
/// while it is connected — and each sweep arrives here as a separate file. Given
/// its own session each file would become its own conversation stream, and
/// nothing downstream is allowed to merge across streams: refinement rejects a
/// section that mixes them, precisely so unrelated recordings never fuse. One
/// meeting would end up as one memory per sweep.
///
/// So a new import extends the previous import session of the same device when
/// their audio is contiguous, and starts a fresh session when it is not. A
/// device that timestamps its files is placed by those timestamps; one that does
/// not is assumed to continue seamlessly where the previous sweep ended, which
/// is what a drained ring buffer actually is.
function placement(db, userId, deviceId, record) {
  const gapMs = getConfig().importSessionContinuityMs;
  // Only an import that names its device can continue a stream. Imports without
  // one all share a synthetic device, so continuing there would splice a
  // hand-uploaded file onto whatever a wearable happened to sync just before it.
  const previous = gapMs && record.device_id ? db.prepare(`SELECT s.* FROM recording_sessions s
    WHERE s.user_id=? AND s.device_id=?
      AND EXISTS (SELECT 1 FROM recording_sources src WHERE src.session_id=s.id AND src.kind='import')
    ORDER BY s.corrected_ended_at DESC LIMIT 1`).get(userId, deviceId) : null;
  const fresh = { session: null, startedAt: record.capture_time || record.created_at };
  if (!previous) return fresh;
  const previousEndMs = Date.parse(previous.corrected_ended_at);
  if (!Number.isFinite(previousEndMs)) return fresh;
  if (record.capture_time) {
    const startMs = Date.parse(record.capture_time);
    // A file that starts before the previous one ended is not a continuation:
    // it was drained out of order, or belongs to an older recording.
    if (!Number.isFinite(startMs) || startMs + 1_000 < previousEndMs || startMs - previousEndMs > gapMs) return fresh;
    return { session: previous, startedAt: new Date(Math.max(startMs, previousEndMs)).toISOString() };
  }
  if (Date.now() - previousEndMs > gapMs) return fresh;
  return { session: previous, startedAt: previous.corrected_ended_at };
}

async function handle(job) {
  const db = getDatabase();
  const record = db.prepare("SELECT * FROM imports WHERE id=? AND user_id=? AND state='assembled'").get(job.resource_id, job.user_id);
  if (!record) return { skipped: true };
  const workDirectory = path.join(ensureRuntimeDirs().audioTmp, `import-${record.id}`);
  fs.mkdirSync(workDirectory, { mode: 0o700 });
  const pattern = path.join(workDirectory, 'chunk-%08d.wav');
  const result = spawnSync(ffmpegPath, ['-v', 'error', '-i', record.temporary_path, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
    '-f', 'segment', '-segment_time', String(getConfig().chunkTargetMs / 1000), '-reset_timestamps', '1', pattern], { encoding: 'utf8' });
  if (result.status !== 0) throw Object.assign(new Error(`Import decode failed: ${result.stderr.slice(0, 500)}`), { code: 'IMPORT_DECODE_FAILED' });
  const files = fs.readdirSync(workDirectory).filter((name) => name.endsWith('.wav')).sort().map((name) => path.join(workDirectory, name));
  if (!files.length) throw Object.assign(new Error('Import contained no decodable audio.'), { code: 'IMPORT_EMPTY' });
  const sourceId = crypto.randomUUID();
  const createdFiles = [];
  // Measured once: a multi-hour import produces thousands of segments, and the
  // session end needs the same durations the chunk rows do.
  const durations = files.map(wavDurationMs);
  const totalDurationMs = durations.reduce((sum, durationMs) => sum + durationMs, 0);
  let sessionId;
  try {
    db.transaction(() => {
      const deviceId = importDevice(db, record.user_id, record.device_id);
      const placed = placement(db, record.user_id, deviceId, record);
      const startedAt = placed.startedAt;
      const endedAt = new Date(Date.parse(startedAt) + totalDurationMs).toISOString();
      // Segment times are derived from the session start plus each chunk's
      // monotonic offset, so a continued session numbers its offsets from that
      // same origin rather than restarting at zero.
      const sessionStartMs = placed.session ? Date.parse(placed.session.corrected_started_at) : Date.parse(startedAt);
      let offsetMs = Date.parse(startedAt) - sessionStartMs;
      if (placed.session) {
        sessionId = placed.session.id;
        db.prepare(`UPDATE recording_sessions SET device_ended_at=?,corrected_ended_at=?,
          updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(endedAt, endedAt, sessionId);
      } else {
        sessionId = crypto.randomUUID();
        db.prepare(`INSERT INTO recording_sessions
          (id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
          VALUES (?,?,?,?,?,?,?,?,?,?,'ended')`).run(sessionId, record.user_id, deviceId, `import-${record.id}`, startedAt,
          endedAt, startedAt, endedAt, record.timezone || 'UTC', record.created_at);
      }
      db.prepare(`INSERT INTO recording_sources
        (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,closed_at,metadata_json)
        VALUES (?,?,?,'import','mono',16000,'pcm_s16le',?,?,?)`).run(sourceId, sessionId, `import-source-${record.id}`, files.length - 1, new Date().toISOString(), JSON.stringify({ importId: record.id, originalName: record.original_name }));
      files.forEach((file, sequence) => {
        const durationMs = durations[sequence]; const chunkId = crypto.randomUUID();
        const destination = path.join(ensureRuntimeDirs().audioTmp, `${chunkId}.wav`); fs.renameSync(file, destination);
        createdFiles.push(destination);
        db.prepare(`INSERT INTO audio_chunks
          (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,
           monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path)
          VALUES (?,?,?,?,?,?,?,?,?,'pcm_s16le','mono',?,?,?,0,'uploaded',?)`).run(chunkId, record.user_id, sessionId, sourceId, sequence,
          `import:${record.id}:${sequence}`, sha256File(destination), fs.statSync(destination).size, 'wav',
          new Date(sessionStartMs + offsetMs).toISOString(), offsetMs, Math.max(1, durationMs), destination);
        jobs.enqueue({ userId: record.user_id, resourceType: 'audio_chunk', resourceId: chunkId, type: 'transcribe_chunk', priority: 70 }, db);
        offsetMs += durationMs;
      });
      db.prepare("UPDATE imports SET state='processing',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(record.id);
    })();
    fs.rmSync(workDirectory, { recursive: true, force: true });
    return { sessionId, sourceId, chunks: files.length };
  } catch (error) {
    for (const filename of createdFiles) { try { fs.unlinkSync(filename); } catch (_) {} }
    fs.rmSync(workDirectory, { recursive: true, force: true });
    db.prepare("UPDATE imports SET state='failed',error_code=?,expires_at=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
      .run(error.code || 'IMPORT_PROCESSING_FAILED', new Date(Date.now() + getConfig().importFailedTtlHours * 60 * 60_000).toISOString(), record.id);
    throw error;
  }
}

module.exports = { handle, wavDurationMs };
