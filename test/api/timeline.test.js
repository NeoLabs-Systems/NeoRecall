'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-timeline-'));
// Writing a moment up again needs somewhere to send the request; without a
// configured model the service refuses, which is its own test below.
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_BASE_URL = 'http://127.0.0.1:9/v1';
process.env.AI_API_MODEL = 'test/model';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

/// An account with a usable session, made directly rather than through
/// registration: this file needs more accounts than the registration limiter
/// allows per minute, and none of these tests are about that limiter.
async function account(username) {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)')
    .run(userId, username, 'not-a-real-hash');
  const token = `nrs_${crypto.randomBytes(24).toString('base64url')}`;
  db.prepare(`INSERT INTO user_sessions (id,user_id,token_hash,expires_at)
    VALUES (?,?,?,?)`).run(crypto.randomUUID(), userId,
      crypto.createHash('sha256').update(token).digest('hex'),
      new Date(Date.now() + 3_600_000).toISOString());
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const chunkId = crypto.randomUUID();
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'D','test','desktop')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,device_ended_at,corrected_started_at,corrected_ended_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,?,?,'UTC',?,'ended')`)
    .run(sessionId, userId, deviceId, sessionId, '2026-08-01T10:00:00.000Z', '2026-08-06T11:00:00.000Z',
      '2026-08-01T10:00:00.000Z', '2026-08-06T11:00:00.000Z', '2026-08-01T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence,closed_at)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,0,?)`)
    .run(sourceId, sessionId, sourceId, '2026-08-06T11:00:00.000Z');
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,?,?,1,'wav','pcm_s16le','mono','2026-08-01T10:00:00.000Z',0,1000,'transcribed')`)
    .run(chunkId, userId, sessionId, sourceId, chunkId, crypto.randomBytes(32).toString('hex'));
  return { userId, chunkId, token };
}

function conversation(context, { day, index, state = 'consolidated', segments = 3, title = null }) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  const base = Date.UTC(2026, 7, day, 8 + index, 0, 0);
  db.prepare(`INSERT INTO conversations
    (id,user_id,started_at,ended_at,state,boundary_method,boundary_version,title_en,summary_en,topics_json,memory_worthy,insight_state,refined_at)
    VALUES (?,?,?,?,?,'test','1',?,?,?,1,'final',?)`)
    .run(id, context.userId, new Date(base).toISOString(), new Date(base + 1800000).toISOString(), state,
      title || `Day ${day} talk ${index}`, 'What was discussed.', '["Project"]',
      state === 'closed' ? null : new Date(base + 1900000).toISOString());
  const insert = db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,?,'combined',?,?,?,?,?,'en')`);
  for (let s = 0; s < segments; s += 1) {
    const at = new Date(base + s * 60000).toISOString();
    insert.run(crypto.randomUUID(), context.userId, context.chunkId, id, at, at, s * 1000, s * 1000 + 900,
      `line ${s} of day ${day} talk ${index}`);
  }
  return id;
}

test('the timeline is paged by moments, newest first, each one previewed', async () => {
  const context = await account('timeline-moments');
  for (let day = 1; day <= 6; day += 1) {
    for (let index = 0; index < 2; index += 1) conversation(context, { day, index, segments: 40 });
  }
  const auth = { Authorization: `Bearer ${context.token}` };
  const first = await request(app).get('/api/v1/conversations/timeline?limit=8').set(auth).expect(200);
  assert.equal(first.body.moments.length, 8, 'a page holds the requested number of moments');
  assert.equal(first.body.moments[0].titleEn, 'Day 6 talk 1', 'the newest moment comes first');
  // A page carries enough of each moment to recognise it and says how much
  // more there is. Sending every transcript in full would make each refresh
  // megabytes for moments nobody opened.
  assert.equal(first.body.moments[0].segments.length, 3);
  assert.equal(first.body.moments[0].segmentCount, 40);

  const second = await request(app).get(`/api/v1/conversations/timeline?limit=8&before=${first.body.nextCursor}`)
    .set(auth).expect(200);
  assert.equal(second.body.moments.length, 4, 'the last page holds what is left');
  const ids = [...first.body.moments, ...second.body.moments].map((moment) => moment.id);
  assert.equal(new Set(ids).size, 12, 'no moment is repeated or skipped across pages');
  assert.equal(second.body.nextCursor, null);
});

test('speech that has no conversation yet still opens the timeline', async () => {
  const context = await account('timeline-pending');
  conversation(context, { day: 1, index: 0 });
  const db = getDatabase();
  db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,NULL,'combined','2026-08-25T17:00:00.000Z','2026-08-25T17:00:30.000Z',0,30000,'just said this','en')`)
    .run(crypto.randomUUID(), context.userId, context.chunkId);
  const response = await request(app).get('/api/v1/conversations/timeline?limit=8')
    .set('Authorization', `Bearer ${context.token}`).expect(200);
  assert.equal(response.body.moments[0].kind, 'pending', 'the newest speech leads the timeline');
  assert.equal(response.body.moments[0].segments[0].text, 'just said this');
});

test('one account never sees another account moments', async () => {
  const mine = await account('timeline-mine');
  const theirs = await account('timeline-theirs');
  conversation(mine, { day: 1, index: 0 });
  conversation(theirs, { day: 1, index: 0 });
  const response = await request(app).get('/api/v1/conversations/timeline?limit=8')
    .set('Authorization', `Bearer ${mine.token}`).expect(200);
  assert.equal(response.body.moments.length, 1);
  assert.equal(response.body.moments[0].segments[0].user_id, mine.userId);
});

test('writing a moment up again clears its memory and puts it back in the queue', async () => {
  const context = await account('timeline-reprocess');
  const conversationId = conversation(context, { day: 2, index: 0 });
  const db = getDatabase();
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at)
    VALUES ('run-x',?,'succeeded','2026-08-02T09:00:00.000Z')`).run(context.userId);
  const memory = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,'meeting','Old write-up','Stale summary.','📝',5,'2026-08-02T10:00:00.000Z','2026-08-02T10:30:00.000Z','run-x')
    RETURNING id`).get(crypto.randomUUID(), context.userId);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id) VALUES (?,?)').run(memory.id, conversationId);

  const response = await request(app).post(`/api/v1/conversations/${conversationId}/reprocess`)
    .set('Authorization', `Bearer ${context.token}`).expect(202);
  assert.equal(response.body.replacedMemories, 1);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM memories WHERE user_id=?').get(context.userId).c, 0,
    'the superseded memory is gone rather than duplicated');
  const after = db.prepare('SELECT * FROM conversations WHERE id=?').get(conversationId);
  assert.equal(after.state, 'closed', 'the conversation waits to be written up again');
  assert.equal(after.refined_at, null);
  assert.equal(after.title_en, 'Day 2 talk 0', 'the existing write-up stays on screen until a new one lands');
  // The transcript is the record and is never part of what gets rebuilt.
  assert.equal(db.prepare('SELECT COUNT(*) c FROM transcript_segments WHERE conversation_id=?').get(conversationId).c, 3);
});

test('a memory built from several conversations survives a single moment being redone', async () => {
  const context = await account('timeline-shared-memory');
  const first = conversation(context, { day: 3, index: 0 });
  const second = conversation(context, { day: 3, index: 1 });
  const db = getDatabase();
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at)
    VALUES ('run-y',?,'succeeded','2026-08-03T09:00:00.000Z')`).run(context.userId);
  const memory = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,'meeting','Shared write-up','Covers both.','📝',5,'2026-08-03T10:00:00.000Z','2026-08-03T12:00:00.000Z','run-y')
    RETURNING id`).get(crypto.randomUUID(), context.userId);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id) VALUES (?,?)').run(memory.id, first);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id) VALUES (?,?)').run(memory.id, second);

  const response = await request(app).post(`/api/v1/conversations/${first}/reprocess`)
    .set('Authorization', `Bearer ${context.token}`).expect(202);
  assert.equal(response.body.replacedMemories, 0);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM memories WHERE user_id=?').get(context.userId).c, 1,
    'material from a conversation nobody asked to redo is not thrown away');
});

test('a conversation that is still recording cannot be written up again', async () => {
  const context = await account('timeline-open');
  const id = conversation(context, { day: 4, index: 0, state: 'open' });
  await request(app).post(`/api/v1/conversations/${id}/reprocess`)
    .set('Authorization', `Bearer ${context.token}`).expect(409);
});

test('another account cannot write up a conversation it does not own', async () => {
  const owner = await account('timeline-owner');
  const outsider = await account('timeline-outsider');
  const id = conversation(owner, { day: 5, index: 0 });
  await request(app).post(`/api/v1/conversations/${id}/reprocess`)
    .set('Authorization', `Bearer ${outsider.token}`).expect(404);
});

test('a moment is not stripped of its write-up when no model could replace it', async () => {
  const context = await account('timeline-no-model');
  const conversationId = conversation(context, { day: 6, index: 0 });
  const db = getDatabase();
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at)
    VALUES ('run-z',?,'succeeded','2026-08-06T09:00:00.000Z')`).run(context.userId);
  const memory = db.prepare(`INSERT INTO memories
    (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
    VALUES (?,?,'meeting','Keep me','Still the only write-up.','📝',5,'2026-08-06T10:00:00.000Z','2026-08-06T10:30:00.000Z','run-z')
    RETURNING id`).get(crypto.randomUUID(), context.userId);
  db.prepare('INSERT INTO memory_sources (memory_id,conversation_id) VALUES (?,?)').run(memory.id, conversationId);
  // No endpoint to send anything to.
  db.prepare("INSERT INTO app_settings (key,value_json) VALUES ('providers.llm',?)")
    .run(JSON.stringify({ provider: 'openai_compatible', baseUrl: '', model: '' }));
  try {
    await request(app).post(`/api/v1/conversations/${conversationId}/reprocess`)
      .set('Authorization', `Bearer ${context.token}`).expect(409);
    assert.equal(db.prepare('SELECT COUNT(*) c FROM memories WHERE user_id=?').get(context.userId).c, 1,
      'nothing is removed when nothing can be generated to replace it');
    assert.equal(db.prepare('SELECT state FROM conversations WHERE id=?').get(conversationId).state, 'consolidated');
  } finally {
    db.prepare("DELETE FROM app_settings WHERE key='providers.llm'").run();
  }
});

test('opening a moment returns everything that was said in it', async () => {
  const context = await account('timeline-open-moment');
  const conversationId = conversation(context, { day: 1, index: 0, segments: 40 });
  const auth = { Authorization: `Bearer ${context.token}` };
  const response = await request(app).get(`/api/v1/conversations/${conversationId}/segments`)
    .set(auth).expect(200);
  assert.equal(response.body.segments.length, 40, 'the whole conversation, not a preview');
  assert.equal(response.body.segmentCount, 40);
  assert.equal(response.body.truncated, false);
  assert.equal(response.body.segments[0].text, 'line 0 of day 1 talk 0', 'in the order it was spoken');
});

test('ungrouped speech can be opened as well', async () => {
  const context = await account('timeline-open-pending');
  const db = getDatabase();
  const insert = db.prepare(`INSERT INTO transcript_segments
    (public_id,user_id,chunk_id,conversation_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
    VALUES (?,?,?,NULL,'combined',?,?,?,?,?,'en')`);
  for (let index = 0; index < 5; index += 1) {
    const at = new Date(Date.UTC(2026, 7, 25, 17, index, 0)).toISOString();
    insert.run(crypto.randomUUID(), context.userId, context.chunkId, at, at, index * 1000, index * 1000 + 900, `fresh line ${index}`);
  }
  const response = await request(app).get('/api/v1/conversations/pending/segments')
    .set('Authorization', `Bearer ${context.token}`).expect(200);
  assert.equal(response.body.segments.length, 5);
  assert.equal(response.body.segments[0].text, 'fresh line 0');
});

test('one account cannot open another account moment', async () => {
  const owner = await account('segments-owner');
  const outsider = await account('segments-outsider');
  const conversationId = conversation(owner, { day: 1, index: 0 });
  await request(app).get(`/api/v1/conversations/${conversationId}/segments`)
    .set('Authorization', `Bearer ${outsider.token}`).expect(404);
});
