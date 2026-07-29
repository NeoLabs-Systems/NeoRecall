'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
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

test('one account can declare concurrent devices while another account stays isolated', async () => {
  const owner = await request(app).post('/api/v1/auth/register').send({
    username: 'multi-device-owner',
    password: 'a third long unique password',
  }).expect(201);
  const outsider = await request(app).post('/api/v1/auth/register').send({
    username: 'multi-device-outsider',
    password: 'a fourth long unique password',
  }).expect(201);
  const ownerAuth = { Authorization: `Bearer ${owner.body.session.token}` };
  const outsiderAuth = { Authorization: `Bearer ${outsider.body.session.token}` };

  const declarations = await Promise.all([
    request(app).post('/api/v1/devices').set(ownerAuth).send({
      clientUuid: crypto.randomUUID(),
      name: 'Desktop A',
      platform: 'macos',
      kind: 'desktop',
    }).expect(201),
    request(app).post('/api/v1/devices').set(ownerAuth).send({
      clientUuid: crypto.randomUUID(),
      name: 'Browser B',
      platform: 'web',
      kind: 'browser',
    }).expect(201),
  ]);
  assert.notEqual(declarations[0].body.id, declarations[1].body.id);

  const ownerDevices = await request(app).get('/api/v1/devices').set(ownerAuth).expect(200);
  const outsiderDevices = await request(app).get('/api/v1/devices').set(outsiderAuth).expect(200);
  assert.equal(ownerDevices.body.devices.length, 2);
  assert.equal(outsiderDevices.body.devices.length, 0);
});
