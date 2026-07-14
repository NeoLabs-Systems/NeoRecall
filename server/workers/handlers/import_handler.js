'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { sha256 } = require('../../utils/crypto');
const jobs = require('../../services/jobs/job_service');

function wavDurationMs(filename) {
  const bytes = fs.readFileSync(filename);
  if (bytes.toString('ascii', 0, 4) !== 'RIFF' || bytes.toString('ascii', 8, 12) !== 'WAVE') throw Object.assign(new Error('Segmented import is not a WAV file.'), { code: 'IMPORT_SEGMENT_INVALID' });
  let offset = 12; let byteRate; let dataSize;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4); const size = bytes.readUInt32LE(offset + 4);
    if (id === 'fmt ') byteRate = bytes.readUInt32LE(offset + 16);
    if (id === 'data') { dataSize = size; break; }
    offset += 8 + size + (size % 2);
  }
  if (!byteRate || dataSize === undefined) throw Object.assign(new Error('WAV metadata is incomplete.'), { code: 'IMPORT_SEGMENT_INVALID' });
  return Math.round(dataSize / byteRate * 1000);
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
  const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
  const createdFiles = [];
  let deviceId = record.device_id;
  const startedAt = record.capture_time || record.created_at;
  try {
    db.transaction(() => {
      if (!deviceId) {
        const existing = db.prepare("SELECT id FROM devices WHERE user_id=? AND kind='import' AND client_uuid='neorecall-import-service'").get(record.user_id);
        deviceId = existing?.id || crypto.randomUUID();
        if (!existing) db.prepare(`INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,'neorecall-import-service','Audio imports','server','import')`).run(deviceId, record.user_id);
      }
      db.prepare(`INSERT INTO recording_sessions
        (id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
        VALUES (?,?,?,?,?,?,?,?,?,?,'ended')`).run(sessionId, record.user_id, deviceId, `import-${record.id}`, startedAt,
        new Date(Date.parse(startedAt) + files.reduce((sum, file) => sum + wavDurationMs(file), 0)).toISOString(), startedAt,
        new Date(Date.parse(startedAt) + files.reduce((sum, file) => sum + wavDurationMs(file), 0)).toISOString(), record.timezone || 'UTC', record.created_at);
      db.prepare(`INSERT INTO recording_sources
        (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,closed_at,metadata_json)
        VALUES (?,?,?,'import','mono',16000,'pcm_s16le',?,?,?)`).run(sourceId, sessionId, `import-source-${record.id}`, files.length - 1, new Date().toISOString(), JSON.stringify({ importId: record.id, originalName: record.original_name }));
      let offsetMs = 0;
      files.forEach((file, sequence) => {
        const durationMs = wavDurationMs(file); const bytes = fs.readFileSync(file); const chunkId = crypto.randomUUID();
        const destination = path.join(ensureRuntimeDirs().audioTmp, `${chunkId}.wav`); fs.renameSync(file, destination);
        createdFiles.push(destination);
        db.prepare(`INSERT INTO audio_chunks
          (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,
           monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path)
          VALUES (?,?,?,?,?,?,?,?,?,'pcm_s16le','mono',?,?,?,0,'uploaded',?)`).run(chunkId, record.user_id, sessionId, sourceId, sequence,
          `import:${record.id}:${sequence}`, sha256(bytes), bytes.length, 'wav', new Date(Date.parse(startedAt) + offsetMs).toISOString(), offsetMs, Math.max(1, durationMs), destination);
        jobs.enqueue({ userId: record.user_id, resourceType: 'audio_chunk', resourceId: chunkId, type: 'transcribe_chunk', priority: 70 }, db);
        offsetMs += durationMs;
      });
      db.prepare("UPDATE imports SET state='processing',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(record.id);
    })();
    fs.rmSync(workDirectory, { recursive: true, force: true });
    return { sessionId, chunks: files.length };
  } catch (error) {
    for (const filename of createdFiles) { try { fs.unlinkSync(filename); } catch (_) {} }
    fs.rmSync(workDirectory, { recursive: true, force: true });
    db.prepare("UPDATE imports SET state='failed',error_code=?,expires_at=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
      .run(error.code || 'IMPORT_PROCESSING_FAILED', new Date(Date.now() + getConfig().importFailedTtlHours * 60 * 60_000).toISOString(), record.id);
    throw error;
  }
}

module.exports = { handle, wavDurationMs };
