'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-admin-backup-'));

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

let adminToken;
test('the first account is the admin', async () => {
  const registration = await request(app).post('/api/v1/auth/register')
    .send({ username: 'server-admin', password: 'a long admin password' }).expect(201);
  assert.equal(registration.body.user.role, 'admin');
  adminToken = registration.body.session.token;
});

test('the backup endpoints are admin-only', async () => {
  await request(app).get('/api/v1/admin/backups').expect(401);
  await request(app).post('/api/v1/admin/backups/run').expect(401);
  // A normal account token must not reach the admin API either.
  const user = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ordinary-user', password: 'a long and unique password' }).expect(201);
  const refused = await request(app).get('/api/v1/admin/backups')
    .set('Authorization', `Bearer ${user.body.session.token}`).expect(403);
  assert.equal(refused.body.error.code, 'ADMIN_REQUIRED');
});

test('status reports the schedule before anything has run', async () => {
  const response = await request(app).get('/api/v1/admin/backups')
    .set('Authorization', `Bearer ${adminToken}`).expect(200);
  assert.equal(response.body.status.destination, 'local');
  assert.equal(response.body.status.enabled, true);
  // Three artifacts kept by default; this file deliberately does not set
  // NEORECALL_BACKUP_RETAIN, so it is the shipped default being asserted.
  assert.equal(response.body.status.retain, 3);
  assert.equal(response.body.status.due, true, 'an installation that has never backed up is due');
  assert.equal(response.body.status.lastSuccessAt, null);
  assert.deepEqual(response.body.history, []);
});

test('running a backup from the Admin page stores an artifact and is audited', async () => {
  const run = await request(app).post('/api/v1/admin/backups/run')
    .set('Authorization', `Bearer ${adminToken}`).expect(200);
  assert.match(run.body.key, /^neorecall-\d{8}T\d{6}Z-[0-9a-f]{6}\.nrbak$/);
  assert.ok(run.body.bytes > 0);

  const after = await request(app).get('/api/v1/admin/backups')
    .set('Authorization', `Bearer ${adminToken}`).expect(200);
  assert.equal(after.body.status.due, false);
  assert.ok(after.body.status.lastSuccessAt);
  assert.equal(after.body.status.artifactCount, 1);
  assert.equal(after.body.history[0].state, 'succeeded');
  assert.equal(after.body.history[0].trigger_kind, 'manual');

  const audited = getDatabase().prepare("SELECT * FROM audit_log WHERE action='backup_run'").get();
  assert.ok(audited, 'a manual backup leaves an audit entry');
  assert.equal(audited.resource_id, run.body.key);
});
