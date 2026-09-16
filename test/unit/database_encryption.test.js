'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-db-enc-'));
process.env.NEORECALL_REQUIRE_VECTOR = 'false';

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { isPlainSqliteFile } = require('../../server/db/sqlite');

migrate();
test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('the live database is ciphertext on disk and still readable', () => {
  const db = getDatabase();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES ('u-enc','unique-secret-username','x')").run();
  const filename = path.join(process.env.NEORECALL_HOME, 'data', 'neorecall.sqlite3');
  closeDatabase();

  assert.equal(isPlainSqliteFile(filename), false);
  const raw = fs.readFileSync(filename);
  assert.ok(!raw.includes(Buffer.from('SQLite format 3')), 'the SQLite header is not in the clear');
  assert.ok(!raw.includes(Buffer.from('unique-secret-username')), 'account names are not in the clear');

  const reopened = getDatabase();
  assert.equal(
    reopened.prepare('SELECT username FROM users WHERE id=?').get('u-enc').username,
    'unique-secret-username',
  );
});

test('a leftover plaintext database is encrypted on the next open', () => {
  const Database = require('better-sqlite3-multiple-ciphers');
  const filename = path.join(process.env.NEORECALL_HOME, 'data', 'legacy.sqlite3');
  const legacy = new Database(filename);
  legacy.exec("CREATE TABLE users (id TEXT, username TEXT); INSERT INTO users VALUES ('legacy','legacy-plain-user');");
  legacy.close();
  assert.equal(isPlainSqliteFile(filename), true);
  assert.ok(fs.readFileSync(filename).includes(Buffer.from('legacy-plain-user')));

  const { openKeyedDatabase } = require('../../server/db/sqlite');
  const opened = openKeyedDatabase(filename);
  assert.equal(opened.prepare('SELECT username FROM users').get().username, 'legacy-plain-user');
  opened.close();
  assert.equal(isPlainSqliteFile(filename), false);
  assert.ok(!fs.readFileSync(filename).includes(Buffer.from('legacy-plain-user')));
});
