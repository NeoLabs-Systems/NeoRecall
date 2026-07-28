'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-channel-'));
process.env.NEORECALL_HOME = home;
delete process.env.NEORECALL_RELEASE_CHANNEL;

const {
  parseReleaseChannel,
  writeReleaseChannelToEnvFile,
  readConfiguredReleaseChannel,
  choosePreferredBranchForChannel,
} = require('../../runtime/release_channel');
const { ENV_FILE, ensureRuntimeDirs } = require('../../runtime/paths');
const { hasBundledWebClient } = require('../../lib/install_helpers');

test.after(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

test('release channel parses aliases and persists to env file', () => {
  ensureRuntimeDirs();
  assert.equal(parseReleaseChannel('preview'), 'beta');
  assert.equal(parseReleaseChannel('main'), 'stable');
  writeReleaseChannelToEnvFile('stable', ENV_FILE);
  assert.equal(readConfiguredReleaseChannel({ env: {}, envFile: ENV_FILE }), 'stable');
  writeReleaseChannelToEnvFile('beta', ENV_FILE);
  assert.equal(readConfiguredReleaseChannel({ env: {}, envFile: ENV_FILE }), 'beta');
});

test('beta channel prefers the newer git branch', () => {
  assert.equal(choosePreferredBranchForChannel('stable', { stable: '1.0.0', beta: '1.1.0-beta.0' }), 'main');
  assert.equal(choosePreferredBranchForChannel('beta', { stable: '1.0.0', beta: '1.1.0-beta.0' }), 'beta');
  assert.equal(choosePreferredBranchForChannel('beta', { stable: '1.2.0', beta: '1.1.0-beta.9' }), 'main');
});

test('bundled web client detection requires index and bootstrap assets', () => {
  const dir = path.join(home, 'web');
  fs.mkdirSync(dir, { recursive: true });
  assert.equal(hasBundledWebClient(dir), false);
  fs.writeFileSync(path.join(dir, 'index.html'), '<html></html>');
  assert.equal(hasBundledWebClient(dir), false);
  fs.writeFileSync(path.join(dir, 'main.dart.js'), '//');
  assert.equal(hasBundledWebClient(dir), true);
});
