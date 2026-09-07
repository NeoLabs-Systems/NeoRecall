'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-resolution-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const engine = require('../../server/speakers/identity_engine');
const matching = require('../../server/transcription/speaker_matching');
const handler = require('../../server/workers/handlers/resolve_speakers_handler');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const limits = () => require('../../server/services/settings/processing_settings_service').get();
const MODEL = matching.modelName;
// Relative to now, not a fixed date: the sweep only looks back a bounded number
// of days, so a hard-coded timestamp silently ages out of the window and takes
// the test's meaning with it.
const START = new Date(Date.now() - 2 * 60 * 60_000).toISOString();
const ENDED = new Date(Date.now() - 60 * 60_000).toISOString();

function bytes(vector) { return Buffer.from(vector.buffer, vector.byteOffset, vector.byteLength); }
function at(similarity, axis = 1) {
  const vector = new Float32Array([similarity, 0, 0]);
  vector[axis] = Math.sqrt(Math.max(0, 1 - similarity * similarity));
  return vector;
}

function seedUser() {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `speaker-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  return { userId, deviceId };
}

// One session with one source and one chunk. Sessions are seeded separately
// where a test needs a voice heard in two recordings.
function seedSession({ userId, deviceId }, { startedAt = START, offsetMs = 0 } = {}) {
  const db = getDatabase();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')`).run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono',?,?,60000,'transcribed')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, crypto.randomBytes(32).toString('hex'), startedAt, offsetMs);
  return { sessionId, sourceId, chunkId };
}

function seedConversation(userId) {
  const id = crypto.randomUUID();
  getDatabase().prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(id, userId, START, ENDED);
  return id;
}

// One voice inside a conversation: a session cluster, the turns that carry its
// fingerprint, and the transcript rows that put it in the conversation.
function seedVoice({ userId, sessionId, chunkId }, conversationId, {
  ordinal, embedding, startMs, endMs, voiceprintId = null, overlapping = 0,
}) {
  const db = getDatabase();
  const clusterId = crypto.randomUUID();
  db.prepare(`INSERT INTO speaker_clusters
    (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?,1)`).run(clusterId, userId, sessionId, ordinal, bytes(embedding), MODEL, embedding.length);
  db.prepare(`INSERT INTO speaker_turns
    (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions,overlapping_speech)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)`).run(crypto.randomUUID(), userId, chunkId, clusterId, voiceprintId,
    startMs, endMs, bytes(embedding), MODEL, embedding.length, overlapping);
  db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,conversation_id,speaker_cluster_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text)
    VALUES (?,?,?,?,?,'combined',?,?,?,?,'Ein Satz.')`).run(crypto.randomUUID(), userId, chunkId, conversationId, clusterId,
    new Date(Date.parse(START) + startMs).toISOString(), new Date(Date.parse(START) + endMs).toISOString(), startMs, endMs);
  return clusterId;
}

function labels(conversationId) {
  return getDatabase().prepare('SELECT DISTINCT local_label FROM conversation_speakers WHERE conversation_id=? ORDER BY local_label')
    .all(conversationId).map((row) => row.local_label);
}
function voiceprintCount(userId) {
  return getDatabase().prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(userId).count;
}

test('one person split across three labels in a conversation becomes one person', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  // The reported bug, reproduced exactly: one voice that per-chunk resolution
  // split into three clusters, none of which had enough speech in any single
  // chunk to enroll anyone — so every turn resolved to nobody and each cluster
  // fell back to its own label.
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 20_000 });
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 2, embedding: at(0.97), startMs: 20_000, endMs: 40_000 });
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 3, embedding: at(0.96), startMs: 40_000, endMs: 60_000 });
  require('../../server/services/conversations/conversation_membership_service')
    .rebuildConversationSpeakers(db, user.userId, conversationId);
  assert.equal(labels(conversationId).length, 3, 'the pipeline really did split one voice three ways');

  const result = engine.resolveConversation(db, user.userId, conversationId);

  assert.deepEqual(labels(conversationId), ['Speaker 1'], 'the conversation now names one speaker');
  assert.equal(voiceprintCount(user.userId), 1, 'and that speaker is one durable person, not three');
  assert.equal(result.mergedClusters, 2);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE session_id=?').get(session.sessionId).count, 1);
});

test('a voice heard in two recordings shares one label without either cluster being destroyed', () => {
  const db = getDatabase();
  const user = seedUser();
  const first = seedSession(user);
  const second = seedSession(user, { startedAt: new Date(Date.now() - 30 * 60_000).toISOString() });
  const conversationId = seedConversation(user.userId);
  // Refinement can re-partition segments across a whole batch, so one
  // conversation really can span two sessions. Merging the clusters would move a
  // row out of the session the live resolver searches, which then mints a
  // replacement every chunk. Sharing the person is enough.
  seedVoice({ ...user, ...first }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });
  seedVoice({ ...user, ...second }, conversationId, { ordinal: 1, embedding: at(0.97), startMs: 0, endMs: 30_000 });

  engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE user_id=?').get(user.userId).count, 2,
    'both session clusters survive');
  const assigned = db.prepare(`SELECT DISTINCT voiceprint_id FROM speaker_turns
    WHERE user_id=? AND voiceprint_id IS NOT NULL`).all(user.userId);
  assert.equal(assigned.length, 1, 'and they resolve to the same person');
  assert.deepEqual(labels(conversationId), ['Speaker 1'], 'which is what collapses the label');
});

test('two people talking over each other stay two people however alike they score', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  // Adversarial: the diarizer blends overlapping speech, so two speakers on one
  // microphone can score higher against each other than a real duplicate pair.
  // Speaking at the same time on the same source is the harder evidence.
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 2, embedding: at(0.99), startMs: 10_000, endMs: 40_000 });

  engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE session_id=?').get(session.sessionId).count, 2);
  assert.equal(labels(conversationId).length, 2, 'the two speakers keep separate labels');
});

test('a name the user set is never undone by a merge', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  const named = (name) => {
    const id = crypto.randomUUID();
    db.prepare(`INSERT INTO voiceprints (id,user_id,display_name,display_name_source,centroid_embedding,
      embedding_model,embedding_dimensions,sample_count) VALUES (?,?,?,'manual',?,?,3,2)`)
      .run(id, user.userId, name, require('../../server/transcription/voiceprint_storage').sealCentroid(new Float32Array([1, 0, 0])), MODEL);
    return id;
  };
  seedVoice({ ...user, ...session }, conversationId, {
    ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000, voiceprintId: named('Mara'),
  });
  seedVoice({ ...user, ...session }, conversationId, {
    ordinal: 2, embedding: at(0.99), startMs: 30_000, endMs: 60_000, voiceprintId: named('Anna'),
  });

  engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE session_id=?').get(session.sessionId).count, 2,
    'two people the user named by hand are never folded together by a similarity score');
  assert.equal(voiceprintCount(user.userId), 2);
});

test('resolving twice changes nothing the second time', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 2, embedding: at(0.97), startMs: 30_000, endMs: 60_000 });

  engine.resolveConversation(db, user.userId, conversationId);
  const after = engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(after.mergedClusters, 0, 'nothing left to merge');
  assert.equal(after.assignedTurns, 0, 'nothing left to attach');
  assert.equal(voiceprintCount(user.userId), 1, 'and no second person invented on the way through');
});

test('speech nobody could fingerprint resolves to nothing rather than failing', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  // Every turn overlapped, so no measurement is safe to use. Without the
  // native runtime installed this is the shape of every conversation.
  seedVoice({ ...user, ...session }, conversationId, {
    ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000, overlapping: 1,
  });
  const before = voiceprintCount(user.userId);

  const result = engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(result.mergedClusters, 0);
  assert.equal(voiceprintCount(user.userId), before, 'blended speech never founds a person');
});

test('a conversation with no speaker turns at all is a clean no-op', () => {
  const db = getDatabase();
  const user = seedUser();
  seedSession(user);
  const conversationId = seedConversation(user.userId);
  const result = engine.resolveConversation(db, user.userId, conversationId);
  assert.deepEqual(result, { voices: 0, groups: 0, mergedClusters: 0, assignedTurns: 0 });
});

test('a conversation that no longer exists is skipped, not retried', async () => {
  const user = seedUser();
  // Refinement deletes the conversations it replaces, so a queued job routinely
  // names a row that has gone. Throwing here would burn every retry attempt to
  // reach the same answer.
  const result = await handler.handle({ user_id: user.userId, resource_id: crypto.randomUUID() });
  assert.deepEqual(result, { skipped: 'conversation_gone' });
});

test('the enrollment floor is what conversation-scale speech finally clears', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  const { voiceEnrollMinimumMs } = limits();
  // Two turns, each on its own too short to found a person — which is why the
  // live pass left them attached to nobody. Together they are plenty.
  const half = Math.ceil(voiceEnrollMinimumMs * 0.6);
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: half });
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 2, embedding: at(0.97), startMs: half, endMs: half * 2 });
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_turns WHERE user_id=? AND voiceprint_id IS NOT NULL').get(user.userId).count, 0);

  engine.resolveConversation(db, user.userId, conversationId);

  assert.equal(voiceprintCount(user.userId), 1, 'the pooled speech of a whole conversation enrolls the person');
  assert.ok(db.prepare('SELECT COUNT(*) count FROM speaker_turns WHERE user_id=? AND voiceprint_id IS NOT NULL').get(user.userId).count > 0,
    'and the turns are attached to them');
});

// --- Recovering conversations the pass never reached ---------------------------
//
// A conversation queues its own resolution when it closes, so on a healthy
// server the sweep finds nothing. It exists for the times that did not happen: a
// worker down at the wrong moment, a job that exhausted its attempts, or a
// conversation recorded before this pass existed. Nothing else ever revisits a
// closed conversation, so without the sweep those keep their split labels
// permanently.

const speakers = require('../../server/services/speakers/speaker_service');

function pendingJobs(userId) {
  return getDatabase().prepare(`SELECT resource_id FROM jobs WHERE user_id=? AND type='resolve_speakers'
    AND status IN ('queued','leased')`).all(userId).map((row) => row.resource_id);
}

test('a conversation that never got its speakers resolved is picked up later', () => {
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  // Speech attached to no durable person: the exact state the pass corrects, and
  // the reason this conversation still reads as several speakers.
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });

  assert.deepEqual(speakers.sweepUnresolvedConversations(user.userId), 1);
  assert.deepEqual(pendingJobs(user.userId), [conversationId]);
});

test('the sweep does not queue the same conversation twice', () => {
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });

  assert.equal(speakers.sweepUnresolvedConversations(user.userId), 1);
  assert.equal(speakers.sweepUnresolvedConversations(user.userId), 0,
    'a conversation already waiting is not queued again every hour');
});

test('a conversation whose speakers are all resolved is left alone', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });
  engine.resolveConversation(db, user.userId, conversationId);
  db.prepare("UPDATE jobs SET status='completed' WHERE user_id=?").run(user.userId);

  assert.equal(speakers.sweepUnresolvedConversations(user.userId), 0,
    'once every voice has a person, there is nothing left to revisit');
});

test('a still-recording conversation is never swept', () => {
  const db = getDatabase();
  const user = seedUser();
  const session = seedSession(user);
  const conversationId = seedConversation(user.userId);
  seedVoice({ ...user, ...session }, conversationId, { ordinal: 1, embedding: new Float32Array([1, 0, 0]), startMs: 0, endMs: 30_000 });
  db.prepare("UPDATE conversations SET state='open' WHERE id=?").run(conversationId);
  // More speech is still arriving, so any answer now is provisional by
  // definition. Closing is what makes the whole conversation available.
  assert.equal(speakers.sweepUnresolvedConversations(user.userId), 0);
});
