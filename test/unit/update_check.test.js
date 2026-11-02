'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { checkForUpdate, resolvePreferredBranch } = require('../../runtime/update_check');

// A scripted git: answers by the first matching prefix of the joined args.
function fakeGit(answers) {
  return (_cmd, args) => {
    const key = args.join(' ');
    const hit = Object.entries(answers).find(([prefix]) => key.startsWith(prefix));
    return hit ? { status: 0, stdout: hit[1] } : { status: 1, stdout: '' };
  };
}

const manifest = (version) => JSON.stringify({ version });

test('stable follows main, beta follows beta until a stable release passes it', () => {
  const branches = { 'rev-parse --verify --quiet refs/remotes/origin/main': '', 'rev-parse --verify --quiet refs/remotes/origin/beta': '' };
  assert.equal(resolvePreferredBranch('stable', fakeGit(branches)), 'main');
  assert.equal(resolvePreferredBranch('beta', fakeGit({ ...branches, 'tag --list v[0-9]*.[0-9]*.[0-9]*-beta.*': 'v1.3.0-beta.1\n', 'tag --list v[0-9]*.[0-9]*.[0-9]* ': 'v1.2.0\n' })), 'beta');
  assert.equal(resolvePreferredBranch('beta', fakeGit({ ...branches, 'tag --list v[0-9]*.[0-9]*.[0-9]*-beta.*': 'v1.3.0-beta.1\n', 'tag --list v[0-9]*.[0-9]*.[0-9]* ': 'v1.4.0\n' })), 'main');
  assert.equal(resolvePreferredBranch('beta', fakeGit(branches)), 'beta');
});

test('stable falls back to beta only while main does not exist', () => {
  const run = fakeGit({ 'rev-parse --verify --quiet refs/remotes/origin/beta': '' });
  const notes = [];
  assert.equal(resolvePreferredBranch('stable', run, { onFallback: (note) => notes.push(note) }), 'beta');
  assert.equal(notes.length, 1);
});

test('a newer version on the branch is reported with its changes', async () => {
  const run = fakeGit({
    'rev-parse --verify --quiet refs/remotes/origin/beta': '',
    'rev-parse --abbrev-ref HEAD': 'beta',
    'rev-parse HEAD': 'aaa',
    'rev-list --count': '2',
    'show origin/beta:package.json': manifest('0.2.0'),
    'show HEAD:package.json': manifest('0.1.0'),
    'log --no-merges': 'Add a thing\nchore: bump',
  });
  const result = await checkForUpdate({ run, channel: 'beta', fetchRemote: async () => true });
  assert.equal(result.checked, true);
  assert.deepEqual(result.update, { version: '0.2.0', branch: 'beta', changes: ['Add a thing'] });
});

test('an unreachable remote is not an answer', async () => {
  const result = await checkForUpdate({ run: fakeGit({}), channel: 'beta', fetchRemote: async () => false });
  assert.deepEqual(result, { checked: false, update: null, reason: 'offline' });
});
