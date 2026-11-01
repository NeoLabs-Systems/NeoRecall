'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-not-found-'));
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');
const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('an unknown page in a browser gets the 404 page, API clients keep the JSON error', async () => {
  const page = await request(app).get('/no/such/page').set('Accept', 'text/html,application/xhtml+xml,*/*;q=0.8');
  assert.equal(page.status, 404);
  assert.match(page.headers['content-type'], /^text\/html/);
  assert.match(page.text, /Except this page/);

  for (const [url, accept] of [['/no/such/page', 'application/json'], ['/no/such/page', '*/*'], ['/api/v1/nope', 'text/html']]) {
    const api = await request(app).get(url).set('Accept', accept);
    assert.equal(api.status, 404, url);
    assert.equal(api.body.error.code, 'NOT_FOUND', `${url} ${accept}`);
  }
});
