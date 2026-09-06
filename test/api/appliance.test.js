'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-appliance-'));
const { createApp } = require('../../server/app');
const { closeDatabase, getDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

async function registerUser(username) {
  const res = await request(app).post('/api/v1/auth/register').send({ username, password: 'a long and unique password' }).expect(201);
  return { Authorization: `Bearer ${res.body.session.token}` };
}

test('a device can register with kind "appliance" and the migration preserves foreign keys', async () => {
  const auth = await registerUser('appliance-owner');
  const res = await request(app).post('/api/v1/devices').set(auth).send({
    clientUuid: crypto.randomUUID(), name: 'NeoRecall Desk', platform: 'raspberrypi-zero2w', kind: 'appliance',
  }).expect(201);
  assert.equal(res.body.kind, 'appliance');

  const listed = await request(app).get('/api/v1/devices').set(auth).expect(200);
  assert.ok(listed.body.devices.some((d) => d.id === res.body.id && d.kind === 'appliance'));

  // The device-kind rebuild (022_device_kind_appliance.js) must not have broken
  // referential integrity with tables that reference devices(id).
  const violations = getDatabase().pragma('foreign_key_check');
  assert.deepEqual(violations, []);
});

test('an invalid device kind is still rejected', async () => {
  const auth = await registerUser('appliance-invalid-kind');
  await request(app).post('/api/v1/devices').set(auth).send({
    clientUuid: crypto.randomUUID(), name: 'Bogus', platform: 'test', kind: 'toaster',
  }).expect(400);
});

test('DELETE /api-keys/self revokes the calling API key', async () => {
  const auth = await registerUser('self-revoke-owner');
  const created = await request(app).post('/api/v1/api-keys').set(auth).send({
    name: 'Desk key', scopes: ['ingest:write', 'devices:write', 'devices:read'],
  }).expect(201);
  const keyAuth = { Authorization: `Bearer ${created.body.token}` };

  // The key works before revocation.
  await request(app).get('/api/v1/devices').set(keyAuth).expect(200);

  await request(app).delete('/api/v1/api-keys/self').set(keyAuth).expect(204);

  // The now-revoked key can no longer authenticate at all.
  await request(app).get('/api/v1/devices').set(keyAuth).expect(401);
});

test('DELETE /api-keys/self is rejected for an interactive session (no key to revoke)', async () => {
  const auth = await registerUser('self-revoke-session-only');
  await request(app).delete('/api/v1/api-keys/self').set(auth).expect(400);
});

test('DELETE /api-keys/self is not shadowed by DELETE /api-keys/:id', async () => {
  const auth = await registerUser('self-revoke-not-shadowed');
  const created = await request(app).post('/api/v1/api-keys').set(auth).send({
    name: 'Named key', scopes: ['ingest:write'],
  }).expect(201);
  // A session calling DELETE /api-keys/self must hit the dedicated route (400 NOT_AN_API_KEY),
  // not fall through to /:id and 404 on a literal id of "self".
  const res = await request(app).delete('/api/v1/api-keys/self').set(auth).expect(400);
  assert.equal(res.body.error.code, 'NOT_AN_API_KEY');

  // Meanwhile the real key can still be revoked by id via the session.
  await request(app).delete(`/api/v1/api-keys/${created.body.id}`).set(auth).expect(204);
});

test('an API key cannot revoke another user’s API key by id', async () => {
  const ownerAuth = await registerUser('self-revoke-cross-user-owner');
  const outsiderAuth = await registerUser('self-revoke-cross-user-outsider');
  const created = await request(app).post('/api/v1/api-keys').set(ownerAuth).send({
    name: 'Owner key', scopes: ['ingest:write'],
  }).expect(201);
  await request(app).delete(`/api/v1/api-keys/${created.body.id}`).set(outsiderAuth).expect(404);
});

test('DELETE /api-keys/self on an already-revoked key returns 404', async () => {
  const auth = await registerUser('self-revoke-twice');
  const created = await request(app).post('/api/v1/api-keys').set(auth).send({
    name: 'Once key', scopes: ['ingest:write'],
  }).expect(201);
  const keyAuth = { Authorization: `Bearer ${created.body.token}` };
  await request(app).delete('/api/v1/api-keys/self').set(keyAuth).expect(204);
  // The key is now revoked and can no longer authenticate to call /self again.
  await request(app).delete('/api/v1/api-keys/self').set(keyAuth).expect(401);
});

test('the device list says whether an appliance is recording right now', async () => {
  const auth = await registerUser('appliance-recording-state');
  const device = await request(app).post('/api/v1/devices').set(auth).send({
    clientUuid: crypto.randomUUID(), name: 'NeoRecall Desk', platform: 'raspberrypi', kind: 'appliance',
  }).expect(201);

  const idle = await request(app).get('/api/v1/devices').set(auth).expect(200);
  const before = idle.body.devices.find((d) => d.id === device.body.id);
  assert.equal(before.active_session_id, null);
  assert.equal(before.active_session_started_at, null);

  const startedAt = new Date().toISOString();
  const session = await request(app).post('/api/v1/ingest/sessions').set(auth).send({
    deviceId: device.body.id, clientUuid: crypto.randomUUID(), startedAt, timezone: 'Europe/Berlin',
    consentAttestedAt: startedAt,
    sources: [{ clientUuid: crypto.randomUUID(), kind: 'combined', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }],
  }).expect(201);

  // A screenless device cannot report this itself once the phone is out of
  // Bluetooth range, so the list has to carry it.
  const recording = await request(app).get('/api/v1/devices').set(auth).expect(200);
  const during = recording.body.devices.find((d) => d.id === device.body.id);
  assert.equal(during.active_session_id, session.body.session.id);
  assert.ok(during.active_session_started_at);

  await request(app).patch(`/api/v1/ingest/sessions/${session.body.session.id}`).set(auth).send({
    endedAt: new Date().toISOString(), status: 'ended',
  }).expect(200);

  const stopped = await request(app).get('/api/v1/devices').set(auth).expect(200);
  assert.equal(stopped.body.devices.find((d) => d.id === device.body.id).active_session_id, null);
});
