'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-diagnostics-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const diagnostics = require('../../server/services/diagnostics/diagnostic_service');
const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('diagnostic export is session-only, redacted, and account-isolated', async () => {
  const first = await request(app).post('/api/v1/auth/register').send({
    username: 'diagnostic-owner',
    password: 'a long and unique password',
  }).expect(201);
  const second = await request(app).post('/api/v1/auth/register').send({
    username: 'diagnostic-outsider',
    password: 'another long unique password',
  }).expect(201);
  const firstUserId = first.body.user.id;
  const secondUserId = second.body.user.id;
  const firstToken = first.body.session.token;

  diagnostics.recordRequest({
    userId: firstUserId,
    requestId: 'first-request',
    method: 'GET',
    path: '/api/v1/devices/3f45a980-1cf8-4f42-9c15-55b2c2036413?token=private',
    statusCode: 503,
    durationMs: 17,
    errorCode: 'DEVICE_OFFLINE',
  });
  diagnostics.recordRequest({
    userId: secondUserId,
    requestId: 'second-request',
    method: 'GET',
    path: '/api/v1/private-outsider-marker',
    statusCode: 418,
    durationMs: 9,
    errorCode: 'OUTSIDER_ONLY',
  });

  const exported = await request(app)
    .get('/api/v1/diagnostics/export')
    .set('Authorization', `Bearer ${firstToken}`)
    .expect(200);

  const serialized = JSON.stringify(exported.body);
  assert.match(serialized, /DEVICE_OFFLINE/);
  assert.match(serialized, /\/api\/v1\/devices\/:id/);
  assert.doesNotMatch(serialized, /private-outsider-marker|OUTSIDER_ONLY|private/);
  assert.doesNotMatch(serialized, new RegExp(firstToken.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));

  const apiKey = await request(app)
    .post('/api/v1/api-keys')
    .set('Authorization', `Bearer ${firstToken}`)
    .send({ name: 'diagnostics-test', scopes: ['devices:read'] })
    .expect(201);
  await request(app)
    .get('/api/v1/diagnostics/export')
    .set('Authorization', `Bearer ${apiKey.body.token}`)
    .expect(403);
});
