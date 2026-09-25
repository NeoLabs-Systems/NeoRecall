'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Database = require('better-sqlite3-multiple-ciphers');
const migration = require('../../server/db/migrations/036_account_admin');

// The pre-036 shape: accounts with a role, plus the separate dashboard login.
function legacySchema(db, accounts) {
  db.pragma('foreign_keys = ON');
  db.exec(`
    CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'user',
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
    CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, actor_type TEXT NOT NULL, actor_id TEXT,
      affected_user_id TEXT REFERENCES users(id) ON DELETE SET NULL, action TEXT NOT NULL, metadata_json TEXT);
    CREATE TABLE admins (id TEXT PRIMARY KEY, username TEXT NOT NULL);
    CREATE TABLE admin_sessions (id TEXT PRIMARY KEY, admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE);
    CREATE TABLE admin_two_factor (admin_id TEXT PRIMARY KEY REFERENCES admins(id) ON DELETE CASCADE);
    CREATE TABLE admin_recovery_codes (id TEXT PRIMARY KEY, admin_id TEXT NOT NULL REFERENCES admins(id) ON DELETE CASCADE);
    INSERT INTO admins (id, username) VALUES ('a1', 'dashboard');
    INSERT INTO admin_sessions (id, admin_id) VALUES ('s1', 'a1');
  `);
  const insert = db.prepare('INSERT INTO users (id, username, role) VALUES (?, ?, ?)');
  for (const [id, role] of accounts) insert.run(id, id, role);
}

function tables(db) {
  return db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'admin%'").all().map((row) => row.name);
}

test('the dashboard login tables are dropped', () => {
  const db = new Database(':memory:');
  legacySchema(db, [['u1', 'admin'], ['u2', 'user']]);
  db.transaction(() => migration.up(db))();
  assert.deepEqual(tables(db), []);
  assert.deepEqual(db.prepare('SELECT id, role FROM users ORDER BY id').all(),
    [{ id: 'u1', role: 'admin' }, { id: 'u2', role: 'user' }]);
});

test('an only account that is not an admin becomes one, and the grant is audited', () => {
  const db = new Database(':memory:');
  legacySchema(db, [['only', 'user']]);
  db.transaction(() => migration.up(db))();
  assert.equal(db.prepare('SELECT role FROM users').get().role, 'admin');
  const entry = db.prepare('SELECT * FROM audit_log').get();
  assert.equal(entry.action, 'admin_granted');
  assert.equal(entry.affected_user_id, 'only');
  assert.deepEqual(JSON.parse(entry.metadata_json), { source: 'migration' });
});

test('several accounts without an admin are left for the operator to decide', () => {
  const db = new Database(':memory:');
  legacySchema(db, [['u1', 'user'], ['u2', 'user']]);
  db.transaction(() => migration.up(db))();
  assert.equal(db.prepare("SELECT COUNT(*) c FROM users WHERE role='admin'").get().c, 0);
  assert.equal(db.prepare('SELECT COUNT(*) c FROM audit_log').get().c, 0);
});
