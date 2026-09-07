'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-occasion-'));

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const occasion = require('../../server/services/memories/memory_occasion_service');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const NOW = Date.parse('2026-08-01T12:00:00.000Z');
const MINUTE = 60_000;

function at(minutesAgo) {
  return new Date(NOW - minutesAgo * MINUTE).toISOString();
}

// A conversation as buildCandidates hands it over: identity, stream, span, size.
function fragment(startMinutesAgo, endMinutesAgo, { sessionId = 'stream-a', characters = 100 } = {}) {
  return {
    id: crypto.randomUUID(),
    sessionId,
    startedAt: at(startMinutesAgo),
    endedAt: at(endMinutesAgo),
    characters,
  };
}

const LIMITS = Object.freeze({
  occasionGapMs: 15 * MINUTE,
  maxConversations: 12,
  maxCharacters: 250_000,
  maxSpanMs: 4 * 60 * MINUTE,
});

test('fragments of one sitting chain together and a later sitting does not', () => {
  const first = fragment(40, 38);
  const second = fragment(34, 32);
  const later = fragment(10, 8);
  const chained = occasion.chain([first, second, later], LIMITS);
  assert.deepEqual(chained.conversations.map((item) => item.id), [first.id, second.id],
    'Four-minute pauses stay one occasion; a twenty-two-minute gap starts another.');
  assert.equal(chained.characters, 200);
});

test('a chain never crosses recording streams', () => {
  const first = fragment(40, 38);
  const other = fragment(37, 35, { sessionId: 'stream-b' });
  assert.deepEqual(occasion.chain([first, other], LIMITS).conversations.map((item) => item.id), [first.id],
    'A second device recording at the same moment is not the same input.');
});

test('the chain stops at the conversation, character and duration ceilings', () => {
  const many = [fragment(40, 38), fragment(37, 35), fragment(34, 32)];
  assert.equal(occasion.chain(many, { ...LIMITS, maxConversations: 2 }).conversations.length, 2);
  assert.equal(occasion.chain(many, { ...LIMITS, maxCharacters: 150 }).conversations.length, 1);
  assert.equal(occasion.chain(many, { ...LIMITS, maxSpanMs: 5 * MINUTE }).conversations.length, 2);
});

test('the oldest fragment is always carried, however large it is on its own', () => {
  // The backlog drains oldest-first. A single conversation larger than the whole
  // budget must still be carried, or it blocks every later memory forever.
  const huge = fragment(40, 38, { characters: 900_000 });
  assert.deepEqual(occasion.chain([huge, fragment(37, 35)], LIMITS).conversations.map((item) => item.id), [huge.id]);
});

// The readiness cases need real rows: they are answered from the recording, not
// from the fragments handed in.
function recording(userId, sessionId, { lastUploadMinutesAgo = 0 } = {}) {
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO users(id,username,password_hash,created_at) VALUES (?,?,'x',?)").run(userId, userId, at(600));
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, at(600), at(600), at(600));
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0)`).run(sourceId, sessionId, sourceId);
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,
    channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,uploaded_at)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono',?,0,30000,'transcribed',?)`)
    .run(crypto.randomUUID(), userId, sessionId, sourceId, crypto.randomUUID(), 'a'.repeat(64), at(600), at(lastUploadMinutesAgo));
  return { userId, sessionId };
}

// A conversation row that is not a consolidation candidate — still open, or
// still being transcribed — but may still belong to the occasion.
function pendingConversation(userId, sessionId, startMinutesAgo, endMinutesAgo, { quarantined = false } = {}) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  const chunk = db.prepare('SELECT id FROM audio_chunks WHERE session_id=? LIMIT 1').get(sessionId);
  db.prepare(`INSERT INTO conversations(id,user_id,started_at,ended_at,state,boundary_method,boundary_version,quarantined_at)
    VALUES (?,?,?,?,'open','gap',1,?)`).run(id, userId, at(startMinutesAgo), at(endMinutesAgo), quarantined ? at(1) : null);
  db.prepare(`INSERT INTO transcript_segments(public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,?,'combined',?,?,0,30000,'x','de')`).run(crypto.randomUUID(), userId, chunk.id, id, at(startMinutesAgo), at(endMinutesAgo));
  return id;
}

const OPTIONS = Object.freeze({
  memoryOccasionGapMs: 15 * MINUTE,
  memorySettleMs: 8 * MINUTE,
  memoryOccasionMaxWaitMs: 60 * MINUTE,
});

test('a sitting is held back while its recording is still running', () => {
  const { userId, sessionId } = recording(crypto.randomUUID(), crypto.randomUUID());
  const chained = [fragment(20, 18, { sessionId }), fragment(14, 2, { sessionId })];
  const held = occasion.readiness(userId, chained, OPTIONS, getDatabase(), NOW);
  assert.equal(held.ready, false);
  assert.equal(held.reason, 'occasion_unsettled');
  assert.equal(held.consolidateAfter, new Date(NOW + 6 * MINUTE).toISOString(),
    'It waits the settle delay from the last speech, not from now.');
});

test('a stopped recording is written up at once', () => {
  const { userId, sessionId } = recording(crypto.randomUUID(), crypto.randomUUID(), { lastUploadMinutesAgo: 30 });
  const ready = occasion.readiness(userId, [fragment(20, 2, { sessionId })], OPTIONS, getDatabase(), NOW);
  assert.deepEqual(ready, { ready: true, reason: 'recording_stopped' },
    'A conversation that just ended is the one someone is about to look for.');
});

test('a quiet stretch settles even while the recording continues', () => {
  const { userId, sessionId } = recording(crypto.randomUUID(), crypto.randomUUID());
  const ready = occasion.readiness(userId, [fragment(30, 20, { sessionId })], OPTIONS, getDatabase(), NOW);
  assert.equal(ready.ready, true);
  assert.equal(ready.reason, 'settled');
});

test('a fragment that is still transcribing holds its occasion back, and one beyond the gap releases it', () => {
  const inside = recording(crypto.randomUUID(), crypto.randomUUID(), { lastUploadMinutesAgo: 30 });
  pendingConversation(inside.userId, inside.sessionId, 18, 16);
  const held = occasion.readiness(inside.userId, [fragment(30, 22, { sessionId: inside.sessionId })], OPTIONS, getDatabase(), NOW);
  assert.equal(held.ready, false, 'A successor inside the occasion gap is still part of this sitting.');
  assert.equal(held.reason, 'occasion_unsettled');

  const apart = recording(crypto.randomUUID(), crypto.randomUUID(), { lastUploadMinutesAgo: 30 });
  pendingConversation(apart.userId, apart.sessionId, 4, 2);
  const released = occasion.readiness(apart.userId, [fragment(30, 22, { sessionId: apart.sessionId })], OPTIONS, getDatabase(), NOW);
  assert.equal(released.ready, true, 'A successor beyond the gap proves this occasion ended.');
  assert.equal(released.reason, 'occasion_ended');
});

test('a quarantined successor never holds an occasion back', () => {
  // It will never become a candidate, so waiting for it would stop this user's
  // memories for good.
  const { userId, sessionId } = recording(crypto.randomUUID(), crypto.randomUUID(), { lastUploadMinutesAgo: 30 });
  pendingConversation(userId, sessionId, 18, 16, { quarantined: true });
  assert.equal(occasion.readiness(userId, [fragment(30, 22, { sessionId })], OPTIONS, getDatabase(), NOW).ready, true);
});

test('nothing is held back past the maximum wait', () => {
  // An always-on recording never stops and a talkative day never goes quiet.
  const { userId, sessionId } = recording(crypto.randomUUID(), crypto.randomUUID());
  pendingConversation(userId, sessionId, 50, 48);
  const forced = occasion.readiness(userId, [fragment(90, 70, { sessionId })], OPTIONS, getDatabase(), NOW);
  assert.deepEqual(forced, { ready: true, reason: 'waited' });
});
