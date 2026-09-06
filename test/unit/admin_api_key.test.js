'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CLI = path.join(__dirname, '..', '..', 'bin', 'neorecall.js');

function runCli(home, args) {
  return spawnSync(process.execPath, [CLI, ...args], {
    encoding: 'utf8',
    env: { ...process.env, NEORECALL_HOME: home },
  });
}

function readEnvValue(home, key) {
  const raw = fs.readFileSync(path.join(home, '.env'), 'utf8');
  const line = raw.split('\n').find((entry) => entry.startsWith(`${key}=`));
  return line ? line.slice(key.length + 1) : null;
}

// The desktop installer reads this key to configure transcription and
// language-model providers from the app, so it has to exist after a first run
// and stay the same on every later one.
test('admin-key creates a key once and reuses it afterwards', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-adminkey-'));
  try {
    const first = runCli(home, ['admin-key', '--json']);
    assert.equal(first.status, 0, first.stderr);
    const created = JSON.parse(first.stdout.trim());
    assert.equal(created.created, true);
    assert.match(created.adminApiKey, /^[A-Za-z0-9_-]{40,}$/);
    assert.equal(readEnvValue(home, 'ADMIN_API_KEY'), created.adminApiKey);

    const second = runCli(home, ['admin-key', '--json']);
    assert.equal(second.status, 0, second.stderr);
    const reused = JSON.parse(second.stdout.trim());
    assert.equal(reused.adminApiKey, created.adminApiKey);
    assert.equal(reused.created, false);

    // The file keeps exactly one entry for the key, not one per run.
    const occurrences = fs.readFileSync(path.join(home, '.env'), 'utf8')
      .split('\n').filter((line) => line.startsWith('ADMIN_API_KEY=')).length;
    assert.equal(occurrences, 1);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test('the key is stored in a file only the owner can read', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-adminkey-mode-'));
  try {
    assert.equal(runCli(home, ['admin-key', '--json']).status, 0);
    const mode = fs.statSync(path.join(home, '.env')).mode & 0o777;
    assert.equal(mode, 0o600);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
