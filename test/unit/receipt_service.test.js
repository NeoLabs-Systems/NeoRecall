'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-receipt-'));
process.env.NEORECALL_REQUIRE_VECTOR = 'true';
const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const receipts = require('../../server/services/ingest/receipt_service');

test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('terminal receipt cannot be issued before persistence and unlink', () => {
  const db = getDatabase(); migrate(db);
  const user = crypto.randomUUID(); const device = crypto.randomUUID(); const session = crypto.randomUUID(); const source = crypto.randomUUID(); const chunk = crypto.randomUUID();
  db.prepare("INSERT INTO users(id,username,password_hash) VALUES (?,?,'x')").run(user, 'receipt-user');
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(device, user, device);
  db.prepare("INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status) VALUES (?,?,?,?,?,?, 'UTC',?,'active')").run(session, user, device, session, '2026-07-13T00:00:00Z', '2026-07-13T00:00:00Z', '2026-07-13T00:00:00Z');
  db.prepare("INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')").run(source, session, source);
  db.prepare("INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,temporary_path) VALUES (?,?,?,?,0,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'wav','pcm_s16le','mono','2026-07-13T00:00:00Z',0,1000,'uploaded','/tmp/audio')").run(chunk, user, session, source, chunk);
  assert.throws(() => receipts.completeTerminal(db, chunk, 'transcribed'), /persisted transcript state/);
});

test('nonterminal receipts use observed throughput for a queue ETA', () => {
  const db = getDatabase();
  const chunk = db.prepare("SELECT id FROM audio_chunks WHERE state='uploaded' LIMIT 1").get().id;
  const user = db.prepare('SELECT user_id FROM audio_chunks WHERE id=?').get(chunk).user_id;
  const job = crypto.randomUUID();
  db.prepare(`INSERT INTO jobs
    (id,user_id,resource_type,resource_id,type,status,priority,max_attempts)
    VALUES (?,?,'audio_chunk',?,'transcribe_chunk','queued',0,3)`)
    .run(job, user, chunk);
  db.prepare(`INSERT INTO processing_metrics
    (job_id,user_id,metric,value,unit)
    VALUES (?,?, 'transcription_pipeline_rtf',0.5,'ratio')`)
    .run(job, user);

  const receipt = receipts.receipt(
    db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunk),
  );

  assert.equal(receipt.queuePosition, 0);
  assert.equal(receipt.estimatedRemainingMs, 500);
  assert.equal(receipt.estimateBasis, 'observed_transcription_rtf');
});
