'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-cloud-api-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const loginFlow = require('../../server/services/cloud/nextcloud_login_flow');
const accounts = require('../../server/services/cloud/cloud_account_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

async function register(username) {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username, password: 'a long and unique password' }).expect(201);
  return { Authorization: `Bearer ${registered.body.session.token}`, userId: registered.body.user.id };
}

test('cloud status starts disconnected', async () => {
  const auth = await register('cloud-status');
  const response = await request(app).get('/api/v1/cloud').set(auth).expect(200);
  assert.equal(response.body.cloud.connected, false);
  assert.equal(response.body.cloud.status, 'disconnected');
});

test('link-local Nextcloud URLs are rejected', async () => {
  const auth = await register('cloud-ssrf');
  const started = await request(app).post('/api/v1/cloud/nextcloud/login').set(auth)
    .send({ instanceUrl: 'https://169.254.169.254' }).expect(400);
  assert.equal(started.body.error.code, 'INVALID_CLOUD_URL');
});

test('connected account patches, queues a backup, and disconnects without echoing secrets', async () => {
  const auth = await register('cloud-connect');
  const fetchImpl = async (url, opts) => {
    if (String(url).includes('/login/v2') && !String(url).includes('poll')) {
      return {
        status: 200,
        json: async () => ({
          login: 'https://cloud.example.test/index.php/login/v2/flow/abc',
          poll: { token: 'tok', endpoint: 'https://cloud.example.test/index.php/login/v2/poll' },
        }),
      };
    }
    return {
      status: 200,
      json: async () => ({ loginName: 'ada', appPassword: 'app-secret' }),
    };
  };
  await loginFlow.start(auth.userId, 'https://cloud.example.test', { fetchImpl });
  const result = await loginFlow.poll(auth.userId, { fetchImpl });
  accounts.upsertConnected(auth.userId, result);

  const connected = await request(app).get('/api/v1/cloud').set(auth).expect(200);
  assert.equal(connected.body.cloud.connected, true);
  assert.equal(connected.body.cloud.username, 'ada');
  assert.ok(!JSON.stringify(connected.body).includes('app-secret'));

  const patched = await request(app).patch('/api/v1/cloud').set(auth)
    .send({ audioEnabled: true, dataBackupEnabled: true }).expect(200);
  assert.equal(patched.body.cloud.audioEnabled, true);
  assert.equal(patched.body.cloud.dataBackupEnabled, true);

  await request(app).post('/api/v1/cloud/backup').set(auth).expect(200);
  await request(app).delete('/api/v1/cloud').set(auth).expect(204);
  const after = await request(app).get('/api/v1/cloud').set(auth).expect(200);
  assert.equal(after.body.cloud.connected, false);
});
