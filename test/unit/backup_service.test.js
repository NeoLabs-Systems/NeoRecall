'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-backup-'));
process.env.NEORECALL_BACKUP_RETAIN = '2';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const backups = require('../../server/services/backup/backup_service');
const { createDestination } = require('../../server/services/backup/destinations');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('a backup produces an encrypted artifact that restores to the same database', async () => {
  const db = getDatabase();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES ('u1','backup-user','x')").run();
  const result = await backups.run({ triggerKind: 'manual' });

  const artifact = path.join(process.env.NEORECALL_HOME, 'backups', result.key);
  assert.ok(fs.existsSync(artifact), 'the artifact is written to the destination');
  assert.equal(fs.statSync(artifact).mode & 0o777, 0o600);

  // Never plaintext at rest: the SQLite header must not survive encryption.
  const head = fs.readFileSync(artifact).subarray(0, 16);
  assert.equal(head.subarray(0, 4).toString('ascii'), 'NRB1');
  assert.ok(!fs.readFileSync(artifact).includes(Buffer.from('SQLite format 3')), 'the artifact is encrypted');

  const restored = path.join(process.env.NEORECALL_HOME, 'restored.sqlite3');
  const outcome = await backups.restore(result.key, restored);
  assert.equal(outcome.checksum, result.checksum, 'the restored file matches the snapshot checksum');

  const reopened = require('better-sqlite3')(restored, { readonly: true });
  assert.equal(reopened.prepare('SELECT username FROM users WHERE id=?').get('u1').username, 'backup-user');
  reopened.close();

  const row = db.prepare('SELECT * FROM backups WHERE id=?').get(result.id);
  assert.equal(row.state, 'succeeded');
  assert.equal(row.trigger_kind, 'manual');
  assert.equal(row.artifact_key, result.key);
});

test('retention keeps only the configured number of artifacts', async () => {
  const destination = createDestination('local');
  const directory = path.join(process.env.NEORECALL_HOME, 'backups');
  // Two older artifacts alongside the one the first test produced.
  for (const key of ['neorecall-20200101T000000Z-aaaaaa.nrbak', 'neorecall-20200102T000000Z-bbbbbb.nrbak']) {
    fs.writeFileSync(path.join(directory, key), 'stale', { mode: 0o600 });
  }
  assert.equal((await destination.list()).length, 3);
  await backups.run({ triggerKind: 'scheduled' });
  const remaining = await destination.list();
  assert.equal(remaining.length, 2, 'NEORECALL_BACKUP_RETAIN=2 is honoured');
  assert.ok(remaining.every((entry) => !entry.key.startsWith('neorecall-2020')), 'the oldest artifacts are the ones removed');
});

test('retention never touches files it did not write', async () => {
  const directory = path.join(process.env.NEORECALL_HOME, 'backups');
  const foreign = path.join(directory, 'operator-notes.txt');
  fs.writeFileSync(foreign, 'do not delete');
  await backups.run({ triggerKind: 'scheduled' });
  assert.ok(fs.existsSync(foreign), 'an unrelated file in the backup directory survives');
  await assert.rejects(() => require('../../server/services/backup/destinations').createDestination('local').remove('../../data/neorecall.sqlite3'),
    /unrecognized backup key/i, 'keys are validated before any filesystem action');
});

test('status reports schedule state and the destination location', async () => {
  const state = await backups.status();
  assert.equal(state.destination, 'local');
  assert.equal(state.enabled, true);
  assert.equal(state.retain, 2);
  assert.equal(state.location, path.join(process.env.NEORECALL_HOME, 'backups'));
  assert.equal(state.unreachable, null);
  assert.ok(state.lastSuccessAt, 'a completed run is reflected');
  assert.equal(state.due, false, 'a fresh backup is not immediately due again');
  assert.ok(state.artifactCount >= 1 && state.artifactBytes > 0);
  assert.equal(backups.history(5)[0].state, 'succeeded');
});

test('an unknown destination fails loudly instead of silently not backing up', async () => {
  process.env.NEORECALL_BACKUP_DESTINATION = 'nope';
  try {
    await assert.rejects(() => backups.run({ triggerKind: 'manual' }), /Unknown backup destination/);
  } finally {
    delete process.env.NEORECALL_BACKUP_DESTINATION;
    }
});
