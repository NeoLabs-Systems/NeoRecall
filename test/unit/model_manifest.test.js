'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-models-'));
process.env.NEORECALL_HOME = home;

const manifest = require('../../models/manifest.json');
const { pruneRetired } = require('../../lib/model_downloader');
const { ensureRuntimeDirs } = require('../../runtime/paths');

test.after(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

function seed(relative, bytes) {
  const filename = path.join(ensureRuntimeDirs().models, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, Buffer.alloc(bytes));
  return filename;
}

test('every manifest entry is pinned well enough to verify after download', () => {
  assert.ok(manifest.models.length > 0);
  for (const model of manifest.models) {
    assert.ok(model.id, 'a model needs an id');
    assert.ok(model.license, `${model.id} needs a license`);
    assert.ok(model.files.length > 0, `${model.id} needs files`);
    for (const file of model.files) {
      assert.match(file.sha256, /^[0-9a-f]{64}$/, `${file.path} needs a real sha256`);
      assert.ok(Number.isInteger(file.size) && file.size > 0, `${file.path} needs a byte size`);
      // Hub downloads resolve hubPath at a pinned revision; everything else
      // needs either a direct URL or an archive to extract from.
      if (model.huggingFace) assert.ok(file.hubPath && model.revision, `${file.path} needs hubPath + revision`);
      else assert.ok(file.url || file.archivePath, `${file.path} needs a url or archivePath`);
    }
  }
});

test('the configured default language model is one the manifest installs', () => {
  const source = fs.readFileSync(path.join(__dirname, '../../server/config.js'), 'utf8');
  const configured = source.match(/defaultLlmModelFile = '([^']+)'/)[1];
  const installed = manifest.models.flatMap((model) => model.files).map((file) => file.path);
  assert.ok(
    installed.includes(configured),
    `config defaults to ${configured}, which setup never downloads`,
  );
});

test('a retired model is never still installed by the same manifest', () => {
  const installed = new Set(manifest.models.flatMap((model) => model.files).map((file) => file.path));
  for (const retired of manifest.retired || []) {
    assert.ok(!installed.has(retired), `${retired} is both retired and installed`);
  }
});

test('update reclaims a superseded model without touching anything else', () => {
  const retired = (manifest.retired || [])[0];
  assert.ok(retired, 'expected at least one retired model to exercise pruning');

  seed(retired, 1024);
  seed(`${retired}.partial`, 512);
  const ownModel = seed('llm/operator-supplied.gguf', 256);

  const removed = pruneRetired();
  assert.deepEqual(removed.map((entry) => entry.path), [retired]);
  assert.equal(removed[0].bytes, 1536, 'a half-finished download is reclaimed too');

  const models = ensureRuntimeDirs().models;
  assert.ok(!fs.existsSync(path.join(models, retired)));
  assert.ok(!fs.existsSync(path.join(models, `${retired}.partial`)));
  assert.ok(fs.existsSync(ownModel), 'a model the operator put there is not ours to delete');

  assert.deepEqual(pruneRetired(), [], 'pruning twice is a no-op');
});

test('a retired model the operator pinned is left alone', () => {
  const retired = (manifest.retired || [])[0];
  const filename = seed(retired, 1024);
  process.env.LLM_MODEL_FILE = retired;
  try {
    assert.deepEqual(pruneRetired(), []);
    assert.ok(fs.existsSync(filename), 'LLM_MODEL_FILE is an explicit choice, not leftovers');
  } finally {
    delete process.env.LLM_MODEL_FILE;
  }
  fs.rmSync(filename, { force: true });
});
