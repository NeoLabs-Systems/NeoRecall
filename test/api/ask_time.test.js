'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-ask-time-'));
const embeddings = require('../../server/embeddings/embedding_service');
embeddings.embed = async () => { const vector = new Float32Array(384); vector[0] = 1; return vector; };
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const aiEngine = require('../../server/ai/ai_engine');
const settings = require('../../server/services/settings/settings_service');

const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('a question about a day is answered from that day in the user\'s timezone', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ask-today', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  settings.update(userId, { timezone: 'Europe/Berlin' });

  const insert = getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,'memory',?,?,?,?,?,?)`);
  // 00:30 Berlin on the 13th is still the 12th in UTC: a day window that is not
  // converted through the user's timezone loses this one.
  insert.run(userId, 'm1', 'Früher Start', 'Um halb eins noch am Rechner gesessen.', '2026-07-12T22:30:00.000Z', 4, 'h1');
  insert.run(userId, 'm2', 'Dach', 'Angebot für das Dach besprochen.', '2026-07-13T09:00:00.000Z', 6, 'h2');
  insert.run(userId, 'm3', 'Vortag', 'Der Tag davor, ohne Bezug.', '2026-07-12T09:00:00.000Z', 6, 'h3');

  const asked = [];
  aiEngine.planQuery = async (_userId, input) => {
    asked.push(input);
    return { value: { searchQueries: ['Tagesverlauf'], fromLocal: '2026-07-13T00:00:00', toLocal: '2026-07-14T00:00:00', kinds: [], wholePeriod: true } };
  };
  let seen = null;
  aiEngine.answer = async (_userId, question, context, beforeAttempt, frame) => {
    beforeAttempt();
    seen = { context, frame };
    return { value: { answer: 'Zwei Dinge.', citations: context.map((item) => ({ sourceId: item.sourceId })) }, requestId: 'test' };
  };

  const response = await request(app).post('/api/v1/search/ask').set(auth).send({ question: 'Was habe ich heute gemacht?' }).expect(200);

  assert.equal(asked.length, 1);
  assert.equal(asked[0].timezone, 'Europe/Berlin');
  assert.match(asked[0].nowLocal, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/);
  assert.deepEqual(seen.context.map((item) => item.sourceId).sort(), ['memory:m1', 'memory:m2']);
  assert.equal(seen.frame.timezone, 'Europe/Berlin');
  assert.deepEqual(seen.frame.period, { fromLocal: '2026-07-13T00:00:00', toLocal: '2026-07-14T00:00:00' });
  assert.equal(response.body.retrieval.considered, 2);
  assert.equal(response.body.retrieval.wholePeriod, true);
  assert.equal(response.body.citations.length, 2);
  assert.ok(response.body.citations.every((citation) => typeof citation.relevance === 'number' && citation.title));
});

test('a plan the model could not produce still answers the question as written', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ask-fallback', password: 'a long and unique password' }).expect(201);
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,'memory','f1','Dach','Angebot für das Dach besprochen.','2026-07-13T09:00:00.000Z',6,'hf1')`).run(registration.body.user.id);

  aiEngine.planQuery = async () => { throw Object.assign(new Error('down'), { code: 'AI_TIMEOUT' }); };
  let seen = null;
  aiEngine.answer = async (_userId, question, context, beforeAttempt) => {
    beforeAttempt();
    seen = context;
    return { value: { answer: 'Ja.', citations: [] }, requestId: 'test' };
  };

  await request(app).post('/api/v1/search/ask').set(auth).send({ question: 'Angebot' }).expect(200);
  assert.deepEqual(seen.map((item) => item.sourceId), ['memory:f1']);
});

test('the written record answers the day, not the day\'s raw speech', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ask-layers', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  settings.update(userId, { timezone: 'Europe/Berlin' });

  const insert = getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,?,?,?,?,?,?,?)`);
  // A day of recording is overwhelmingly segments: without a layered read they
  // fill every slot and the memories written from them never reach the answer.
  for (let index = 0; index < 30; index += 1) {
    const minute = String(index).padStart(2, '0');
    insert.run(userId, 'segment', `s${index}`, null, `Gesprochener Satz ${index}.`, `2026-07-13T10:${minute}:00.000Z`, 0, `hs${index}`);
  }
  insert.run(userId, 'memory', 'm1', 'Dach', 'Angebot für das Dach besprochen.', '2026-07-13T09:00:00.000Z', 6, 'hm1');
  insert.run(userId, 'memory', 'm2', 'Spaziergang', 'Langer Spaziergang am Nachmittag.', '2026-07-13T16:00:00.000Z', 4, 'hm2');

  aiEngine.planQuery = async () => ({ value: {
    searchQueries: ['Tagesverlauf'], fromLocal: '2026-07-13T00:00:00', toLocal: '2026-07-14T00:00:00', kinds: [], wholePeriod: true,
  } });
  let seen = null;
  aiEngine.answer = async (_userId, question, context, beforeAttempt) => {
    beforeAttempt();
    seen = context;
    return { value: { answer: 'Zwei Dinge.', citations: [] }, requestId: 'test' };
  };

  await request(app).post('/api/v1/search/ask').set(auth).send({ question: 'Was habe ich heute gemacht?' }).expect(200);

  const kinds = seen.map((item) => item.kind);
  assert.deepEqual(seen.slice(0, 2).map((item) => item.sourceId), ['memory:m1', 'memory:m2']);
  assert.equal(kinds.filter((kind) => kind === 'segment').length, 4);
});

test('an empty period reports the archive rather than reporting that nothing happened', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ask-empty-period', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  settings.update(userId, { timezone: 'Europe/Berlin' });
  getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,'memory','e1','Vorgestern','Etwas älteres.','2026-07-11T09:00:00.000Z',5,'he1')`).run(userId);

  aiEngine.planQuery = async () => ({ value: {
    searchQueries: ['Tagesverlauf'], fromLocal: '2026-07-13T00:00:00', toLocal: '2026-07-14T00:00:00', kinds: [], wholePeriod: true,
  } });
  let frame = null;
  aiEngine.answer = async (_userId, question, context, beforeAttempt, given) => {
    beforeAttempt();
    frame = given;
    assert.deepEqual(context, []);
    return { value: { answer: 'Für heute ist nichts festgehalten.', citations: [] }, requestId: 'test' };
  };

  const response = await request(app).post('/api/v1/search/ask').set(auth).send({ question: 'Was habe ich heute gemacht?' }).expect(200);
  assert.equal(frame.archive.holdsNothingForThePeriod, true);
  assert.equal(frame.archive.latestActivityAt, '2026-07-11T09:00:00.000Z');
  assert.equal(response.body.retrieval.timezone, 'Europe/Berlin');
});

test('a kind restriction that finds nothing is lifted rather than answered as an empty archive', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ask-kind-widen', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,'memory','k1','Dach','Angebot für das Dach besprochen.','2026-07-13T09:00:00.000Z',6,'hk1')`).run(userId);

  // The day has no daily summary yet — it is written when the day is
  // consolidated — so a plan that asks for one alone must not end the search.
  aiEngine.planQuery = async () => ({ value: {
    searchQueries: ['Dach'], fromLocal: null, toLocal: null, kinds: ['daily_summary'], wholePeriod: false,
  } });
  let seen = null;
  aiEngine.answer = async (_userId, question, context, beforeAttempt) => {
    beforeAttempt();
    seen = context;
    return { value: { answer: 'Ja.', citations: [] }, requestId: 'test' };
  };

  await request(app).post('/api/v1/search/ask').set(auth).send({ question: 'Was war mit dem Dach?' }).expect(200);
  assert.deepEqual(seen.map((item) => item.sourceId), ['memory:k1']);
});
