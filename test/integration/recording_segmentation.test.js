'use strict';

// One recording is one conversation, unless the subject really moved on.
//
// The live stream and a prerecorded file reach conversation detection through
// the same door — chunks, transcript segments, then the boundary handler — so
// both are driven here against the shipping configuration. What is asserted is
// the property a reader cares about: an hour of one meeting is one moment in
// the timeline and one memory, not a card every few minutes.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ffmpegPath = require('ffmpeg-static');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-segmentation-'));

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const boundaryHandler = require('../../server/workers/handlers/boundary_handler');
const importHandler = require('../../server/workers/handlers/import_handler');
const { getConfig } = require('../../server/config');

const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

// One clock reading for the whole suite, so two offsets a fixed distance apart
// stay exactly that far apart however long the run takes.
const SUITE_NOW = Date.now();
const iso = (offsetMs) => new Date(SUITE_NOW + offsetMs).toISOString();

// Two subjects, in the dimensionality the search index stores. Far enough apart
// to be told apart (cosine ~0.2, below the similarity threshold) and identical
// within themselves, which is the shape a run of utterances about one thing has.
const DIMENSIONS = require('../../server/config').getConfig().embeddingDimensions;
const SUBJECTS = [0, 1].map((axis) => {
  const vector = new Float32Array(DIMENSIONS);
  vector[axis] = 0.9;
  vector[1 - axis] = 0.1;
  return vector;
});

async function user(username) {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username, password: 'a long and unique password' }).expect(201);
  return registration.body.user.id;
}

function liveSession(userId, startedAt) {
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',-1)`).run(sourceId, sessionId, sourceId);
  return { userId, sessionId, sourceId, deviceId };
}

// One transcribed utterance, indexed and embedded the way the transcribe
// handler and the embedding worker leave it. Detection reads the embedding
// through the search index, so a test that skipped it would exercise the
// no-evidence path rather than the real one.
function utterance(userId, chunkId, { startedAt, endedAt, text, subject }) {
  const db = getDatabase();
  const inserted = db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,'combined',?,?,0,30000,?,'de')`)
    .run(crypto.randomUUID(), userId, chunkId, startedAt, endedAt, text);
  const document = db.prepare(`INSERT INTO search_documents (user_id,kind,source_id,body,occurred_at,importance,text_hash)
    VALUES (?,'segment',?,?,?,0,?) RETURNING id`)
    .get(userId, String(inserted.lastInsertRowid), text, startedAt, crypto.createHash('sha256').update(text).digest('hex'));
  const embedding = SUBJECTS[subject];
  db.prepare(`INSERT INTO search_embeddings (document_id,user_id,model_revision,dimensions,embedding,text_hash)
    VALUES (?,?,'test',?,?,?)`).run(document.id, userId, embedding.length, Buffer.from(embedding.buffer.slice(0)),
    crypto.createHash('sha256').update(text).digest('hex'));
  return inserted.lastInsertRowid;
}

function liveChunk(recording, sequence, offsetMs) {
  const db = getDatabase();
  const chunkId = crypto.randomUUID();
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,
    channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_sha256,transcript_segment_count,persisted_at,server_deleted_at)
    VALUES (?,?,?,?,?,?,?,1,'wav','pcm_s16le','mono',?,?,30000,'transcribed',?,1,?,?)`)
    .run(chunkId, recording.userId, recording.sessionId, recording.sourceId, sequence, chunkId, 'a'.repeat(64),
      iso(offsetMs), sequence * 30_000, 'b'.repeat(64), iso(offsetMs), iso(offsetMs));
  db.prepare('UPDATE recording_sources SET contiguous_terminal_sequence=? WHERE id=?').run(sequence, recording.sourceId);
  return chunkId;
}

function conversations(userId) {
  return getDatabase().prepare(`SELECT c.id,c.started_at,c.ended_at,
    (SELECT COUNT(*) FROM transcript_segments t WHERE t.conversation_id=c.id) segments
    FROM conversations c WHERE c.user_id=? ORDER BY c.started_at`).all(userId);
}

// A meeting: a minute of speech at a time, an ordinary pause between two of
// them, and — where `breakAfter` says so — a break long enough to have cut the
// recording under the old three-minute rule but far short of a separate
// sitting. `subjectAt` says what each stretch is about.
const SPEECH_MS = 60_000;
const PAUSE_MS = 60_000;
const BREAK_MS = 420_000;

function meeting(recording, { utterances, breakAfter = new Set(), subjectAt = () => 0 }) {
  const offsets = [];
  let cursor = 0;
  for (let index = 0; index < utterances; index += 1) {
    offsets.push(cursor);
    cursor += SPEECH_MS + (breakAfter.has(index) ? BREAK_MS : PAUSE_MS);
  }
  // The last utterance ends a minute ago, so the recording still counts as
  // running and the final conversation is left open.
  const origin = -cursor;
  offsets.forEach((offsetMs, index) => {
    const chunkId = liveChunk(recording, index, offsetMs);
    utterance(recording.userId, chunkId, {
      startedAt: iso(origin + offsetMs),
      endedAt: iso(origin + offsetMs + SPEECH_MS),
      text: `Utterance ${index} of the meeting, long enough to carry a subject.`,
      subject: subjectAt(index),
    });
  });
}

test('a long live recording with ordinary pauses stays one conversation', async () => {
  const userId = await user('segmentation-live');
  const recording = liveSession(userId, iso(-3_600_000));
  // Twenty stretches of speech with two seven-minute breaks in them. Under the
  // old three-minute rule this one recording arrived as three conversations.
  meeting(recording, { utterances: 20, breakAfter: new Set([6, 13]) });

  await boundaryHandler.handle({ user_id: userId });
  const grouped = conversations(userId);
  assert.equal(grouped.length, 1, 'One recording, one conversation.');
  assert.equal(grouped[0].segments, 20, 'Every utterance belongs to it.');
});

test('a live recording splits where the subject changed, and only there', async () => {
  const userId = await user('segmentation-live-subject');
  const recording = liveSession(userId, iso(-3_600_000));
  meeting(recording, { utterances: 20, breakAfter: new Set([6, 13]), subjectAt: (index) => (index < 10 ? 0 : 1) });

  await boundaryHandler.handle({ user_id: userId });
  const grouped = conversations(userId);
  assert.equal(grouped.length, 2, 'The subject moved on once, so there is one boundary.');
  assert.deepEqual(grouped.map((row) => row.segments), [10, 10], 'And it sits where the subject changed.');
});

test('a single aside does not start a conversation of its own', async () => {
  const userId = await user('segmentation-live-aside');
  const recording = liveSession(userId, iso(-3_600_000));
  meeting(recording, { utterances: 20, breakAfter: new Set([6, 13]), subjectAt: (index) => (index === 11 ? 1 : 0) });

  await boundaryHandler.handle({ user_id: userId });
  assert.equal(conversations(userId).length, 1, 'One remark about something else is not a new conversation.');
});

// Everything above drives the live stream. The rest drives a prerecorded file
// through the real import handler, so the chunking a file is cut into is the
// shipping one rather than a number this test chose.
function wav(seconds) {
  const filename = path.join(process.env.NEORECALL_HOME, 'import_tmp', `${crypto.randomUUID()}.source`);
  const result = spawnSync(ffmpegPath, ['-v', 'error', '-f', 'lavfi', '-i', `sine=frequency=440:duration=${seconds}`,
    '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-f', 'wav', filename], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return filename;
}

async function importRecording(userId, seconds) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  const filename = wav(seconds);
  const bytes = fs.readFileSync(filename);
  db.prepare(`INSERT INTO imports (id,user_id,original_name,content_type,total_size,sha256,part_size,capture_time,timezone,state,temporary_path)
    VALUES (?,?,'meeting.wav','audio/wav',?,?,8388608,?,'UTC','assembled',?)`)
    .run(id, userId, bytes.length, crypto.createHash('sha256').update(bytes).digest('hex'),
      iso(-seconds * 1000 - 600_000), filename);
  return importHandler.handle({ resource_id: id, user_id: userId });
}

test('a prerecorded file is cut into chunks for transcription, not into conversations', async () => {
  const userId = await user('segmentation-import');
  const db = getDatabase();
  const result = await importRecording(userId, 600);

  // The file is cut at the configured chunk target — half a minute, not three
  // minutes — because that is a unit of transcription work.
  const chunks = db.prepare('SELECT * FROM audio_chunks WHERE user_id=? ORDER BY sequence').all(userId);
  assert.equal(chunks.length, result.chunks);
  assert.ok(chunks.length >= 19, `Ten minutes at ${getConfig().chunkTargetMs}ms per chunk is many chunks, got ${chunks.length}.`);
  for (const chunk of chunks) {
    assert.ok(chunk.duration_ms <= getConfig().chunkMaxMs, 'No chunk exceeds the transcription ceiling.');
  }

  // Transcribed, they are one continuous stretch of speech about one thing.
  for (const chunk of chunks) {
    const startedAt = new Date(Date.parse(chunk.device_started_at)).toISOString();
    utterance(userId, chunk.id, {
      startedAt,
      endedAt: new Date(Date.parse(startedAt) + chunk.duration_ms).toISOString(),
      text: `Chunk ${chunk.sequence} of one continuous recording about one subject.`,
      subject: 0,
    });
  }

  await boundaryHandler.handle({ user_id: userId });
  const grouped = conversations(userId);
  assert.equal(grouped.length, 1, `One file, one conversation — got ${grouped.length}.`);
  assert.equal(grouped[0].segments, chunks.length, 'Nothing was left out of it.');
});

test('the prerecorded flow splits on the same evidence the live flow does', async () => {
  const userId = await user('segmentation-import-subject');
  const db = getDatabase();
  await importRecording(userId, 900);
  const chunks = db.prepare('SELECT * FROM audio_chunks WHERE user_id=? ORDER BY sequence').all(userId);
  const half = Math.floor(chunks.length / 2);
  for (const chunk of chunks) {
    const startedAt = new Date(Date.parse(chunk.device_started_at)).toISOString();
    utterance(userId, chunk.id, {
      startedAt,
      endedAt: new Date(Date.parse(startedAt) + chunk.duration_ms).toISOString(),
      text: `Chunk ${chunk.sequence}, spoken about subject ${chunk.sequence < half ? 'one' : 'two'}.`,
      subject: chunk.sequence < half ? 0 : 1,
    });
  }

  await boundaryHandler.handle({ user_id: userId });
  const grouped = conversations(userId);
  assert.equal(grouped.length, 2, 'A subject that holds splits a file exactly as it splits a live stream.');
  assert.deepEqual(grouped.map((row) => row.segments), [half, chunks.length - half]);
});
