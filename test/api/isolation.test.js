'use strict';

const test = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-isolation-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('cross-user ID probing returns 404 without leaking content', async () => {
  const first = await request(app).post('/api/v1/auth/register').send({ username: 'isolation-a', password: 'a long and unique password' });
  const second = await request(app).post('/api/v1/auth/register').send({ username: 'isolation-b', password: 'another unique password' });
  const device = await request(app).post('/api/v1/devices').set('Authorization', `Bearer ${first.body.session.token}`).send({ clientUuid: 'isolation-device-a', name: 'A', platform: 'test', kind: 'desktop' });
  await request(app).get(`/api/v1/devices/${device.body.id}`).set('Authorization', `Bearer ${second.body.session.token}`).expect(404);
});
