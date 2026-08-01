'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-identity-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const identity = require('../../server/services/speakers/speaker_identity_service');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

function vector(values) { return new Float32Array(values); }
function bytes(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }

// Builds one user with a session, a speaker cluster, a voiceprint the cluster's
// turns already stick to, and (unless `withDisplayName` is false) an existing
// manually-set display name — the state consolidation's speaker naming reads
// and writes against.
function seedVoice(db, { displayName = null } = {}) {
  const userId = crypto.randomUUID(); const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID(); const chunkId = crypto.randomUUID();
  const clusterId = crypto.randomUUID(); const voiceprintId = crypto.randomUUID();
  const sample = vector([1, 0, 0, 0]);
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `identity-${userId}`);
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
  db.prepare(`INSERT INTO speaker_clusters
    (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,1,?,'test-model',?,1)`).run(clusterId, userId, sessionId, bytes(sample), sample.length);
  db.prepare(`INSERT INTO voiceprints (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,'test-model',?,1)`).run(voiceprintId, userId, displayName, bytes(sample), sample.length);
  db.prepare(`INSERT INTO speaker_turns (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions)
    VALUES (?,?,?,?,?,0,1000,?,'test-model',?)`).run(crypto.randomUUID(), userId, chunkId, clusterId, voiceprintId, bytes(sample), sample.length);
  return { userId, clusterId, voiceprintId };
}

// voiceprints.entity_id is a real foreign key into entities, so a test that
// expects the link to succeed needs an actual entities row to point at.
function seedEntity(db, userId, { id, canonicalNameEn = 'Someone', kind = 'person' } = {}) {
  db.prepare(`INSERT INTO entities (id,user_id,kind,canonical_name_en,normalized_identity_key)
    VALUES (?,?,?,?,?)`).run(id, userId, kind, canonicalNameEn, canonicalNameEn.toLowerCase());
  return id;
}

test('an unnamed voiceprint is named and linked to the entity a self-introduction identified', () => {
  const db = getDatabase();
  const { userId, clusterId, voiceprintId } = seedVoice(db);
  const entityId = seedEntity(db, userId, { id: crypto.randomUUID(), canonicalNameEn: 'Sumner Tilton' });
  const entities = [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Sumner Tilton', displayName: 'Sumner Tilton', speakerAlias: 'speaker1' }];
  const entityIds = new Map([['person-1', entityId]]);
  const clusterIdsByAlias = new Map([['speaker1', clusterId]]);

  const linked = identity.linkEntitiesToSpeakers(db, userId, entities, entityIds, clusterIdsByAlias);

  assert.deepEqual(linked, [{ voiceprintId, entityId }]);
  const row = db.prepare('SELECT display_name,entity_id FROM voiceprints WHERE id=?').get(voiceprintId);
  assert.deepEqual(row, { display_name: 'Sumner Tilton', entity_id: entityId });
});

test('a manually set display name is never overwritten by an automatic identification', () => {
  const db = getDatabase();
  const { userId, clusterId, voiceprintId } = seedVoice(db, { displayName: 'Chosen by the user' });
  const entityId = seedEntity(db, userId, { id: crypto.randomUUID(), canonicalNameEn: 'Someone Else' });
  const entities = [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Someone Else', displayName: 'Someone Else', speakerAlias: 'speaker1' }];
  const entityIds = new Map([['person-1', entityId]]);
  const clusterIdsByAlias = new Map([['speaker1', clusterId]]);

  identity.linkEntitiesToSpeakers(db, userId, entities, entityIds, clusterIdsByAlias);

  const row = db.prepare('SELECT display_name,entity_id FROM voiceprints WHERE id=?').get(voiceprintId);
  // The name is preserved; the entity link still forms so future consolidation
  // runs can keep recognizing this as the same person across other voiceprints.
  assert.deepEqual(row, { display_name: 'Chosen by the user', entity_id: entityId });
});

test('an entity that is not a person is never written onto a voice', () => {
  const db = getDatabase();
  const { userId, clusterId, voiceprintId } = seedVoice(db);
  const entities = [{ ref: 'loc-1', kind: 'location', canonicalNameEn: 'City Hall', displayName: null, speakerAlias: 'speaker1' }];
  const entityIds = new Map([['loc-1', 'entity-1']]);
  const clusterIdsByAlias = new Map([['speaker1', clusterId]]);

  const linked = identity.linkEntitiesToSpeakers(db, userId, entities, entityIds, clusterIdsByAlias);

  assert.deepEqual(linked, []);
  const row = db.prepare('SELECT display_name,entity_id FROM voiceprints WHERE id=?').get(voiceprintId);
  assert.deepEqual(row, { display_name: null, entity_id: null });
});

test('a speaker alias this batch never used is ignored rather than guessed at', () => {
  const db = getDatabase();
  const { userId, voiceprintId } = seedVoice(db);
  const entities = [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Someone', displayName: null, speakerAlias: 'speaker9' }];
  const entityIds = new Map([['person-1', 'entity-1']]);
  const clusterIdsByAlias = new Map(); // "speaker9" was never assigned to a cluster in this batch

  const linked = identity.linkEntitiesToSpeakers(db, userId, entities, entityIds, clusterIdsByAlias);

  assert.deepEqual(linked, []);
  assert.equal(db.prepare('SELECT entity_id FROM voiceprints WHERE id=?').get(voiceprintId).entity_id, null);
});

test('an entity with no speakerAlias is skipped entirely', () => {
  const db = getDatabase();
  const { userId, clusterId } = seedVoice(db);
  const entities = [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Someone', displayName: null, speakerAlias: null }];
  const entityIds = new Map([['person-1', 'entity-1']]);
  const clusterIdsByAlias = new Map([['speaker1', clusterId]]);

  assert.deepEqual(identity.linkEntitiesToSpeakers(db, userId, entities, entityIds, clusterIdsByAlias), []);
});
