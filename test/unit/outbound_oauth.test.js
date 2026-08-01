'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

// Seal OAuth state with the same secret.key the runtime uses; isolate to a temp home.
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-oauth-test-'));
process.env.NEORECALL_HOME = home;
fs.mkdirSync(path.join(home), { recursive: true });

const oauth = require('../../server/services/sources/oauth/outbound_oauth');

test('issueState and consumeState round-trip a payload once', () => {
  const state = oauth.issueState({ userId: 'user-1', provider: 'zoom' });
  assert.equal(typeof state, 'string');
  const body = oauth.consumeState(state);
  assert.equal(body.userId, 'user-1');
  assert.equal(body.provider, 'zoom');
  assert.ok(body.nonce);
  assert.throws(() => oauth.consumeState(state), /already used|invalid|expired/i);
});

test('consumeState rejects garbage and expired payloads', () => {
  assert.throws(() => oauth.consumeState('not-valid'), /invalid|verified/i);
  assert.throws(() => oauth.consumeState(''), /missing|invalid/i);
});

test('pkcePair returns a verifier and S256 challenge', () => {
  const pair = oauth.pkcePair();
  assert.ok(pair.verifier.length > 10);
  assert.ok(pair.challenge.length > 10);
  assert.notEqual(pair.verifier, pair.challenge);
});

test('buildAuthorizeUrl includes client, redirect, state, and scopes', () => {
  const url = oauth.buildAuthorizeUrl(
    {
      authorizationUrl: 'https://example.test/oauth/authorize',
      clientId: 'cid',
      scopes: ['a', 'b'],
      extraAuthorizeParams: { prompt: 'consent' },
    },
    {
      redirectUri: 'https://app.test/callback',
      state: 'signed-state',
      codeChallenge: 'chal',
    },
  );
  const parsed = new URL(url);
  assert.equal(parsed.searchParams.get('client_id'), 'cid');
  assert.equal(parsed.searchParams.get('redirect_uri'), 'https://app.test/callback');
  assert.equal(parsed.searchParams.get('state'), 'signed-state');
  assert.equal(parsed.searchParams.get('scope'), 'a b');
  assert.equal(parsed.searchParams.get('code_challenge'), 'chal');
  assert.equal(parsed.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(parsed.searchParams.get('prompt'), 'consent');
});

test('needsRefresh respects expiry skew', () => {
  assert.equal(oauth.needsRefresh({ accessToken: 't', expiresAt: null }), false);
  assert.equal(oauth.needsRefresh({ accessToken: null }), true);
  assert.equal(
    oauth.needsRefresh({
      accessToken: 't',
      expiresAt: new Date(Date.now() + 10 * 60_000).toISOString(),
    }),
    false,
  );
  assert.equal(
    oauth.needsRefresh({
      accessToken: 't',
      expiresAt: new Date(Date.now() + 10_000).toISOString(),
    }),
    true,
  );
});
