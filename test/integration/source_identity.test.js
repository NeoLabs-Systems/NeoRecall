'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-source-identity-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const sourceIdentity = require('../../server/speakers/source_identity');
const transcribeHandler = require('../../server/workers/handlers/transcribe_handler');
const engine = require('../../server/speakers/identity_engine');
const matching = require('../../server/transcription/speaker_matching');
const voiceprintStorage = require('../../server/transcription/voiceprint_storage');
const vectors = require('../../server/transcription/speaker_embeddings');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const START = new Date(Date.now() - 2 * 60 * 60_000).toISOString();
const MODEL = matching.modelName;

function at(similarity, axis = 1) {
  const vector = new Float32Array([similarity, 0, 0]);
  vector[axis] = Math.sqrt(Math.max(0, 1 - similarity * similarity));
  return vector;
}

function seedUser() {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `src-${userId}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, START, START, START);
  return { userId, sessionId };
}

// A source that may or may not declare who it is carrying.
function seedSource({ userId, sessionId }, metadata) {
  const db = getDatabase();
  const sourceId = crypto.randomUUID();
  db.prepare(`INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,metadata_json)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',?)`).run(sourceId, sessionId, sourceId, JSON.stringify(metadata));
  return sourceId;
}

function seedChunk({ userId, sessionId }, sourceId, sequence = 0) {
  const db = getDatabase();
  const chunkId = crypto.randomUUID();
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,?,?,?,1,'wav','pcm_s16le','mono',?,0,30000,'processing')`)
    .run(chunkId, userId, sessionId, sourceId, sequence, chunkId, crypto.randomBytes(32).toString('hex'), START);
  return db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId);
}

function segment(embedding, { startMs = 0, endMs = 20_000, speaker = 0 } = {}) {
  return {
    text: 'Ein Satz.', startMs, endMs, sourceComponent: 'combined', language: 'de',
    diarizationSpeaker: speaker, speakerEmbedding: embedding, speakerSpeechMs: endMs - startMs,
    speakerConfidence: 1, overlappingSpeech: false,
  };
}

test('a source that says whose voice it carries gets that person, named, with no acoustic matching', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { speaker: { key: 'chat:1001', name: 'Mara' } });
  const chunk = seedChunk(user, sourceId);

  transcribeHandler.persistSegments(chunk, [segment(new Float32Array([1, 0, 0]))]);

  const rows = db.prepare('SELECT * FROM voiceprints WHERE user_id=?').all(user.userId);
  assert.equal(rows.length, 1, 'one person, not one per fingerprint');
  assert.equal(rows[0].external_key, 'chat:1001');
  assert.equal(rows[0].display_name, 'Mara');
  // The account name is a suggestion, not something the user stands behind.
  assert.equal(rows[0].display_name_source, 'inferred');
  const turn = db.prepare('SELECT voiceprint_id FROM speaker_turns WHERE user_id=?').get(user.userId);
  assert.equal(turn.voiceprint_id, rows[0].id, 'the speech is attached to them');
});

test('the same declared person across two recordings is one profile, not two', () => {
  const db = getDatabase();
  const user = seedUser();
  const first = seedSource(user, { speaker: { key: 'chat:2002', name: 'Anna' } });
  const second = seedSource(user, { speaker: { key: 'chat:2002', name: 'Anna' } });
  // Deliberately dissimilar fingerprints: a bad measurement, a different
  // microphone, a cold. The declaration is what makes them one person anyway,
  // and that is the whole reason it beats matching on sound.
  transcribeHandler.persistSegments(seedChunk(user, first), [segment(new Float32Array([1, 0, 0]))]);
  transcribeHandler.persistSegments(seedChunk(user, second, 1), [segment(at(0.05, 2))]);

  const rows = db.prepare("SELECT * FROM voiceprints WHERE user_id=? AND external_key='chat:2002'").all(user.userId);
  assert.equal(rows.length, 1);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_turns WHERE user_id=? AND voiceprint_id=?')
    .get(user.userId, rows[0].id).count, 2);
});

test('two declared people who sound identical are never merged', () => {
  const db = getDatabase();
  const user = seedUser();
  const oneSource = seedSource(user, { speaker: { key: 'chat:3001', name: 'One' } });
  const twoSource = seedSource(user, { speaker: { key: 'chat:3002', name: 'Two' } });
  const shared = new Float32Array([1, 0, 0]);
  transcribeHandler.persistSegments(seedChunk(user, oneSource), [segment(shared)]);
  transcribeHandler.persistSegments(seedChunk(user, twoSource, 1), [segment(shared, { startMs: 20_000, endMs: 40_000 })]);

  const conversationId = crypto.randomUUID();
  db.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(conversationId, user.userId, START, new Date().toISOString());
  db.prepare('UPDATE transcript_segments SET conversation_id=? WHERE user_id=?').run(conversationId, user.userId);

  engine.resolveConversation(db, user.userId, conversationId);

  const labels = db.prepare('SELECT DISTINCT local_label FROM conversation_speakers WHERE conversation_id=?')
    .all(conversationId).map((row) => row.local_label);
  assert.equal(labels.length, 2, 'identical fingerprints do not override two sources that named two people');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(user.userId).count, 2);
});

test('one declared person never splits, whatever their fingerprints scored', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { speaker: { key: 'chat:4004', name: 'Split' } });
  // Two fingerprints far enough apart that similarity alone would put them in
  // different voices — a bad measurement, a moved microphone, a cold. On a
  // stream that is one person by construction that is a measurement failure, and
  // the declaration decides instead. Note this is prevented rather than
  // repaired: the recording-local voice follows from the person, so the split
  // never happens and no later pass has to undo it.
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(new Float32Array([1, 0, 0]))]);
  transcribeHandler.persistSegments(seedChunk(user, sourceId, 1), [segment(at(0.02, 2), { startMs: 40_000, endMs: 60_000 })]);

  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_clusters WHERE session_id=?').get(user.sessionId).count, 1,
    'both stretches are the same recording-local voice');

  const conversationId = crypto.randomUUID();
  db.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
    VALUES (?,?,?,?,'closed','test','1')`).run(conversationId, user.userId, START, new Date().toISOString());
  db.prepare('UPDATE transcript_segments SET conversation_id=? WHERE user_id=?').run(conversationId, user.userId);
  engine.resolveConversation(db, user.userId, conversationId);

  const labels = db.prepare('SELECT DISTINCT local_label FROM conversation_speakers WHERE conversation_id=?')
    .all(conversationId).map((row) => row.local_label);
  assert.deepEqual(labels, ['Speaker 1'], 'and the transcript reads as one person');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(user.userId).count, 1);
});

test('a second voice on the stream is still labelled, but never joins the profile', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { speaker: { key: 'chat:5005', name: 'Owner' } });
  const chunk = seedChunk(user, sourceId);
  // Someone else audible in the room behind an open microphone. It is still the
  // owner's stream, so their label stands — but letting that speech into the
  // profile would corrupt the one thing that makes a declaration valuable
  // elsewhere: a clean fingerprint for the person it names.
  transcribeHandler.persistSegments(chunk, [
    segment(new Float32Array([1, 0, 0]), { speaker: 0, startMs: 0, endMs: 10_000 }),
    segment(at(0.02, 2), { speaker: 1, startMs: 10_000, endMs: 20_000 }),
  ]);

  const row = db.prepare("SELECT * FROM voiceprints WHERE user_id=? AND external_key='chat:5005'").get(user.userId);
  assert.equal(row.sample_count, 0, 'a chunk carrying two voices teaches the profile nothing');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM speaker_turns WHERE user_id=? AND voiceprint_id=?')
    .get(user.userId, row.id).count, 2, 'but both stretches are still attributed to the stream owner');
});

test('a name the user set is never replaced by the one the source supplies', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { speaker: { key: 'chat:6006', name: 'accountname' } });
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(new Float32Array([1, 0, 0]))]);
  db.prepare(`UPDATE voiceprints SET display_name='Mara',display_name_source='manual'
    WHERE user_id=? AND external_key='chat:6006'`).run(user.userId);

  transcribeHandler.persistSegments(seedChunk(user, sourceId, 1), [segment(new Float32Array([1, 0, 0]), { startMs: 40_000, endMs: 60_000 })]);

  const row = db.prepare("SELECT * FROM voiceprints WHERE user_id=? AND external_key='chat:6006'").get(user.userId);
  assert.equal(row.display_name, 'Mara');
  assert.equal(row.display_name_source, 'manual');
});

test('a source that declares nothing is matched acoustically, exactly as before', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { platform: 'macos' });
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(new Float32Array([1, 0, 0]))]);

  const rows = db.prepare('SELECT * FROM voiceprints WHERE user_id=?').all(user.userId);
  assert.ok(rows.every((row) => row.external_key === null), 'nothing invents an external identity');
  assert.equal(sourceIdentity.declaredSpeaker(db, sourceId), null);
});

test('malformed or partial metadata is ignored rather than failing a recording', () => {
  const db = getDatabase();
  const user = seedUser();
  // Metadata is client-supplied. Every one of these is something a client could
  // plausibly send, and none of them may cost a transcript.
  const broken = seedSource(user, {});
  assert.equal(sourceIdentity.declaredSpeaker(db, broken), null);
  const noKey = seedSource(user, { speaker: { name: 'Nameless' } });
  assert.equal(sourceIdentity.declaredSpeaker(db, noKey), null);
  const blankKey = seedSource(user, { speaker: { key: '   ' } });
  assert.equal(sourceIdentity.declaredSpeaker(db, blankKey), null);
  const keyOnly = seedSource(user, { speaker: { key: 'chat:7007' } });
  assert.deepEqual(sourceIdentity.declaredSpeaker(db, keyOnly), { key: 'chat:7007', name: null });
  db.prepare("UPDATE recording_sources SET metadata_json='{not json' WHERE id=?").run(broken);
  assert.equal(sourceIdentity.declaredSpeaker(db, broken), null);
  assert.equal(sourceIdentity.declaredSpeaker(db, null), null);
});

test('a declared profile is what later recognises the same person where nothing is declared', () => {
  const db = getDatabase();
  const user = seedUser();
  const voice = new Float32Array([1, 0, 0]);
  // The point of all of this. Labelled speech from a stream that knew who it was
  // builds a correct profile, and that profile is then the thing that identifies
  // the same person on a room microphone that knows nothing.
  const declaredSource = seedSource(user, { speaker: { key: 'chat:8008', name: 'Known' } });
  transcribeHandler.persistSegments(seedChunk(user, declaredSource), [segment(voice)]);
  const enrolled = db.prepare("SELECT * FROM voiceprints WHERE user_id=? AND external_key='chat:8008'").get(user.userId);
  assert.equal(enrolled.sample_count, 1, 'the declared stream taught the profile what they sound like');

  const anonymous = seedSource(user, { platform: 'macos' });
  transcribeHandler.persistSegments(seedChunk(user, anonymous, 1), [segment(at(0.98), { startMs: 40_000, endMs: 60_000 })]);

  const matched = db.prepare(`SELECT st.voiceprint_id FROM speaker_turns st
    JOIN audio_chunks c ON c.id=st.chunk_id WHERE c.source_id=?`).get(anonymous);
  assert.equal(matched.voiceprint_id, enrolled.id, 'the anonymous recording resolves to the person we already knew');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(user.userId).count, 1,
    'and no second profile is invented for them');
});

test('the seed profile of a declared identity is a real fingerprint, not a placeholder', () => {
  const db = getDatabase();
  const user = seedUser();
  const voice = new Float32Array([0.6, 0.8, 0]);
  const sourceId = seedSource(user, { speaker: { key: 'chat:9009', name: 'Seeded' } });
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(voice)]);

  const row = db.prepare("SELECT * FROM voiceprints WHERE user_id=? AND external_key='chat:9009'").get(user.userId);
  const stored = voiceprintStorage.readCentroid(row.centroid_embedding);
  assert.equal(row.embedding_dimensions, 3);
  assert.ok(vectors.cosine(stored, voice) > 0.999, 'the stored profile is the voice that was heard');
  assert.equal(row.embedding_model, MODEL);
});

test('a person the recording identified appears in the list before any preview exists', () => {
  const db = getDatabase();
  const user = seedUser();
  const sourceId = seedSource(user, { speaker: { key: 'chat:1010', name: 'Listed' } });
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(new Float32Array([1, 0, 0]))]);
  // An unnamed voice is held back until there is enough clean audio to recognise
  // it by ear, because listening is the only way to tell two of them apart. This
  // person is already named and exactly identified, so that reasoning does not
  // apply — waiting would hide the people the server is most sure about.
  const listed = require('../../server/services/speakers/speaker_service').list(user.userId);
  const row = listed.find((speaker) => speaker.display_name === 'Listed');
  assert.ok(row, 'a declared person is listed straight away');
  assert.equal(row.preview_duration_ms, null, 'and is honestly reported as having no preview yet');
});

test('an unnamed voice with no usable preview is still held back', () => {
  const user = seedUser();
  const sourceId = seedSource(user, { platform: 'macos' });
  transcribeHandler.persistSegments(seedChunk(user, sourceId), [segment(new Float32Array([0, 1, 0]))]);
  const listed = require('../../server/services/speakers/speaker_service').list(user.userId);
  assert.equal(listed.length, 0, 'a list of clips too short to identify is worse than no list');
});
