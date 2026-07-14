'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-search-'));
const embeddings = require('../../server/embeddings/embedding_service');
embeddings.embed = async () => { const vector = new Float32Array(384); vector[0] = 1; return vector; };
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase, isVectorReady } = require('../../server/db/database');
const searchIndex = require('../../server/embeddings/search_index_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('keyword branch finds Unicode evidence and remains user-isolated', async () => {
  const first = await request(app).post('/api/v1/auth/register').send({ username: 'search-first', password: 'a long and unique password' }).expect(201);
  const second = await request(app).post('/api/v1/auth/register').send({ username: 'search-second', password: 'a long and unique password' }).expect(201);
  const inserted = getDatabase().prepare(`INSERT INTO search_documents (user_id,kind,source_id,title,body,occurred_at,importance,text_hash)
    VALUES (?,'segment','1',NULL,?,'2026-07-13T10:00:00.000Z',0,?)`).run(first.body.user.id, 'Die Projektplanung für Berlin ist abgeschlossen.', 'hash-one');
  const own = await request(app).get('/api/v1/search?q=Projektplanung').set('Authorization', `Bearer ${first.body.session.token}`).expect(200);
  assert.equal(own.body.results.length, 1);
  assert.equal(own.body.results[0].body, 'Die Projektplanung für Berlin ist abgeschlossen.');
  const isolated = await request(app).get('/api/v1/search?q=Projektplanung').set('Authorization', `Bearer ${second.body.session.token}`).expect(200);
  assert.equal(isolated.body.results.length, 0);

  if (isVectorReady()) {
    await searchIndex.embedDocuments([Number(inserted.lastInsertRowid)]);
    const semantic = await request(app).get('/api/v1/search?q=unrelated-semantic-query').set('Authorization', `Bearer ${first.body.session.token}`).expect(200);
    assert.equal(semantic.body.results[0].body, 'Die Projektplanung für Berlin ist abgeschlossen.');
    searchIndex.removeBySources(getDatabase(), first.body.user.id, [{ kind: 'segment', sourceId: 1 }]);
    const removed = await request(app).get('/api/v1/search?q=unrelated-semantic-query').set('Authorization', `Bearer ${first.body.session.token}`).expect(200);
    assert.equal(removed.body.results.length, 0);
  }
});
