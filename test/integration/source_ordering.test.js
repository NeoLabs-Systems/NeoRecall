'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-source-order-'));
const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const jobs = require('../../server/services/jobs/job_service');
const ingest = require('../../server/services/ingest/ingest_service');
const transcribe = require('../../server/workers/handlers/transcribe_handler');

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('transcription jobs wait for the previous source sequence to become terminal', () => {
  migrate();
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash,role) VALUES (?,?,'unused','user')").run(userId, `order-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,?,?,'desktop')")
    .run(deviceId, userId, deviceId, 'Ordering test', 'test');
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?,'active')`).run(sessionId, userId, deviceId, sessionId, '2026-07-13T10:00:00.000Z', '2026-07-13T10:00:00.000Z', 'UTC', '2026-07-13T10:00:00.000Z');
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')`).run(sourceId, sessionId, sourceId);
  const insertChunk = db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path)
    VALUES (?,?,?,?,?,?,?,1,'wav','pcm_s16le','mono',?,?,30000,2000,'uploaded',?)`);
  const laterId = crypto.randomUUID();
  insertChunk.run(laterId, userId, sessionId, sourceId, 1, crypto.randomUUID(), '1'.repeat(64), '2026-07-13T10:00:28.000Z', 28000, '/tmp/later.wav');
  jobs.enqueue({ userId, resourceType: 'audio_chunk', resourceId: laterId, type: 'transcribe_chunk', priority: 100 }, db);
  assert.equal(jobs.claimNext('ordering-worker'), null);

  const firstId = crypto.randomUUID();
  insertChunk.run(firstId, userId, sessionId, sourceId, 0, crypto.randomUUID(), '0'.repeat(64), '2026-07-13T10:00:00.000Z', 0, '/tmp/first.wav');
  jobs.enqueue({ userId, resourceType: 'audio_chunk', resourceId: firstId, type: 'transcribe_chunk', priority: 100 }, db);
  const firstJob = jobs.claimNext('ordering-worker');
  assert.equal(firstJob.resource_id, firstId);
  db.prepare("UPDATE audio_chunks SET state='transcribed',temporary_path=NULL WHERE id=?").run(firstId);
  assert.equal(jobs.complete(firstJob.id, 'ordering-worker'), true);
  const laterJob = jobs.claimNext('ordering-worker');
  assert.equal(laterJob.resource_id, laterId);

  const gapSourceId = crypto.randomUUID();
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',1)`).run(gapSourceId, sessionId, gapSourceId);
  const afterGapId = crypto.randomUUID();
  insertChunk.run(afterGapId, userId, sessionId, gapSourceId, 1, crypto.randomUUID(), '2'.repeat(64),
    '2026-07-13T10:00:28.000Z', 28000, '/tmp/after-gap.wav');
  jobs.enqueue({ userId, resourceType: 'audio_chunk', resourceId: afterGapId, type: 'transcribe_chunk', priority: 100 }, db);
  db.prepare(`INSERT INTO recording_gaps
    (id,session_id,source_id,start_offset_ms,end_offset_ms,start_sequence,end_sequence,reason)
    VALUES (?,?,?,0,28000,0,0,'device_shutdown')`).run(crypto.randomUUID(), sessionId, gapSourceId);
  const syncState = ingest.syncState(userId, sessionId).sources.find((source) => source.sourceId === gapSourceId);
  assert.deepEqual(syncState.missingRanges, []);
  const afterGapJob = jobs.claimNext('gap-worker');
  assert.equal(afterGapJob.resource_id, afterGapId);
  db.prepare("UPDATE audio_chunks SET state='transcribed',temporary_path=NULL WHERE id=?").run(afterGapId);
  transcribe.updateContiguous(db, gapSourceId);
  assert.equal(db.prepare('SELECT contiguous_terminal_sequence value FROM recording_sources WHERE id=?').get(gapSourceId).value, 1);
});
