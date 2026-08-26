'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

const ORIGIN = 'http://localhost:4500';

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-webauthn-'));
process.env.NEORECALL_ALLOWED_ORIGINS = ORIGIN;
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const { createVirtualAuthenticator } = require('../fixtures/virtual_authenticator');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

async function registerUser(username) {
  const registered = await request(app).post('/api/v1/auth/register')
    .send({ username, password: 'a long and unique password' }).expect(201);
  return { id: registered.body.user.id, headers: { Authorization: `Bearer ${registered.body.session.token}` } };
}

async function addSecurityKey(user, authenticator, label) {
  const options = await request(app).post('/api/v1/settings/security-keys/options')
    .set(user.headers).set('Origin', ORIGIN).expect(200);
  const attestation = authenticator.register({ options: options.body.options, origin: ORIGIN });
  return request(app).post('/api/v1/settings/security-keys')
    .set(user.headers).set('Origin', ORIGIN)
    .send({ challengeId: options.body.challengeId, response: attestation, label });
}

async function signIn(authenticator, { account, userHandle, twoFactorCode } = {}) {
  const options = await request(app).post('/api/v1/auth/webauthn/options')
    .set('Origin', ORIGIN).send(account ? { account } : {}).expect(200);
  const assertion = authenticator.authenticate({ options: options.body.options, origin: ORIGIN, userHandle });
  return request(app).post('/api/v1/auth/webauthn/verify').set('Origin', ORIGIN)
    .send({ challengeId: options.body.challengeId, response: assertion, twoFactorCode });
}

test('sign-in refuses immediately when nothing is registered', async () => {
  // Runs before any key exists so the browser is never sent to a key prompt
  // that cannot be satisfied.
  const empty = await request(app).post('/api/v1/auth/webauthn/options')
    .set('Origin', ORIGIN).send({}).expect(409);
  assert.equal(empty.body.error.code, 'NO_CREDENTIALS_REGISTERED');

  const user = await registerUser('first-key-owner');
  await addSecurityKey(user, createVirtualAuthenticator(), 'First key');
  await request(app).post('/api/v1/auth/webauthn/options')
    .set('Origin', ORIGIN).send({}).expect(200);
});

test('a registered security key signs in without a password and can be managed', async () => {
  const user = await registerUser('key-owner');
  const authenticator = createVirtualAuthenticator();

  const added = await addSecurityKey(user, authenticator, 'YubiKey 5');
  assert.equal(added.statusCode, 200);
  assert.equal(added.body.credentials.length, 1);
  assert.equal(added.body.credentials[0].label, 'YubiKey 5');

  const login = await signIn(authenticator, { userHandle: user.id });
  assert.equal(login.statusCode, 200);
  assert.equal(login.body.user.username, 'key-owner');
  assert.match(login.body.session.token, /^nrs_/);
  await request(app).get('/api/v1/auth/me')
    .set('Authorization', `Bearer ${login.body.session.token}`).expect(200);

  const keyId = added.body.credentials[0].id;
  const renamed = await request(app).put(`/api/v1/settings/security-keys/${keyId}`)
    .set(user.headers).send({ label: 'Backup key' }).expect(200);
  assert.equal(renamed.body.credentials[0].label, 'Backup key');
  assert.ok(renamed.body.credentials[0].lastUsedAt);

  const removed = await request(app).delete(`/api/v1/settings/security-keys/${keyId}`)
    .set(user.headers).expect(200);
  assert.equal(removed.body.credentials.length, 0);
  assert.equal((await signIn(authenticator, { userHandle: user.id })).statusCode, 401);
});

test('a user-verifying key replaces the two-factor code while a presence-only key does not', async () => {
  const verifying = await registerUser('uv-user');
  const verifyingKey = createVirtualAuthenticator({ userVerified: true });
  await addSecurityKey(verifying, verifyingKey, 'Verified key');

  const presence = await registerUser('presence-user');
  const presenceKey = createVirtualAuthenticator({ userVerified: false });
  await addSecurityKey(presence, presenceKey, 'Presence key');

  for (const user of [verifying, presence]) {
    const setup = await request(app).post('/api/v1/settings/2fa/setup').set(user.headers).expect(200);
    const { authenticator: totp } = require('otplib');
    await request(app).post('/api/v1/settings/2fa/enable').set(user.headers)
      .send({ code: totp.generate(setup.body.secret) }).expect(200);
  }

  assert.equal((await signIn(verifyingKey, { userHandle: verifying.id })).statusCode, 200);

  const blocked = await signIn(presenceKey, { userHandle: presence.id });
  assert.equal(blocked.statusCode, 401);
  assert.equal(blocked.body.error.code, 'TWO_FACTOR_REQUIRED');
});

test('challenges are single use and unknown keys are rejected', async () => {
  const user = await registerUser('replay-user');
  const authenticator = createVirtualAuthenticator();
  await addSecurityKey(user, authenticator, 'Main key');

  const options = await request(app).post('/api/v1/auth/webauthn/options')
    .set('Origin', ORIGIN).send({}).expect(200);
  const assertion = authenticator.authenticate({ options: options.body.options, origin: ORIGIN });
  await request(app).post('/api/v1/auth/webauthn/verify').set('Origin', ORIGIN)
    .send({ challengeId: options.body.challengeId, response: assertion }).expect(200);
  const replayed = await request(app).post('/api/v1/auth/webauthn/verify').set('Origin', ORIGIN)
    .send({ challengeId: options.body.challengeId, response: assertion });
  assert.equal(replayed.statusCode, 400);
  assert.equal(replayed.body.error.code, 'CHALLENGE_EXPIRED');

  assert.equal((await signIn(createVirtualAuthenticator())).statusCode, 401);
  await request(app).post('/api/v1/auth/webauthn/options')
    .set('Origin', 'http://evil.example').send({}).expect(403);
});

test('a scoped API key cannot register or remove a security key', async () => {
  const user = await registerUser('api-key-user');
  const key = await request(app).post('/api/v1/api-keys').set(user.headers)
    .send({ name: 'settings key', scopes: ['settings:write'] }).expect(201);
  const keyHeaders = { Authorization: `Bearer ${key.body.token}` };
  await request(app).post('/api/v1/settings/security-keys/options')
    .set(keyHeaders).set('Origin', ORIGIN).expect(403);
  await request(app).delete('/api/v1/settings/security-keys/whatever')
    .set(keyHeaders).expect(403);
});
