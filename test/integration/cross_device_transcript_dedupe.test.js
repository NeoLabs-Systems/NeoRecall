'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-cross-device-dedupe-'));
const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const transcribe = require('../../server/workers/handlers/transcribe_handler');

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

function recording(db, { userId, deviceId, sessionId, sourceId, platform }) {
  db.prepare(`INSERT OR IGNORE INTO devices
    (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,?,?,'desktop')`)
    .run(deviceId, userId, deviceId, platform, platform);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?,'active')`)
    .run(sessionId, userId, deviceId, sessionId, '2026-08-24T10:00:00.000Z',
      '2026-08-24T10:00:00.000Z', 'UTC', '2026-08-24T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')`).run(sourceId, sessionId, sourceId);
  const chunkId = crypto.randomUUID();
  const temporaryPath = path.join(process.env.NEORECALL_HOME, `${chunkId}.wav`);
  fs.writeFileSync(temporaryPath, Buffer.from('audio'));
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,overlap_ms,state,temporary_path)
    VALUES (?,?,?,?,0,?, ?,1,'wav','pcm_s16le','mono','2026-08-24T10:00:00.000Z',0,30000,0,'uploaded',?)`)
    .run(chunkId, userId, sessionId, sourceId, crypto.randomUUID(), crypto.randomBytes(32).toString('hex'), temporaryPath);
  return db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
}

const inference = [{
  text: 'Deploy the release.',
  language: 'en',
  startMs: 1000,
  endMs: 2500,
  sourceComponent: 'combined',
  asrConfidence: 0.9,
  speakerEmbedding: null,
  overlappingSpeech: false,
}];

test('only a timestamp-matched exact transcript from another device is suppressed', () => {
  migrate();
  const db = getDatabase();
  const userId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash,role) VALUES (?,?,?,'user')")
    .run(userId, `cross-device-${userId}`, 'unused');
  const macDeviceId = crypto.randomUUID();

  const firstMac = recording(db, {
    userId, deviceId: macDeviceId, sessionId: crypto.randomUUID(), sourceId: crypto.randomUUID(), platform: 'macos',
  });
  assert.equal(transcribe.persistSegments(firstMac, inference), 1);

  // Separate sessions on one physical client are not cross-device evidence.
  const restartedMac = recording(db, {
    userId, deviceId: macDeviceId, sessionId: crypto.randomUUID(), sourceId: crypto.randomUUID(), platform: 'macos',
  });
  assert.equal(transcribe.persistSegments(restartedMac, inference), 1);

  const phone = recording(db, {
    userId, deviceId: crypto.randomUUID(), sessionId: crypto.randomUUID(), sourceId: crypto.randomUUID(), platform: 'android',
  });
  assert.equal(transcribe.persistSegments(phone, inference), 0);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM transcript_segments WHERE user_id=?').get(userId).count, 2);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM transcript_segments WHERE chunk_id=?').get(phone.id).count, 0);
  const receipt = transcribe.finishCleanup(phone, 0);
  assert.equal(receipt.state, 'silent');
  assert.ok(receipt.persistedAt);
  assert.ok(receipt.serverAudioDeletedAt);
  assert.equal(fs.existsSync(phone.temporary_path), false);
});
