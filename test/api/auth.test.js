'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-auth-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('first registered user is an application admin and opaque tokens authenticate', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'first-user', email: 'first@example.com', password: 'a long and unique password' }).expect(201);
  assert.equal(registration.body.user.role, 'admin');
  assert.match(registration.body.session.token, /^nrs_/);
  const me = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${registration.body.session.token}`).expect(200);
  assert.equal(me.body.user.username, 'first-user');
  const key = await request(app).post('/api/v1/api-keys').set('Authorization', `Bearer ${registration.body.session.token}`)
    .send({ name: 'read-only test', scopes: ['search:read'] }).expect(201);
  await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${key.body.token}`).expect(200);
  await request(app).post('/api/v1/api-keys').set('Authorization', `Bearer ${key.body.token}`)
    .send({ name: 'escalated key', scopes: ['*'] }).expect(403);
  await request(app).put('/api/v1/settings').set('Authorization', `Bearer ${key.body.token}`)
    .send({ timezone: 'UTC' }).expect(403);
  await request(app).post('/api/v1/search/ask').set('Authorization', `Bearer ${key.body.token}`)
    .send({ question: 'What happened?' }).expect(403);
  await request(app).post('/api/v1/auth/logout').set('Authorization', `Bearer ${registration.body.session.token}`).expect(204);
  await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${registration.body.session.token}`).expect(401);
});
