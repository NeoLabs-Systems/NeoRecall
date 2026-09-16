'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-oauth-2fa-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const { generateTotp } = require('../../server/utils/totp');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const password = 'a long and unique password';

test('OAuth 2FA challenge does not put the password in the page', async () => {
  const registered = await request(app).post('/api/v1/auth/register').send({
    username: 'oauth-2fa', email: 'oauth2fa@example.test', password,
  }).expect(201);
  const headers = { Authorization: `Bearer ${registered.body.session.token}` };
  const setup = await request(app).post('/api/v1/settings/2fa/setup').set(headers).expect(200);
  await request(app).post('/api/v1/settings/2fa/enable').set(headers)
    .send({ code: generateTotp(setup.body.secret) }).expect(200);

  const callback = 'https://agent.example.test/api/integrations/oauth/callback';
  const bootstrap = await request(app).post('/api/oauth/companion/neoagent/bootstrap')
    .send({ redirectUri: callback, appName: 'NeoAgent' }).expect(200);
  const verifier = 'oauth-2fa-pkce-verifier-long-enough-for-s256';
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  const continuePath = `/oauth/authorize?${new URLSearchParams({
    response_type: 'code', client_id: bootstrap.body.clientId, redirect_uri: callback,
    state: '0123456789abcdef0123456789abcdef0123456789abcdef',
    scope: bootstrap.body.scopes.join(' '), code_challenge: challenge, code_challenge_method: 'S256',
  })}`;

  const challengePage = await request(app).post('/oauth/sign-in').type('form').send({
    account: 'oauth-2fa', password, continue: continuePath,
  }).expect(200);
  assert.match(challengePage.text, /Two-factor authentication/);
  assert.doesNotMatch(challengePage.text, new RegExp(`value="${password}"`));
  assert.doesNotMatch(challengePage.text, /name="password"/);
  const pending = challengePage.headers['set-cookie'].find((cookie) => cookie.startsWith('neorecall_oauth_2fa='));
  assert.ok(pending);

  const signedIn = await request(app).post('/oauth/sign-in').type('form')
    .set('Cookie', pending.split(';')[0])
    .send({
      account: 'oauth-2fa',
      two_factor_code: generateTotp(setup.body.secret),
      continue: continuePath,
    }).expect(302);
  assert.equal(signedIn.headers.location, continuePath);
});
