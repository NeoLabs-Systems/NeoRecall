'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-mcp-oauth-'));
const { createApp } = require('../../server/app');
const { closeDatabase, getDatabase } = require('../../server/db/database');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

function pkce() {
  const verifier = 'mcp-pkce-verifier-long-enough-for-a-secure-test';
  return {
    verifier,
    challenge: crypto.createHash('sha256').update(verifier).digest('base64url'),
  };
}

async function registerOwner() {
  const password = 'a long and unique password';
  const registered = await request(app).post('/api/v1/auth/register').send({
    username: 'mcp-owner', email: 'mcp@example.test', password,
  }).expect(201);
  return { password, userId: registered.body.user.id, session: registered.body.session.token };
}

async function authorizeClient({ password, clientId, redirectUri, scopes }) {
  const { verifier, challenge } = pkce();
  const authorization = {
    response_type: 'code', client_id: clientId, redirect_uri: redirectUri,
    state: '0123456789abcdef0123456789abcdef',
    scope: scopes.join(' '), code_challenge: challenge, code_challenge_method: 'S256',
  };
  const continuePath = `/oauth/authorize?${new URLSearchParams(authorization)}`;
  const signIn = await request(app).post('/oauth/sign-in').type('form').send({
    account: 'mcp-owner', password, continue: continuePath,
  }).expect(302);
  const cookie = signIn.headers['set-cookie'][0].split(';')[0];
  const consent = await request(app).get(continuePath).set('Cookie', cookie).expect(200);
  const approval = await request(app).post('/oauth/authorize').set('Cookie', cookie)
    .type('form').send({ ...authorization, decision: 'approve' }).expect(302);
  const code = new URL(approval.headers.location).searchParams.get('code');
  const tokens = await request(app).post('/oauth/token').type('form').send({
    grant_type: 'authorization_code', client_id: clientId, code,
    redirect_uri: redirectUri, code_verifier: verifier,
  }).expect(200);
  return { consent, tokens, authorization: `Bearer ${tokens.body.access_token}` };
}

test('MCP OAuth registers a public client, issues read-only tools, and excludes Ask', async () => {
  const owner = await registerOwner();
  const metadata = await request(app).get('/.well-known/oauth-authorization-server')
    .set('Host', 'recall.lan:4500').expect(200);
  assert.equal(metadata.body.issuer, 'http://recall.lan:4500');
  assert.equal(metadata.body.registration_endpoint, 'http://recall.lan:4500/oauth/register');
  assert.deepEqual(metadata.body.token_endpoint_auth_methods_supported, ['none']);

  const resource = await request(app).get('/.well-known/oauth-protected-resource')
    .set('Host', 'recall.lan:4500').expect(200);
  assert.equal(resource.body.resource, 'http://recall.lan:4500/mcp');
  const resourcePath = await request(app).get('/.well-known/oauth-protected-resource/mcp')
    .set('Host', 'recall.lan:4500').expect(200);
  assert.equal(resourcePath.body.resource, 'http://recall.lan:4500/mcp');

  await request(app).post('/oauth/register').send({
    client_name: 'Claude',
    redirect_uris: ['http://chatgpt.example.test/callback'],
  }).expect(400);

  const created = await request(app).post('/oauth/register').send({
    client_name: 'Claude',
    redirect_uris: ['https://claude.example.test/api/mcp/auth_callback'],
    token_endpoint_auth_method: 'none',
  }).expect(201);
  assert.match(created.body.client_id, /^nrc_/);
  assert.equal(created.body.token_endpoint_auth_method, 'none');
  assert.match(created.body.scope, /search:read/);

  const unauthorized = await request(app).post('/mcp').send({
    jsonrpc: '2.0', id: 1, method: 'initialize', params: {},
  }).expect(401);
  assert.match(String(unauthorized.headers['www-authenticate']), /resource_metadata=/);

  const { consent, authorization } = await authorizeClient({
    password: owner.password, clientId: created.body.client_id,
    redirectUri: created.body.redirect_uris[0],
    scopes: created.body.scope.split(' '),
  });
  assert.match(consent.text, /Connect Claude/);
  assert.match(consent.text, /cannot record audio, modify memories, or trigger NeoRecall/);

  const init = await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 1, method: 'initialize', params: {},
  }).expect(200);
  assert.equal(init.body.result.protocolVersion, '2025-03-26');
  assert.equal(init.body.result.serverInfo.name, 'neorecall');

  const listed = await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 2, method: 'tools/list',
  }).expect(200);
  const names = listed.body.result.tools.map((tool) => tool.name);
  assert.deepEqual(names, [
    'search', 'list_memories', 'get_memory', 'list_mini_memories',
    'list_daily_summaries', 'list_conversations', 'get_conversation',
  ]);
  assert.ok(!names.includes('ask'));

  const conversationId = crypto.randomUUID();
  getDatabase().prepare(`INSERT INTO conversations
    (id,user_id,started_at,ended_at,state,boundary_method,boundary_version,title_en)
    VALUES (?,?,?,?, 'closed','test','1','Standup')`)
    .run(conversationId, owner.userId, '2026-09-05T10:00:00.000Z', '2026-09-05T10:20:00.000Z');

  const listCall = await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 3, method: 'tools/call',
    params: { name: 'list_conversations', arguments: { limit: 10 } },
  }).expect(200);
  assert.equal(listCall.body.result.isError, undefined);
  const listedConversations = JSON.parse(listCall.body.result.content[0].text);
  assert.equal(listedConversations.items[0].id, conversationId);

  const conversationCall = await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 4, method: 'tools/call',
    params: { name: 'get_conversation', arguments: { id: conversationId } },
  }).expect(200);
  const conversation = JSON.parse(conversationCall.body.result.content[0].text);
  assert.equal(conversation.id, conversationId);
  assert.equal(conversation.title_en, 'Standup');

  const askCall = await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 5, method: 'tools/call',
    params: { name: 'ask', arguments: { question: 'What happened?' } },
  }).expect(200);
  assert.equal(askCall.body.result.isError, true);

  const sessionAuth = { Authorization: `Bearer ${owner.session}` };
  const connections = await request(app).get('/api/v1/integrations').set(sessionAuth).expect(200);
  assert.equal(connections.body.integrations.length, 1);
  assert.equal(connections.body.integrations[0].name, 'Claude');
  await request(app).get('/api/v1/integrations').set('Authorization', authorization).expect(403);
  await request(app).delete(`/api/v1/integrations/${created.body.client_id}`).set(sessionAuth).expect(204);
  await request(app).post('/mcp').set('Authorization', authorization).send({
    jsonrpc: '2.0', id: 6, method: 'tools/list',
  }).expect(401);
});
