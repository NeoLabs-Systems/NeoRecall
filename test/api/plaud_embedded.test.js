'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-plaud-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('meta advertises Plaud Embedded only when partner credentials are set', async () => {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username: 'plaud-meta', password: 'a long and unique password' }).expect(201);
  const auth = { Authorization: `Bearer ${registered.body.session.token}` };
  const meta = await request(app).get('/api/v1/meta').set(auth).expect(200);
  assert.equal(meta.body.capabilities.plaudEmbedded, false);
});

test('the Plaud session endpoint is absent when the server has no partner app', async () => {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username: 'plaud-session', password: 'a long and unique password' }).expect(201);
  await request(app).post('/api/v1/devices/plaud/session')
    .set({ Authorization: `Bearer ${registered.body.session.token}` })
    .expect(404);
});

test('retired Plaud cloud sources are not offered', async () => {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username: 'plaud-types', password: 'a long and unique password' }).expect(201);
  const types = await request(app).get('/api/v1/sources/types')
    .set({ Authorization: `Bearer ${registered.body.session.token}` }).expect(200);
  assert.ok(!types.body.types.includes('plaud'));
});
