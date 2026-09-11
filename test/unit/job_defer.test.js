'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-defer-'));

const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { getDatabase } = require('../../server/db/database');
const jobs = require('../../server/services/jobs/job_service');

const db = getDatabase();

function seedChunk() {
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  const tempPath = path.join(process.env.NEORECALL_HOME, `${chunkId}.wav`);
  fs.writeFileSync(tempPath, 'audio');
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(userId, `u-${userId.slice(0, 8)}`, 'hash');
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'D','test','desktop')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'ended')`)
    .run(sessionId, userId, deviceId, sessionId, '2026-09-11T10:00:00.000Z', '2026-09-11T10:00:00.000Z', '2026-09-11T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,-1)`).run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,temporary_path)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono','2026-09-11T10:00:00.000Z',0,30000,'processing',?)`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, 'a'.repeat(64), tempPath);
  return { userId, chunkId, tempPath };
}

test('defer returns a leased job to queued without burning an attempt', () => {
  const { userId, chunkId } = seedChunk();
  const jobId = jobs.enqueue({
    userId, resourceType: 'audio_chunk', resourceId: chunkId, type: 'transcribe_chunk', priority: 100,
  });
  const workerId = 'worker-1';
  const leased = jobs.claimNext(workerId);
  assert.equal(leased.id, jobId);
  assert.equal(leased.attempts, 1);
  const retryAt = new Date(Date.now() + 3_600_000).toISOString();
  assert.equal(jobs.defer(jobId, workerId, retryAt), true);
  const row = db.prepare('SELECT * FROM jobs WHERE id=?').get(jobId);
  assert.equal(row.status, 'queued');
  assert.equal(row.attempts, 0);
  assert.equal(row.lease_owner, null);
  assert.equal(row.last_error_code, 'USAGE_LIMIT_EXCEEDED');
  assert.ok(Date.parse(row.next_attempt_at) >= Date.parse(retryAt) - 1000);
});

test('deferring a transcription job leaves the server audio copy in place', () => {
  const { userId, chunkId, tempPath } = seedChunk();
  const jobId = jobs.enqueue({
    userId, resourceType: 'audio_chunk', resourceId: chunkId, type: 'transcribe_chunk',
  });
  const leased = jobs.claimNext('worker-2');
  assert.equal(leased.id, jobId);
  jobs.defer(jobId, 'worker-2', new Date(Date.now() + 60_000).toISOString());
  const chunk = db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
  assert.equal(chunk.state, 'processing');
  assert.equal(chunk.temporary_path, tempPath);
  assert.equal(fs.existsSync(tempPath), true);
});
