'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-crash-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const transcribe = require('../../server/workers/handlers/transcribe_handler');
const tempAudio = require('../../server/services/ingest/temp_audio_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('startup sweep completes a receipt after a crash between transcript commit and unlink', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'crash-user', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id; const db = getDatabase();
  const device = crypto.randomUUID(); const session = crypto.randomUUID(); const source = crypto.randomUUID(); const chunkId = crypto.randomUUID();
  const audio = path.join(process.env.NEORECALL_HOME, 'audio_tmp', `${chunkId}.wav`); fs.writeFileSync(audio, Buffer.from('temporary audio'));
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(device, userId, device);
  db.prepare("INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status) VALUES (?,?,?,?,?,?,'UTC',?,'ended')")
    .run(session, userId, device, session, '2026-07-13T10:00:00.000Z', '2026-07-13T10:00:00.000Z', '2026-07-13T09:59:00.000Z');
  db.prepare("INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0)").run(source, session, source);
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
    device_started_at,monotonic_offset_ms,duration_ms,state,temporary_path) VALUES (?,?,?,?,0,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',15,'wav','pcm_s16le','mono','2026-07-13T10:00:00.000Z',0,16000,'uploaded',?)`)
    .run(chunkId, userId, session, source, chunkId, audio);
  const chunk = db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
  transcribe.persistSegments(chunk, [{ text: 'Durable transcript', language: 'en', startMs: 0, endMs: 1000, sourceComponent: 'combined' }]);
  assert.equal(db.prepare('SELECT state FROM audio_chunks WHERE id=?').get(chunkId).state, 'persisted_cleanup_pending');
  assert.equal(fs.existsSync(audio), true);
  tempAudio.sweep();
  const recovered = db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
  assert.equal(recovered.state, 'transcribed');
  assert.ok(recovered.server_deleted_at);
  assert.equal(recovered.temporary_path, null);
  assert.equal(fs.existsSync(audio), false);
});
