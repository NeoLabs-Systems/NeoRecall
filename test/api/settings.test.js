'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-settings-'));
process.env.NEORECALL_MIN_CONSOLIDATION_INTERVAL_MS = '3600000';
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('user settings validate timezones and preserve the environment interval floor', async () => {
  const registered = await request(app).post('/api/v1/auth/register').send({ username: 'settings-user', password: 'a long and unique password' }).expect(201);
  const auth = { Authorization: `Bearer ${registered.body.session.token}` };
  const updated = await request(app).put('/api/v1/settings').set(auth).send({ consolidationIntervalMs: 1000, timezone: 'Europe/Berlin', chunkTargetMs: 30000, chunkOverlapMs: 2000 }).expect(200);
  assert.equal(updated.body.settings.consolidationIntervalMs, 1000);
  assert.equal(updated.body.settings.effectiveConsolidationIntervalMs, 3600000);
  await request(app).put('/api/v1/settings').set(auth).send({ timezone: 'Not/A_Timezone' }).expect(400);
});
