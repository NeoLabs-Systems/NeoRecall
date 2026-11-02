'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const manifestModule = require('../../server/local_runtime/manifest');

const raw = require('../../models/local_runtimes.json');

test('every pinned artifact is verifiable, over https, and the file validates', () => {
  const manifest = manifestModule.load();
  assert.deepEqual(manifest.components.map((component) => component.id).sort(), ['gemma-2-2b-it', 'whistle']);
  for (const component of manifest.components) {
    assert.ok(component.licenseUrl, `${component.id} links its license`);
    for (const platform of Object.values(component.platforms)) {
      for (const artifact of manifestModule.artifactsFor(component, platform)) {
        assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
        assert.ok(artifact.url.startsWith('https://'));
      }
    }
  }
});

test('both components cover the platforms the server image and the Mac clients run on', () => {
  for (const component of raw.components) {
    assert.deepEqual(Object.keys(component.platforms).sort(), ['darwin-arm64', 'darwin-x64', 'linux-x64'], component.id);
  }
});

test('a model that cannot hold what the consolidation budgets assume says so in its profile', () => {
  const gemma = raw.components.find((component) => component.id === 'gemma-2-2b-it');
  // The output budget has to leave room for a prompt inside the context.
  assert.ok(gemma.profile.consolidationOutputTokens + 512 < gemma.profile.contextSize);
  assert.ok(gemma.profile.previewOutputTokens < gemma.profile.consolidationOutputTokens);
});

test('a malformed manifest is refused before anything is downloaded', () => {
  const broken = JSON.parse(JSON.stringify(raw));
  broken.components[0].files[0].sha256 = 'abc';
  assert.throws(() => manifestModule.load(broken), /SHA-256/);
  const insecure = JSON.parse(JSON.stringify(raw));
  insecure.components[0].files[0].url = 'http://example.com/model';
  assert.throws(() => manifestModule.load(insecure), /https/);
});

test('the fingerprint changes when any pinned byte does', () => {
  const entry = raw.components[0];
  const platform = entry.platforms['linux-x64'];
  const before = manifestModule.fingerprint(entry, platform);
  const moved = JSON.parse(JSON.stringify(entry));
  moved.files[0].sha256 = '0'.repeat(64);
  assert.notEqual(manifestModule.fingerprint(moved, moved.platforms['linux-x64']), before);
});
