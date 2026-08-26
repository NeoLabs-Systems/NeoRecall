'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-admin-backup-'));
process.env.ADMIN_USERNAME = 'dashboard-admin';
process.env.ADMIN_PASSWORD = 'a long admin password';

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const adminAuth = require('../../server/services/auth/admin_auth_service');
const app = createApp();
test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
  delete process.env.ADMIN_USERNAME;
  delete process.env.ADMIN_PASSWORD;
});

let adminToken;
test('bootstrap an admin session', async () => {
  await adminAuth.bootstrap();
  const login = await request(app).post('/admin/api/v1/login')
    .send({ username: 'dashboard-admin', password: 'a long admin password' }).expect(200);
  adminToken = login.body.session?.token || login.body.token;
  assert.ok(adminToken, 'the admin login returns a token');
});

test('the backup endpoints are admin-only', async () => {
  await request(app).get('/admin/api/v1/backups').expect(401);
  await request(app).post('/admin/api/v1/backups/run').expect(401);
  // A normal account token must not reach the admin dashboard API either.
  const user = await request(app).post('/api/v1/auth/register')
    .send({ username: 'ordinary-user', password: 'a long and unique password' }).expect(201);
  await request(app).get('/admin/api/v1/backups')
    .set('Authorization', `Bearer ${user.body.session.token}`).expect(401);
});

test('status reports the schedule before anything has run', async () => {
  const response = await request(app).get('/admin/api/v1/backups')
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

test('running a backup from the dashboard stores an artifact and is audited', async () => {
  const run = await request(app).post('/admin/api/v1/backups/run')
    .set('Authorization', `Bearer ${adminToken}`).expect(200);
  assert.match(run.body.key, /^neorecall-\d{8}T\d{6}Z-[0-9a-f]{6}\.nrbak$/);
  assert.ok(run.body.bytes > 0);

  const after = await request(app).get('/admin/api/v1/backups')
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
