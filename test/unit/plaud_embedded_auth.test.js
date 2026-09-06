'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const auth = require('../../server/services/devices/plaud_embedded_auth');

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => JSON.stringify(body),
  };
}

test.afterEach(() => auth.resetCache());

test('mintUserSession is a no-op when partner credentials are missing', async () => {
  const session = await auth.mintUserSession('user-1', {
    config: { plaudClientId: '', plaudClientSecret: '', plaudApiHost: 'platform-us.plaud.ai' },
    fetchImpl: async () => {
      throw new Error('must not call Plaud');
    },
  });
  assert.equal(session, null);
});

test('mintUserSession exchanges a partner token for a per-user JWT and never requests audio APIs', async () => {
  const requested = [];
  const session = await auth.mintUserSession('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', {
    config: {
      plaudClientId: 'client',
      plaudClientSecret: 'secret',
      plaudApiHost: 'platform-us.plaud.ai',
    },
    fetchImpl: async (url, options) => {
      requested.push({ url: String(url), method: options.method, body: options.body });
      if (String(url).includes('/oauth/partner/access-token')) {
        return jsonResponse(200, { access_token: 'partner-jwt', expires_in: 3600 });
      }
      if (String(url).includes('/open/partner/users/access-token')) {
        return jsonResponse(200, { access_token: 'user-jwt', expires_in: 86400 });
      }
      throw new Error(`unexpected ${url}`);
    },
  });
  assert.equal(session.accessToken, 'user-jwt');
  assert.equal(session.customDomain, 'platform-us.plaud.ai');
  assert.equal(session.expiresIn, 86400);
  assert.equal(requested.length, 2);
  assert.match(requested[0].url, /\/oauth\/partner\/access-token$/);
  assert.match(requested[1].url, /\/open\/partner\/users\/access-token$/);
  assert.ok(!requested.some((call) => /transcription|upload|files/i.test(call.url)));
  const userBody = JSON.parse(requested[1].body);
  assert.equal(userBody.user_id, 'aaaaaaaabbbbccccddddeeeeeeeeeeee');
});

test('a cached partner token is reused until it is close to expiry', async () => {
  let partnerCalls = 0;
  const fetchImpl = async (url) => {
    if (String(url).includes('/oauth/partner/access-token')) {
      partnerCalls += 1;
      return jsonResponse(200, { access_token: 'partner-jwt', expires_in: 3600 });
    }
    return jsonResponse(200, { access_token: `user-${partnerCalls}`, expires_in: 86400 });
  };
  const config = { plaudClientId: 'c', plaudClientSecret: 's', plaudApiHost: 'platform-us.plaud.ai' };
  await auth.mintUserSession('user-aa', { config, fetchImpl });
  await auth.mintUserSession('user-bb', { config, fetchImpl });
  assert.equal(partnerCalls, 1);
});
