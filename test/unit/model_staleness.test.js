'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// A file left by a previous pinned search model can have the expected name and
// the wrong contents. Readiness must distinguish it from the current asset.
process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-staleness-'));
test.after(() => fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }));

const { manifest, installedMatchesManifest } = require('../../lib/model_downloader');

const models = path.join(process.env.NEORECALL_HOME, 'models');

// Sparse: a pinned model file is gigabytes, and only its size is under test.
function write(relativePath, bytes) {
  const filename = path.join(models, relativePath);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.closeSync(fs.openSync(filename, 'w'));
  fs.truncateSync(filename, bytes);
  return filename;
}

const [firstFile] = manifest.models[0].files;

test('a file with the right name and the wrong contents does not count as installed', () => {
  const filename = write(firstFile.path, 8);
  assert.equal(installedMatchesManifest(firstFile.path, filename), false);
});

test('a file matching what the manifest pins counts as installed', () => {
  // Size, not SHA-256: this runs on the readiness path, where hashing gigabytes
  // on every probe is not affordable. `verifyAll` does the cryptographic check
  // during setup, where it belongs.
  const filename = write(firstFile.path, firstFile.size);
  assert.equal(installedMatchesManifest(firstFile.path, filename), true);
});

test('a path the manifest does not describe is the operator\'s own and is accepted', () => {
  const filename = write('llm/an-endpoint-i-manage.bin', 4);
  assert.equal(installedMatchesManifest('llm/an-endpoint-i-manage.bin', filename), true);
});
