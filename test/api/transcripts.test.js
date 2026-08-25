'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-transcripts-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

/// Builds one account whose history is longer than a page, so the newest
/// segments are the ones a single unpaged request can miss.
async function accountWithHistory(username, segmentCount) {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username, password: 'a long and unique password' }).expect(201);
  const token = registration.body.session.token;
  const db = getDatabase();
  const userId = db.prepare('SELECT id FROM users WHERE username=?').get(username).id;
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'D','test','desktop')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?,'UTC',?,'ended')`)
    .run(sessionId, userId, deviceId, sessionId, '2026-08-01T10:00:00.000Z', '2026-08-01T11:00:00.000Z',
      '2026-08-01T10:00:00.000Z', '2026-08-01T11:00:00.000Z', '2026-08-01T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence,closed_at)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,0,?)`)
    .run(sourceId, sessionId, sourceId, '2026-08-01T11:00:00.000Z');
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono','2026-08-01T10:00:00.000Z',0,1000,'transcribed')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, crypto.randomBytes(32).toString('hex'));
  const insert = db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,'combined',?,?,?,?,?,'en')`);
  for (let index = 0; index < segmentCount; index += 1) {
    const at = new Date(Date.UTC(2026, 7, 1, 10, 0, 0) + index * 60000).toISOString();
    insert.run(crypto.randomUUID(), userId, chunkId, at, at, index * 1000, index * 1000 + 900, `utterance ${index}`);
  }
  return { userId, token, segmentCount };
}

test('a long history still shows what was just recorded', async () => {
  const account = await accountWithHistory('transcripts-recent', 150);
  const response = await request(app).get('/api/v1/transcripts?limit=100')
    .set('Authorization', `Bearer ${account.token}`).expect(200);
  const texts = response.body.items.map((item) => item.text);
  assert.equal(texts.length, 100);
  // The most recent utterance is the whole point of a timeline.
  assert.ok(texts.includes('utterance 149'), 'the newest segment must be on the first page');
  assert.ok(!texts.includes('utterance 0'), 'the first page is not the start of the account history');
});

test('paging walks backwards through the history without repeating or skipping', async () => {
  const account = await accountWithHistory('transcripts-paging', 150);
  const auth = { Authorization: `Bearer ${account.token}` };
  const first = await request(app).get('/api/v1/transcripts?limit=100').set(auth).expect(200);
  assert.ok(first.body.nextCursor, 'a longer history offers another page');
  const second = await request(app).get(`/api/v1/transcripts?limit=100&before=${first.body.nextCursor}`)
    .set(auth).expect(200);
  const ids = [...first.body.items, ...second.body.items].map((item) => item.id);
  assert.equal(new Set(ids).size, 150, 'every segment appears exactly once across the two pages');
  assert.equal(second.body.nextCursor, null, 'the history ends after the second page');
});

test('walking the history forward stays available for callers that want it', async () => {
  const account = await accountWithHistory('transcripts-ascending', 5);
  const auth = { Authorization: `Bearer ${account.token}` };
  const ascending = await request(app).get('/api/v1/transcripts?order=asc&limit=3').set(auth).expect(200);
  assert.deepEqual(ascending.body.items.map((item) => item.text), ['utterance 0', 'utterance 1', 'utterance 2']);
  const next = await request(app).get(`/api/v1/transcripts?order=asc&limit=3&after=${ascending.body.nextCursor}`)
    .set(auth).expect(200);
  assert.deepEqual(next.body.items.map((item) => item.text), ['utterance 3', 'utterance 4']);
});

test('one account never sees another account transcripts', async () => {
  const mine = await accountWithHistory('transcripts-mine', 3);
  const theirs = await accountWithHistory('transcripts-theirs', 3);
  const response = await request(app).get('/api/v1/transcripts?limit=100')
    .set('Authorization', `Bearer ${mine.token}`).expect(200);
  assert.equal(response.body.items.length, 3);
  assert.ok(response.body.items.every((item) => item.user_id === mine.userId));
  assert.ok(!response.body.items.some((item) => item.user_id === theirs.userId));
});
