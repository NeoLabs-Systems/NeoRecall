'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { NOTES_END, NOTES_START, buildDownloadNotes, classifyAppAsset, mergeDownloadNotes } = require('../../scripts/release_download_notes');

const TAG = 'v0.1.4-beta.4';
const ASSETS = [
  'NeoRecall-macOS-0.1.4-beta.4.dmg',
  'NeoRecall-Windows-x64-0.1.4-beta.4.zip',
  'NeoRecall-Android-0.1.4-beta.4.apk',
  'NeoRecall-WearOS-0.1.4-beta.4.apk',
  'firmware.bin',
].map((name) => ({ name }));

test('each release file finds its button; raw binaries and checksums get none', () => {
  assert.deepEqual(ASSETS.map((asset) => classifyAppAsset(asset.name)?.id ?? null), [
    'macos', 'windows-x64', 'android', 'wearos', null,
  ]);
});

test('ready apps link to their file, missing ones say building', () => {
  const partial = buildDownloadNotes({ tag: TAG, assets: ASSETS.slice(0, 1) });
  assert.match(partial, /href="https:\/\/github\.com\/NeoLabs-Systems\/NeoRecall\/releases\/download\/v0\.1\.4-beta\.4\/NeoRecall-macOS-0\.1\.4-beta\.4\.dmg"/);
  assert.match(partial, /Windows-building-6b7280/);
  assert.match(partial, /The rest attach/);
  const full = buildDownloadNotes({ tag: TAG, assets: ASSETS });
  assert.doesNotMatch(full, /building/);
  assert.match(full, /Every app for this release is ready\./);
});

test('a refresh replaces only the download section and keeps the changelog', () => {
  const first = mergeDownloadNotes('**Full Changelog**: x...y', buildDownloadNotes({ tag: TAG }));
  assert.ok(first.startsWith(NOTES_START));
  assert.match(first, /\*\*Full Changelog\*\*: x\.\.\.y\n?$/);
  const second = mergeDownloadNotes(first, buildDownloadNotes({ tag: TAG, assets: ASSETS }));
  assert.equal(second.split(NOTES_START).length, 2);
  assert.equal(second.split(NOTES_END).length, 2);
  assert.match(second, /Full Changelog/);
  assert.doesNotMatch(second, /building/);
});
