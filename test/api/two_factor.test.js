'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-2fa-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const { generateTotp } = require('../../server/utils/totp');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const password = 'a long and unique password';

async function registerUser(username) {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username, password }).expect(201);
  return {
    username,
    headers: { Authorization: `Bearer ${registered.body.session.token}` },
  };
}

test('enabling authenticator 2FA returns a manual key and accepts the current code', async () => {
  const user = await registerUser('totp-user');
  const setup = await request(app).post('/api/v1/settings/2fa/setup').set(user.headers).expect(200);
  assert.equal(typeof setup.body.secret, 'string');
  assert.equal(setup.body.manualKey, setup.body.secret);
  assert.match(setup.body.otpauthUri, new RegExp(`secret=${setup.body.secret}`));
  assert.match(setup.body.qrDataUrl, /^data:image\/png;base64,/);

  await request(app).post('/api/v1/settings/2fa/enable').set(user.headers)
    .send({ code: '000000' }).expect(400);

  const enabled = await request(app).post('/api/v1/settings/2fa/enable').set(user.headers)
    .send({ code: generateTotp(setup.body.secret) }).expect(200);
  assert.equal(enabled.body.recoveryCodes.length, 10);

  const status = await request(app).get('/api/v1/settings/2fa').set(user.headers).expect(200);
  assert.equal(status.body.enabled, true);

  await request(app).post('/api/v1/auth/login')
    .send({ account: user.username, password }).expect(401);
  await request(app).post('/api/v1/auth/login')
    .send({ account: user.username, password, twoFactorCode: generateTotp(setup.body.secret) })
    .expect(200);
});

test('a code from the previous 30-second step still enables 2FA', async () => {
  const user = await registerUser('totp-window-user');
  const setup = await request(app).post('/api/v1/settings/2fa/setup').set(user.headers).expect(200);
  const previous = generateTotp(setup.body.secret, Date.now() - 30_000);
  await request(app).post('/api/v1/settings/2fa/enable').set(user.headers)
    .send({ code: previous }).expect(200);
});
