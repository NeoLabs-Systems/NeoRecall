'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');
const express = require('express');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-neorouter-'));
process.env.NEORECALL_NEOROUTER_OFFER_CACHE_MS = '0';

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();

const KEY = 'nrt_fake_key_for_tests';
let fake;
let address;
let approved = false;
let online = true;
let seen;

// A NeoRouter as NeoRecall sees it: the device sign-in and the /v1 endpoints.
function fakeNeoRouter() {
  const router = express();
  router.use((req, res, next) => (online ? next() : req.socket.destroy()));
  router.use(express.urlencoded({ extended: false }), express.json());
  router.post('/oauth/device/code', (req, res) => {
    seen = { device: req.body };
    res.json({ device_code: 'dev-code', user_code: 'ABCD-EFGH', interval: 1, expires_in: 600, verification_uri_complete: `${address}/app/?connect=req1` });
  });
  router.post('/oauth/token', (req, res) => {
    if (req.body.device_code !== 'dev-code' || req.body.client_id !== 'neorecall') return res.status(400).json({ error: 'invalid_grant' });
    if (!approved) return res.status(400).json({ error: 'authorization_pending' });
    return res.json({ access_token: KEY, token_type: 'Bearer' });
  });
  const auth = (req, res, next) => (req.get('authorization') === `Bearer ${KEY}` ? next() : res.status(401).json({ error: { message: 'bad key' } }));
  const lists = {
    chat: [{ id: 'auto', name: 'Auto' }, { id: 'auto-free:fast', name: 'Auto (Fastest, free models only)' }, { id: 'groq/llama-4' }, { id: 'openai/gpt-x' }],
    transcription: [{ id: 'auto' }, { id: 'groq/whisper-large-v3' }],
    embedding: [{ id: 'nvidia/embed' }],
  };
  router.get('/v1/models', auth, (req, res) => res.json({
    object: 'list', data: lists[req.query.type] || [],
    neorouter: { not_allowed_for_key: req.query.type === 'embedding' ? { free: 0, plan: 0, paid: 4 } : {} },
  }));
  router.post('/v1/chat/completions', auth, (req, res) => {
    seen = { chat: req.body };
    res.json({ id: 'c1', choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ answer: 'ready' }) } }], usage: { prompt_tokens: 3, completion_tokens: 2 } });
  });
  router.post('/v1/audio/transcriptions', auth, express.raw({ type: () => true, limit: '20mb' }), (req, res) => {
    seen = { transcription: { contentType: req.get('content-type'), bytes: req.body.length } };
    res.json({ text: 'hello world', language: 'en', duration: 2, segments: [{ start: 0, end: 2, text: 'hello world' }] });
  });
  router.post('/v1/embeddings', auth, (req, res) => {
    seen = { embeddings: req.body };
    // Two components, ignoring `dimensions` on purpose except for its size: the client must normalize.
    const vector = Array.from({ length: req.body.dimensions }, (_, index) => (index === 0 ? 3 : index === 1 ? 4 : 0));
    res.set('X-NeoRouter-Embedding-Pin', 'nvidia/embed').json({ model: 'nvidia-2/embed', data: [{ index: 0, embedding: vector }] });
  });
  return new Promise((resolve) => { const server = http.createServer(router).listen(0, '127.0.0.1', () => resolve(server)); });
}

test.before(async () => {
  fake = await fakeNeoRouter();
  address = `http://127.0.0.1:${fake.address().port}`;
});
test.after(async () => {
  await new Promise((resolve) => fake.close(resolve));
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const bearer = (token) => ({ Authorization: `Bearer ${token}` });
async function register(username) {
  const response = await request(app).post('/api/v1/auth/register').send({ username, password: 'a long and unique password' }).expect(201);
  return { id: response.body.user.id, token: response.body.session.token };
}
async function waitFor(check) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    const value = await check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('timed out');
}

let admin;
let member;

test('only an admin can connect NeoRouter, and nothing is connected at first', async () => {
  admin = await register('router-admin');
  member = await register('router-member');
  await request(app).get('/api/v1/admin/neorouter').set(bearer(member.token)).expect(403);
  await request(app).post('/api/v1/admin/neorouter/connect').set(bearer(member.token)).send({ address }).expect(403);
  const state = await request(app).get('/api/v1/admin/neorouter').set(bearer(admin.token)).expect(200);
  assert.equal(state.body.connected, false);
  assert.deepEqual(state.body.roles, []);
});

test('a wrong or unreachable address is reported plainly', async () => {
  const bad = await request(app).post('/api/v1/admin/neorouter/connect').set(bearer(admin.token)).send({ address: 'http://127.0.0.1:9' }).expect(400);
  assert.match(bad.body.error.message, /Could not reach NeoRouter/);
});

test('connecting stores the key encrypted and puts every kind of work on the router', async () => {
  const started = await request(app).post('/api/v1/admin/neorouter/connect').set(bearer(admin.token)).send({ address }).expect(200);
  assert.match(started.body.url, /connect=req1/);
  assert.equal(started.body.userCode, 'ABCD-EFGH');
  assert.equal(seen.device.client_id, 'neorecall');
  assert.equal(seen.device.scope, 'chat transcription embedding');
  await request(app).get(`/api/v1/admin/neorouter/connect/${started.body.id}`).set(bearer(member.token)).expect(403);
  const pending = await request(app).get(`/api/v1/admin/neorouter/connect/${started.body.id}`).set(bearer(admin.token)).expect(200);
  assert.equal(pending.body.status, 'pending');
  approved = true;
  const done = await waitFor(async () => {
    const response = await request(app).get(`/api/v1/admin/neorouter/connect/${started.body.id}`).set(bearer(admin.token));
    return response.body.status !== 'pending' ? response.body : null;
  });
  assert.equal(done.status, 'completed', JSON.stringify(done));
  await request(app).get(`/api/v1/admin/neorouter/connect/${started.body.id}`).set(bearer(admin.token)).expect(404);

  const rows = getDatabase().prepare("SELECT key,value_json FROM app_settings WHERE key LIKE 'neorouter.%'").all();
  assert.ok(!rows.some((row) => row.value_json.includes(KEY)), 'the key is never stored in clear');
  const state = await request(app).get('/api/v1/admin/neorouter').set(bearer(admin.token)).expect(200);
  assert.deepEqual(state.body.roles.sort(), ['embeddings', 'llm', 'transcription']);
  assert.equal(state.body.reachable, true);
  assert.deepEqual(state.body.offer.roles.llm, { models: 2, auto: 2 });
  assert.equal(state.body.offer.notAllowed.embeddings, 4, 'models the key may not use are reported');
  assert.ok(!JSON.stringify(state.body).includes(KEY));

  const settings = await request(app).get('/api/v1/admin/provider-settings').set(bearer(admin.token)).expect(200);
  assert.equal(settings.body.settings.llm.provider, 'neorouter');
  assert.equal(settings.body.settings.transcription.provider, 'neorouter');
  assert.equal(settings.body.settings.llm.baseUrl, `${address}/v1`);
  assert.ok(!JSON.stringify(settings.body).includes(KEY));
  const catalog = settings.body.settings.catalogs.llm.find((entry) => entry.id === 'neorouter');
  assert.equal(catalog.neorouter, true);
});

test('NeoRouter lists its own models, auto first, per kind of work', async () => {
  const llm = await request(app).post('/api/v1/admin/provider-settings/models').set(bearer(admin.token)).send({ workload: 'llm', provider: 'neorouter' }).expect(200);
  assert.deepEqual(llm.body.models, ['auto', 'auto-free:fast', 'groq/llama-4', 'openai/gpt-x']);
  const stt = await request(app).post('/api/v1/admin/provider-settings/models').set(bearer(admin.token)).send({ workload: 'transcription', provider: 'neorouter' }).expect(200);
  assert.deepEqual(stt.body.models, ['auto', 'groq/whisper-large-v3']);
});

test('summaries and chat run against the router with its auto model', async () => {
  const provider = require('../../server/ai/provider_registry').provider();
  assert.equal(provider.ready(), true);
  const result = await provider.chatJSON({ userId: null, purpose: 'ask', messages: [{ role: 'user', content: 'hi' }] });
  assert.deepEqual(result.value, { answer: 'ready' });
  assert.equal(seen.chat.model, 'auto');
});

test('transcription goes through the router and a router outage fails the job instead of yielding silence', async () => {
  const transcription = require('../../server/transcription/provider_registry');
  transcription.resetForTests();
  const provider = transcription.getProvider();
  assert.equal(await provider.ready(), true);
  const segments = await provider.transcribe({ filename: path.join(__dirname, '..', 'fixtures', 'silence.wav'), channelLayout: 'mono' });
  assert.equal(segments.map((segment) => segment.text).join(' '), 'hello world');
  assert.ok(seen.transcription.bytes > 0);
  // An unreachable router must reject: an empty answer would read as "silence",
  // letting the pipeline persist nothing and then release the audio.
  online = false;
  await assert.rejects(() => provider.transcribe({ filename: path.join(__dirname, '..', 'fixtures', 'silence.wav'), channelLayout: 'mono' }));
  online = true;
});

test('search vectors come from the router at the index size, unit length, and are labelled by its pinned model', async () => {
  const embeddings = require('../../server/embeddings/embedding_service');
  const { vector, space } = await embeddings.embedDetailed('hello', 'passage');
  assert.equal(vector.length, 384);
  assert.equal(seen.embeddings.dimensions, 384);
  assert.equal(seen.embeddings.input_type, 'document');
  assert.ok(Math.abs(Math.hypot(...vector) - 1) < 1e-5);
  assert.equal(space, 'nvidia/embed', 'the pin, not the host that served this request');
  const query = await embeddings.embedDetailed('hello', 'query');
  assert.equal(seen.embeddings.input_type, 'query');
  assert.equal(query.space, space);

  const searchIndex = require('../../server/embeddings/search_index_service');
  const document = searchIndex.upsertDocument({ userId: admin.id, kind: 'memory', sourceId: 'm1', body: 'a memory', occurredAt: new Date().toISOString() });
  await searchIndex.embedDocuments([document.id]);
  assert.equal(getDatabase().prepare('SELECT model_revision FROM search_embeddings WHERE document_id=?').get(document.id).model_revision, 'neorouter:nvidia/embed@384');
});

test('search keeps answering from keywords while the router is unreachable', async () => {
  const search = require('../../server/services/search/search_service');
  online = false;
  try {
    const found = await search.search(admin.id, 'memory');
    assert.ok(Array.isArray(found.results || found));
  } finally {
    online = true;
  }
});

test('switching a kind of work off returns it to the server’s own configuration, and switching embeddings re-embeds', async () => {
  const before = getDatabase().prepare("SELECT COUNT(*) n FROM jobs WHERE type='embed_search_documents' AND resource_type='search_reindex'").get().n;
  const response = await request(app).put('/api/v1/admin/neorouter/roles').set(bearer(admin.token)).send({ roles: ['llm'] }).expect(200);
  assert.deepEqual(response.body.roles, ['llm']);
  const settings = await request(app).get('/api/v1/admin/provider-settings').set(bearer(admin.token)).expect(200);
  assert.equal(settings.body.settings.llm.provider, 'neorouter');
  assert.notEqual(settings.body.settings.transcription.provider, 'neorouter');
  const after = getDatabase().prepare("SELECT COUNT(*) n FROM jobs WHERE type='embed_search_documents' AND resource_type='search_reindex'").get().n;
  assert.ok(after > before, 'documents are embedded again with the other model');
  await request(app).put('/api/v1/admin/neorouter/roles').set(bearer(admin.token)).send({ roles: ['bogus'] }).expect(400);
});

test('a router that cannot be reached is shown as such, and disconnecting removes the key', async () => {
  online = false;
  const state = await request(app).get('/api/v1/admin/neorouter').set(bearer(admin.token)).expect(200);
  online = true;
  assert.equal(state.body.connected, true);
  assert.equal(state.body.reachable, false);
  assert.match(state.body.unreachableReason, /Could not reach NeoRouter/);

  await request(app).delete('/api/v1/admin/neorouter').set(bearer(admin.token)).expect(200);
  assert.equal(getDatabase().prepare("SELECT COUNT(*) n FROM app_settings WHERE key LIKE 'neorouter.%'").get().n, 0);
  const settings = await request(app).get('/api/v1/admin/provider-settings').set(bearer(admin.token)).expect(200);
  assert.notEqual(settings.body.settings.llm.provider, 'neorouter');
  await request(app).put('/api/v1/admin/neorouter/roles').set(bearer(admin.token)).send({ roles: ['llm'] }).expect(400);
});
