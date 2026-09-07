'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-retrieval-'));
const embeddings = require('../../server/embeddings/embedding_service');
// Stored text sits on one axis and every query on another, so the archive holds
// nothing a query is close to — the case the similarity floor exists for.
embeddings.embed = async (_text, prefix = 'passage') => {
  const vector = new Float32Array(384);
  vector[prefix === 'query' ? 1 : 0] = 1;
  return vector;
};
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase, isVectorReady } = require('../../server/db/database');
const searchIndex = require('../../server/embeddings/search_index_service');
const searchService = require('../../server/services/search/search_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

async function account(username) {
  const created = await request(app).post('/api/v1/auth/register').send({ username, password: 'a long and unique password' }).expect(201);
  return { id: created.body.user.id, token: created.body.session.token };
}

function insert(userId, { kind = 'segment', sourceId, body, occurredAt, importance = 0 }) {
  return Number(getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,?,?,NULL,?,?,?,?)`).run(userId, kind, sourceId, body, occurredAt, importance, `hash-${userId}-${kind}-${sourceId}`).lastInsertRowid);
}

test('a distant neighbour is counted, not retrieved', { skip: !isVectorReady() && 'vector extension unavailable' }, async () => {
  const user = await account('retrieval-floor');
  const id = insert(user.id, { sourceId: '1', body: 'Wir haben über den Dachdecker gesprochen.', occurredAt: '2026-07-13T10:00:00.000Z' });
  await searchIndex.embedDocuments([id]);

  const found = await searchService.search(user.id, 'nothing in this archive resembles this');
  assert.equal(found.results.length, 0);
  assert.equal(found.weakCount, 1);

  const response = await request(app).get('/api/v1/search?q=nothing%20like%20it').set('Authorization', `Bearer ${user.token}`).expect(200);
  assert.deepEqual(response.body.results, []);
  assert.equal(response.body.weakCount, 1);
});

test('a time window bounds retrieval and answers for the period itself', async () => {
  const user = await account('retrieval-window');
  insert(user.id, { kind: 'memory', sourceId: 'm1', body: 'Angebot für das Dach besprochen.', occurredAt: '2026-07-13T09:00:00.000Z', importance: 6 });
  insert(user.id, { kind: 'memory', sourceId: 'm2', body: 'Einkauf und ein langer Spaziergang.', occurredAt: '2026-07-13T16:00:00.000Z', importance: 3 });
  insert(user.id, { kind: 'memory', sourceId: 'm3', body: 'Angebot für das Dach besprochen.', occurredAt: '2026-07-11T09:00:00.000Z', importance: 6 });

  const day = { from: '2026-07-13T00:00:00.000Z', to: '2026-07-14T00:00:00.000Z' };
  const inside = await searchService.search(user.id, 'Angebot', day);
  assert.deepEqual(inside.results.map((result) => result.source_id), ['m1']);

  // The words carry nothing to match on; the window is the whole question.
  const period = await searchService.search(user.id, 'was war heute', { ...day, wholeWindow: true });
  assert.deepEqual(period.results.map((result) => result.source_id).sort(), ['m1', 'm2']);
});

test('a memory outranks a passing segment that shares its words', async () => {
  const user = await account('retrieval-kinds');
  insert(user.id, { kind: 'segment', sourceId: 's1', body: 'Anna! Anna, warte kurz.', occurredAt: '2026-07-13T12:00:00.000Z' });
  insert(user.id, { kind: 'memory', sourceId: 'm1', body: 'Anna bekommt die korrigierte Rechnung vor Freitag.', occurredAt: '2026-07-13T11:00:00.000Z', importance: 7 });

  const found = await searchService.search(user.id, 'Anna Rechnung');
  assert.equal(found.results[0].kind, 'memory');
});
