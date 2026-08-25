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

test('the manifest installs what listens to audio, never what recognizes or generates', () => {
  // The line is drawn by what a service can give back rather than by size
  // alone. Speech detection and diarization stay because a transcription
  // service returns words, not voices, and only a voice embedding makes a
  // speaker the same person in a later recording — and they are small enough
  // for that to cost nothing much. Speech recognition and a language model are
  // gigabytes and are exactly what an external provider does well, so they are
  // never installed here.
  const installed = manifest.models.flatMap((model) => model.files).map((file) => file.path);
  assert.ok(installed.some((file) => file.includes('multilingual-e5-small')), 'local search needs its embeddings');
  assert.ok(installed.some((file) => file.startsWith('vad/')), 'speech detection is what keeps silence off a paid endpoint');
  assert.ok(installed.some((file) => file.startsWith('diarization/')), 'speaker identity comes from voice embeddings computed here');
  assert.equal(installed.some((file) => file.startsWith('asr/') || file.startsWith('llm/')), false,
    'recognition and generation belong to a provider, not to this repository');
  // The whole point of keeping them is that they are unremarkable next to what
  // was removed.
  const audioBytes = manifest.models.flatMap((model) => model.files)
    .filter((file) => file.path.startsWith('vad/') || file.path.startsWith('diarization/'))
    .reduce((sum, file) => sum + file.size, 0);
  assert.ok(audioBytes < 64 * 1024 * 1024, `audio models grew to ${(audioBytes / 1e6).toFixed(0)} MB; that is no longer lightweight`);
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
  const ownModel = seed('llm/operator-supplied.bin', 256);

  const removed = pruneRetired();
  assert.deepEqual(removed.map((entry) => entry.path), [retired]);
  assert.equal(removed[0].bytes, 1536, 'a half-finished download is reclaimed too');

  const models = ensureRuntimeDirs().models;
  assert.ok(!fs.existsSync(path.join(models, retired)));
  assert.ok(!fs.existsSync(path.join(models, `${retired}.partial`)));
  assert.ok(fs.existsSync(ownModel), 'a model the operator put there is not ours to delete');

  assert.deepEqual(pruneRetired(), [], 'pruning twice is a no-op');
});

test('an obsolete LLM_MODEL_FILE setting cannot keep a retired bundled model installed', () => {
  const retired = (manifest.retired || [])[0];
  const filename = seed(retired, 1024);
  process.env.LLM_MODEL_FILE = retired;
  try {
    assert.deepEqual(pruneRetired().map((entry) => entry.path), [retired]);
    assert.equal(fs.existsSync(filename), false);
  } finally {
    delete process.env.LLM_MODEL_FILE;
  }
  fs.rmSync(filename, { force: true });
});
