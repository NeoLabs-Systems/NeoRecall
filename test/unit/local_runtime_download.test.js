'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { downloadVerified } = require('../../server/local_runtime/download');
const { fileServer } = require('../helpers/file_server');

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-download-'));
test.after(() => fs.rmSync(directory, { recursive: true, force: true }));

const body = crypto.randomBytes(200_000);
const sha256 = crypto.createHash('sha256').update(body).digest('hex');
// Fetched through `http://` on loopback; production manifests require https, which
// is the manifest validator's concern and not the downloader's.
const fast = { attempts: 4, idleTimeoutMs: 400 };

test('downloads, verifies and reuses a file', async () => {
  const server = await fileServer({ '/a': { body } });
  const destination = path.join(directory, 'a.bin');
  const file = { url: server.url('/a'), size: body.length, sha256 };
  assert.equal((await downloadVerified(file, destination, fast)).cached, false);
  assert.deepEqual(fs.readFileSync(destination), body);
  assert.equal((await downloadVerified(file, destination, fast)).cached, true);
  assert.equal(server.hits.length, 1, 'a verified file is not fetched again');
  await server.close();
});

test('resumes after the connection drops instead of starting over', async () => {
  const server = await fileServer({ '/b': { body, dropAfter: 60_000 } });
  const destination = path.join(directory, 'b.bin');
  await downloadVerified({ url: server.url('/b'), size: body.length, sha256 }, destination, fast);
  assert.deepEqual(fs.readFileSync(destination), body);
  assert.ok(server.hits.some((hit) => /^bytes=\d+-$/.test(hit.range || '')), 'the second attempt asked for the rest');
  await server.close();
});

test('abandons a stalled transfer and resumes it', async () => {
  const server = await fileServer({ '/c': { body, stallAfter: 50_000 } });
  const destination = path.join(directory, 'c.bin');
  const started = Date.now();
  await downloadVerified({ url: server.url('/c'), size: body.length, sha256 }, destination, fast);
  assert.deepEqual(fs.readFileSync(destination), body);
  assert.ok(Date.now() - started < 5_000, 'the idle timeout, not a long request timeout, ended the stall');
  await server.close();
});

test('a server that ignores the range does not corrupt the file', async () => {
  const server = await fileServer({ '/d': { body, dropAfter: 30_000, ignoreRange: true } });
  const destination = path.join(directory, 'd.bin');
  await downloadVerified({ url: server.url('/d'), size: body.length, sha256 }, destination, fast);
  assert.deepEqual(fs.readFileSync(destination), body);
  await server.close();
});

test('a wrong checksum is thrown away and reported, never installed', async () => {
  const server = await fileServer({ '/e': { body } });
  const destination = path.join(directory, 'e.bin');
  await assert.rejects(
    downloadVerified({ url: server.url('/e'), size: body.length, sha256: '0'.repeat(64) }, destination, { ...fast, attempts: 2 }),
    { code: 'LOCAL_CHECKSUM_MISMATCH' },
  );
  assert.equal(fs.existsSync(destination), false);
  assert.equal(fs.existsSync(`${destination}.partial`), false);
  await server.close();
});

test('a missing file fails at once instead of being retried', async () => {
  const server = await fileServer({});
  await assert.rejects(
    downloadVerified({ url: server.url('/missing'), size: 10, sha256 }, path.join(directory, 'f.bin'), fast),
    { code: 'LOCAL_DOWNLOAD_HTTP' },
  );
  assert.equal(server.hits.length, 1);
  await server.close();
});
