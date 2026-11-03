'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'public-status-'));
process.env.NODE_ENV = 'test';
const { createApp } = require('../../server/app');
const { closeDatabase } = require('../../server/db/database');

test('public status and page are served without authentication', async () => {
  const server = createApp().listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const response = await fetch(base + '/api/public/status');
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const body = await response.json();
    assert.equal(body.product, 'NeoRecall');
    assert.equal(body.history.length, 48);
    assert.ok(body.components.some((item) => item.name === 'Storage'));
    const page = await fetch(base + '/status');
    assert.equal(page.status, 200);
    assert.match(await page.text(), /The last 48 hours/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    closeDatabase();
    fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
  }
});
