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

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

function vector(values) { return new Float32Array(values); }
function bytes(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }
// Every test below resolves against this fixed query embedding. A cluster
// centroid built with `centroidWithSimilarity(s)` then has cosine similarity to
// the query of exactly `s` — both are unit vectors, so cosine reduces to the
// centroid's first component — letting each scenario state the exact
// similarity it needs instead of picking coordinates and hoping the resulting
// dot product lands where intended.
const QUERY = new Float32Array([1, 0]);
function centroidWithSimilarity(similarity) { return new Float32Array([similarity, Math.sqrt(Math.max(0, 1 - similarity * similarity))]); }

function seedSession(db) {
  const userId = crypto.randomUUID(); const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `speaker-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId,
    '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z');
  return { userId, sessionId };
}

function seedCluster(db, { userId, sessionId, ordinal, embedding }) {
  const clusterId = crypto.randomUUID();
  db.prepare(`INSERT INTO speaker_clusters
    (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?,1)`).run(clusterId, userId, sessionId, ordinal, bytes(embedding), matching.modelName, embedding.length);
  return clusterId;
}

test('a boundary-continuity anchor keeps its cluster despite drift below the plain threshold', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // Cosine 0.55 clears the relaxed continuity threshold (0.5 default) but not
  // the plain clustering threshold (0.65 default): exactly the drift a
  // re-segmented chunk boundary produces for the same continuing speaker.
  const clusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.55) });

  const withoutContinuity = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });
  assert.notEqual(withoutContinuity.id, clusterId, 'without continuity evidence, a below-threshold match still mints a new cluster');

  // resolveCluster above mutated the first cluster's centroid and minted a
  // second one; reseed a clean single cluster for the continuity assertion.
  db.prepare('DELETE FROM speaker_clusters WHERE user_id=?').run(userId);
  const freshClusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.55) });
  const withContinuity = matching.resolveCluster(db, {
    userId, sessionId, embedding: QUERY, continuity: { clusterId: freshClusterId, gapMs: 500 },
  });
  assert.equal(withContinuity.id, freshClusterId, 'a continuity anchor within the gap keeps its cluster at the relaxed threshold');
});

test('continuity breaks a genuine near-tie in favor of the anchor, but yields to a clearly better distinct match', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // Near-tie: the anchor scores 0.60, the other cluster 0.62 — within the
  // default 0.05 margin of each other. Continuity should still keep the anchor.
  const anchorId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.60) });
  seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(0.62) });
  const tieResolved = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: { clusterId: anchorId, gapMs: 200 } });
  assert.equal(tieResolved.id, anchorId, 'a near-tie at the boundary resolves to the continuity anchor, not the marginally closer cluster');

  // Not a near-tie: some other cluster clearly matches better than the anchor.
  // That is what a real speaker change right at the chunk boundary looks like,
  // and continuity must not paper over it.
  db.prepare('DELETE FROM speaker_clusters WHERE user_id=?').run(userId);
  const anchorId2 = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.55) });
  seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(0.90) });
  const changed = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: { clusterId: anchorId2, gapMs: 200 } });
  assert.notEqual(changed.id, anchorId2, 'continuity never overrides a distinct cluster that clearly scores higher');
});

test('a continuity anchor outside the configured gap is ignored', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  const clusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.55) });
  const resolved = matching.resolveCluster(db, {
    userId, sessionId, embedding: QUERY, continuity: { clusterId, gapMs: 60_000 },
  });
  assert.notEqual(resolved.id, clusterId, 'a gap beyond the configured continuity window is treated the same as no continuity at all');
});

test('an ambiguous global match without continuity mints a new cluster instead of guessing', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // Both clusters clear the 0.65 threshold and sit within 0.05 of each other:
  // exactly the ambiguity that let a distinct speaker's turn be silently
  // folded into an unrelated cluster before the margin check existed.
  seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.70) });
  seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(0.68) });
  const before = db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count;
  const resolved = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });
  const after = db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count;
  assert.equal(after, before + 1, 'an ambiguous match mints a new cluster rather than attaching to either candidate');
  assert.equal(db.prepare('SELECT sample_count FROM speaker_clusters WHERE id=?').get(resolved.id).sample_count, 1);
});

test('a confident global match without continuity still resolves normally', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  const clusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(0.90) });
  seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(0.10) });
  const resolved = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });
  assert.equal(resolved.id, clusterId, 'a clear best match with a wide margin over the runner-up resolves without minting a new cluster');
});

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
