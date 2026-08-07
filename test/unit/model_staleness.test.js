'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Reproduces a real incident. When the pinned speech model changed, a machine
// that still had the previous generation on disk kept reporting ready: the
// filenames were identical, so every existence check passed. The recogniser then
// loaded a transducer encoder through the Whisper code path, aborted the
// inference host on the first chunk, and did that again on every retry — a
// server that looked healthy and transcribed nothing, indefinitely.
process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-staleness-'));
test.after(() => fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }));

const { manifest, installedMatchesManifest } = require('../../lib/model_downloader');
const { SherpaProvider } = require('../../server/transcription/providers/sherpa_provider');
const aiProviders = require('../../server/ai/provider_registry');

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
  const filename = write('llm/some-model-i-chose.gguf', 4);
  assert.equal(installedMatchesManifest('llm/some-model-i-chose.gguf', filename), true);
});

test('a stale model directory reports not ready instead of failing every job', async () => {
  for (const model of manifest.models) for (const file of model.files) write(file.path, 8);
  assert.equal(await new SherpaProvider().ready(), false, 'Speech models must not read as ready.');
  assert.equal(aiProviders.ready(), false, 'The language model must not read as ready.');
});

test('a directory holding exactly what this version pins reports ready', async () => {
  for (const model of manifest.models) for (const file of model.files) write(file.path, file.size);
  assert.equal(await new SherpaProvider().ready(), true);
  assert.equal(aiProviders.ready(), true);
});
