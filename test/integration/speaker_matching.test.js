'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-matching-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const matching = require('../../server/transcription/speaker_matching');

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

function vector(values) { return new Float32Array(values); }
function bytes(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }

test('a session speaker cluster keeps its established voiceprint when global matching becomes ambiguous', () => {
  const db = getDatabase();
  migrate(db);
  const userId = crypto.randomUUID(); const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID(); const chunkId = crypto.randomUUID(); const clusterId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `speaker-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId,
    '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z');
  db.prepare("INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')")
    .run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'wav','pcm_s16le','mono','2026-07-14T10:00:00.000Z',0,30000,'processing')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId);
  const sample = vector([1, 0, 0, 0]);
  db.prepare(`INSERT INTO speaker_clusters
    (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?,1)`).run(clusterId, userId, sessionId, 1, bytes(sample), matching.modelName, sample.length);

  const first = matching.resolveVoiceprint(db, { userId, clusterId, embedding: sample, enabled: true });
  db.prepare(`INSERT INTO speaker_turns
    (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions)
    VALUES (?,?,?,?,?,0,1000,?,?,?)`).run(crypto.randomUUID(), userId, chunkId, clusterId, first.id, bytes(sample), matching.modelName, sample.length);
  db.prepare(`INSERT INTO voiceprints
    (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count) VALUES (?,?,?,?,?,1)`)
    .run(crypto.randomUUID(), userId, bytes(sample), matching.modelName, sample.length);

  const reused = matching.resolveVoiceprint(db, { userId, clusterId, embedding: sample, enabled: true });
  assert.equal(reused.id, first.id);
  assert.equal(db.prepare('SELECT count(*) count FROM voiceprints WHERE user_id=?').get(userId).count, 2);
  assert.equal(db.prepare('SELECT sample_count FROM voiceprints WHERE id=?').get(first.id).sample_count, 2);
});
