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

// Thresholds are read rather than hard-coded, so tests stay valid as defaults move.
const limits = () => require('../../server/services/settings/processing_settings_service').get();
function belowPlainAboveContinuity() {
  const { speakerClusterThreshold: plain, speakerClusterContinuityThreshold: relaxed } = limits();
  return (plain + relaxed) / 2;
}

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

test('the shipped speaker duration cutoff favors labeling short speech', () => {
  assert.equal(limits().speakerMinimumTurnMs, 500);
});

test('a boundary-continuity anchor keeps its cluster despite drift below the plain threshold', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // A similarity between the relaxed continuity bar and the plain one: exactly
  // the drift a re-segmented chunk boundary produces for the same continuing
  // speaker.
  const drifted = belowPlainAboveContinuity();
  const clusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(drifted) });

  const withoutContinuity = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });
  assert.notEqual(withoutContinuity.id, clusterId, 'without continuity evidence, a below-threshold match still mints a new cluster');

  // resolveCluster above mutated the first cluster's centroid and minted a
  // second one; reseed a clean single cluster for the continuity assertion.
  db.prepare('DELETE FROM speaker_clusters WHERE user_id=?').run(userId);
  const freshClusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(drifted) });
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
  // Both clear the plain threshold and are near-identical to each other, so
  // without continuity they would merge; the anchor is what decides which of
  // the two the turn belongs to.
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
  const clusterId = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(belowPlainAboveContinuity()) });
  const resolved = matching.resolveCluster(db, {
    userId, sessionId, embedding: QUERY, continuity: { clusterId, gapMs: 60_000 },
  });
  assert.notEqual(resolved.id, clusterId, 'a gap beyond the configured continuity window is treated the same as no continuity at all');
});

test('two clusters that both match strongly are one person, and are merged rather than tripled', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // Two strong candidates this alike are the same person already split, so
  // they are folded together rather than left to accumulate a third copy.
  const { speakerClusterThreshold: plain, speakerClusterMargin: margin } = limits();
  const first = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(plain + 0.2) });
  const second = seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(plain + 0.2 - margin / 2) });
  const resolved = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });

  const remaining = db.prepare('SELECT id FROM speaker_clusters WHERE user_id=?').all(userId).map((row) => row.id);
  assert.deepEqual(remaining, [resolved.id], 'the two candidates end as one voice, and no third is created');
  assert.ok([first, second].includes(resolved.id), 'the survivor is one of the original clusters');
});

test('a borderline match against a weak runner-up still refuses to guess', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // A genuinely new speaker grazing the threshold, with the runner-up just
  // below the bar: both readings are equally weak, so neither is trusted.
  const { speakerClusterThreshold: plain, speakerClusterMargin: margin } = limits();
  seedCluster(db, { userId, sessionId, ordinal: 1, embedding: centroidWithSimilarity(plain + margin / 4) });
  seedCluster(db, { userId, sessionId, ordinal: 2, embedding: centroidWithSimilarity(plain - margin / 4) });
  const before = db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count;
  const resolved = matching.resolveCluster(db, { userId, sessionId, embedding: QUERY, continuity: null });
  const after = db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count;
  assert.equal(after, before + 1, 'a contested borderline match mints a new cluster rather than attaching to either candidate');
  assert.equal(db.prepare('SELECT sample_count FROM speaker_clusters WHERE id=?').get(resolved.id).sample_count, 1);
});

test('speech too short to fingerprint never becomes a new speaker', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  // A sub-second turn produced a 0.97 similarity to a *different* speaker in
  // measurement. Such a turn may join a voice that already exists, but letting
  // it invent one turns noise into a person.
  const { speakerMinimumTurnMs } = limits();
  const before = db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count;
  const resolved = matching.resolveCluster(db, {
    userId, sessionId, embedding: QUERY, continuity: null, durationMs: Math.max(0, speakerMinimumTurnMs - 1),
  });
  assert.equal(resolved, null, 'the turn resolves to no speaker at all');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(userId).count, before,
    'and no cluster is created for it');
});

test('speech at the minimum fingerprint duration creates a speaker', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  const { speakerMinimumTurnMs } = limits();
  const resolved = matching.resolveCluster(db, {
    userId, sessionId, embedding: QUERY, continuity: null, durationMs: speakerMinimumTurnMs,
  });
  assert.ok(resolved, 'real short speech at the configured cutoff gets a speaker label');
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

test('a sealed voiceprint is recognized as the same person in a later cluster', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  const firstCluster = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: QUERY });
  const first = matching.resolveVoiceprint(db, { userId, clusterId: firstCluster, embedding: QUERY, enabled: true });
  const stored = db.prepare('SELECT centroid_embedding FROM voiceprints WHERE id=?').get(first.id).centroid_embedding;
  assert.notEqual(Buffer.compare(stored, bytes(QUERY)), 0, 'the enrolled centroid is sealed at rest');

  // No speaker_turns, so sticky assignment cannot hide a failed global rank.
  const laterCluster = seedCluster(db, { userId, sessionId, ordinal: 2, embedding: QUERY });
  const matched = matching.resolveVoiceprint(db, { userId, clusterId: laterCluster, embedding: QUERY, enabled: true });
  assert.equal(matched.id, first.id, 'global matching still finds the sealed voiceprint');
  assert.equal(db.prepare('SELECT count(*) count FROM voiceprints WHERE user_id=?').get(userId).count, 1);
});

test('a voice is fingerprinted from everything it said in a chunk, not from one turn', () => {
  const { poolBySpeaker } = require('../../server/transcription/diarization');
  const turns = [
    { speaker: 0, startMs: 0, endMs: 1_000, embedding: new Float32Array([1, 0]) },
    { speaker: 0, startMs: 2_000, endMs: 3_000, embedding: new Float32Array([0, 1]) },
    { speaker: 1, startMs: 4_000, endMs: 7_000, embedding: new Float32Array([0, 1]) },
  ];
  const pooled = poolBySpeaker(turns);
  assert.equal(pooled.get(0).speechMs, 2_000, 'both of the first voice\'s turns count toward its fingerprint');
  assert.equal(pooled.get(1).speechMs, 3_000);
  // Equal-length turns average evenly; the pooled vector is the mean.
  assert.ok(Math.abs(pooled.get(0).embedding[0] - 0.5) < 1e-6);
  assert.ok(Math.abs(pooled.get(0).embedding[1] - 0.5) < 1e-6);
});

test('pooling weights a long turn more heavily than a short one', () => {
  const { poolBySpeaker } = require('../../server/transcription/diarization');
  // Three seconds of clear speech should not be dragged around by a half-second
  // fragment that happens to follow it.
  const pooled = poolBySpeaker([
    { speaker: 0, startMs: 0, endMs: 3_000, embedding: new Float32Array([1, 0]) },
    { speaker: 0, startMs: 3_000, endMs: 3_500, embedding: new Float32Array([0, 1]) },
  ]);
  const voice = pooled.get(0);
  assert.equal(voice.speechMs, 3_500);
  assert.ok(voice.embedding[0] > voice.embedding[1] * 5, 'the long turn dominates the fingerprint');
});

test('clusters resolved to one recurring voice share a label and collapse into one session identity', () => {
  const db = getDatabase();
  const { userId, sessionId } = seedSession(db);
  const sourceId = crypto.randomUUID(); const chunkId = crypto.randomUUID(); const conversationId = crypto.randomUUID();
  const voiceprintId = crypto.randomUUID();
  db.prepare("INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')")
    .run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',1,'wav','pcm_s16le','mono','2026-07-14T10:00:00.000Z',0,10000,'processing')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId);
  db.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'open','test','1')`).run(conversationId, userId, '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:10.000Z');
  const firstCluster = seedCluster(db, { userId, sessionId, ordinal: 1, embedding: new Float32Array([1, 0]) });
  const secondCluster = seedCluster(db, { userId, sessionId, ordinal: 2, embedding: new Float32Array([0.99, 0.01]) });
  db.prepare(`INSERT INTO voiceprints
    (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?, ?,2,2)`).run(voiceprintId, userId, bytes(new Float32Array([1, 0])), matching.modelName);
  const turn = db.prepare(`INSERT INTO speaker_turns
    (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions)
    VALUES (?,?,?,?,?,?,?,?,?,2)`);
  turn.run(crypto.randomUUID(), userId, chunkId, firstCluster, voiceprintId, 0, 5000,
    bytes(new Float32Array([1, 0])), matching.modelName);
  turn.run(crypto.randomUUID(), userId, chunkId, secondCluster, voiceprintId, 5000, 10000,
    bytes(new Float32Array([0.99, 0.01])), matching.modelName);
  const segment = db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,conversation_id,speaker_cluster_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text)
    VALUES (?,?,?,?,?,'combined',?,?,?,?,?)`);
  segment.run(crypto.randomUUID(), userId, chunkId, conversationId, firstCluster,
    '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:05.000Z', 0, 5000, 'First stretch.');
  segment.run(crypto.randomUUID(), userId, chunkId, conversationId, secondCluster,
    '2026-07-14T10:00:05.000Z', '2026-07-14T10:00:10.000Z', 5000, 10000, 'Second stretch.');

  const membership = require('../../server/services/conversations/conversation_membership_service');
  membership.rebuildConversationSpeakers(db, userId, conversationId);
  const labels = db.prepare('SELECT local_label FROM conversation_speakers WHERE conversation_id=? ORDER BY cluster_id')
    .all(conversationId).map((row) => row.local_label);
  assert.deepEqual(labels, ['Speaker 1', 'Speaker 1'], 'one recurring person is not numbered once per cluster');

  assert.equal(matching.collapseSessionClustersByVoiceprint(db, { userId, sessionId }), 1);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE session_id=?').get(sessionId).count, 1);
  assert.equal(db.prepare('SELECT COUNT(DISTINCT speaker_cluster_id) count FROM transcript_segments WHERE conversation_id=?')
    .get(conversationId).count, 1, 'all transcript evidence follows the surviving cluster');
});
