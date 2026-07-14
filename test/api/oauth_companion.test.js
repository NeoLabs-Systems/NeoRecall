'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-oauth-'));
const { createApp } = require('../../server/app');
const { closeDatabase, getDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('NeoAgent companion uses consent, PKCE, read-only scopes, and rotating refresh tokens', async () => {
  const password = 'a long and unique password';
  await request(app).post('/api/v1/auth/register').send({
    username: 'recall-owner', email: 'recall@example.test', password,
  }).expect(201);

  const callback = 'https://agent.example.test/api/integrations/oauth/callback';
  const bootstrap = await request(app).post('/api/oauth/companion/neoagent/bootstrap')
    .send({ redirectUri: callback, appName: 'NeoAgent' }).expect(200);
  assert.match(bootstrap.body.clientId, /^nrc_/);
  assert.deepEqual(bootstrap.body.scopes, ['search:read', 'memories:read', 'recordings:read']);

  await request(app).post('/api/oauth/companion/neoagent/bootstrap')
    .send({ redirectUri: 'https://attacker.example.test/callback', appName: 'NeoAgent' }).expect(400);
  await request(app).post('/api/oauth/companion/neoagent/bootstrap')
    .send({ redirectUri: 'http://agent.example.test/api/integrations/oauth/callback', appName: 'NeoAgent' }).expect(400);

  const verifier = 'neoagent-pkce-verifier-long-enough-for-a-secure-test';
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  const authorization = {
    response_type: 'code', client_id: bootstrap.body.clientId, redirect_uri: callback,
    state: '0123456789abcdef0123456789abcdef0123456789abcdef',
    scope: bootstrap.body.scopes.join(' '), code_challenge: challenge, code_challenge_method: 'S256',
  };
  const continuePath = `/oauth/authorize?${new URLSearchParams(authorization)}`;
  const signIn = await request(app).post('/oauth/sign-in').type('form').send({
    account: 'recall-owner', password, continue: continuePath,
  }).expect(302);
  assert.equal(signIn.headers.location, continuePath);
  const cookie = signIn.headers['set-cookie'][0].split(';')[0];
  assert.match(signIn.headers['set-cookie'][0], /HttpOnly/);
  assert.match(signIn.headers['set-cookie'][0], /SameSite=Lax/);
  assert.equal(getDatabase().prepare('SELECT COUNT(*) count FROM user_sessions').get().count, 1);

  const consent = await request(app).get(continuePath).set('Cookie', cookie).expect(200);
  assert.match(consent.text, /Connect NeoAgent/);
  assert.match(consent.text, /cannot record audio, modify memories, or trigger NeoRecall/);

  const approval = await request(app).post('/oauth/authorize').set('Cookie', cookie)
    .type('form').send({ ...authorization, decision: 'approve' }).expect(302);
  const redirect = new URL(approval.headers.location);
  assert.equal(redirect.origin, 'https://agent.example.test');
  assert.equal(redirect.searchParams.get('state'), authorization.state);
  const code = redirect.searchParams.get('code');
  assert.match(code, /^nroc_/);

  const exchange = await request(app).post('/oauth/token').type('form').send({
    grant_type: 'authorization_code', client_id: bootstrap.body.clientId, code,
    redirect_uri: callback, code_verifier: verifier,
  }).expect(200);
  assert.match(exchange.body.access_token, /^nro_/);
  assert.match(exchange.body.refresh_token, /^nrr_/);
  assert.equal(exchange.body.scope, bootstrap.body.scopes.join(' '));

  const authorizationHeader = `Bearer ${exchange.body.access_token}`;
  const meta = await request(app).get('/api/v1/meta').set('Authorization', authorizationHeader).expect(200);
  assert.equal(meta.body.user.username, 'recall-owner');
  await request(app).get('/api/v1/memories').set('Authorization', authorizationHeader).expect(200);
  await request(app).post('/api/v1/search/ask').set('Authorization', authorizationHeader)
    .send({ question: 'What happened?' }).expect(403);

  const userinfo = await request(app).get('/oauth/userinfo').set('Authorization', authorizationHeader).expect(200);
  assert.equal(userinfo.body.email, 'recall@example.test');

  const refreshed = await request(app).post('/oauth/token').type('form').send({
    grant_type: 'refresh_token', client_id: bootstrap.body.clientId,
    refresh_token: exchange.body.refresh_token,
  }).expect(200);
  assert.notEqual(refreshed.body.access_token, exchange.body.access_token);
  assert.notEqual(refreshed.body.refresh_token, exchange.body.refresh_token);
  await request(app).get('/api/v1/meta').set('Authorization', authorizationHeader).expect(401);
  await request(app).get('/api/v1/meta').set('Authorization', `Bearer ${refreshed.body.access_token}`).expect(200);
  await request(app).post('/oauth/token').type('form').send({
    grant_type: 'refresh_token', client_id: bootstrap.body.clientId,
    refresh_token: exchange.body.refresh_token,
  }).expect(400);

  await request(app).post('/oauth/revoke').type('form').send({
    client_id: bootstrap.body.clientId, token: refreshed.body.refresh_token,
  }).expect(200);
  await request(app).get('/api/v1/meta')
    .set('Authorization', `Bearer ${refreshed.body.access_token}`).expect(401);
  await request(app).post('/oauth/token').type('form').send({
    grant_type: 'refresh_token', client_id: bootstrap.body.clientId,
    refresh_token: refreshed.body.refresh_token,
  }).expect(400);
});
