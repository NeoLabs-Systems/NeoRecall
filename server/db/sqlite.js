'use strict';

const fs = require('node:fs');
const Database = require('better-sqlite3-multiple-ciphers');
const { masterKey } = require('../utils/crypto');

const SQLITE_HEADER = Buffer.from('SQLite format 3\0');

function waitBriefly(deadline) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.min(50, Math.max(1, deadline - Date.now())));
}

function isPlainSqliteFile(filename) {
  if (!filename || filename === ':memory:') return false;
  try {
    const stat = fs.statSync(filename);
    if (!stat.isFile() || stat.size < 16) return false;
    const handle = fs.openSync(filename, 'r');
    try {
      const header = Buffer.alloc(16);
      if (fs.readSync(handle, header, 0, 16, 0) !== 16) return false;
      return header.equals(SQLITE_HEADER);
    } finally {
      fs.closeSync(handle);
    }
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

function withExclusiveLock(lockPath, run) {
  const deadline = Date.now() + 120_000;
  for (;;) {
    try {
      const handle = fs.openSync(lockPath, 'wx', 0o600);
      try {
        fs.writeSync(handle, String(process.pid));
        return run();
      } finally {
        fs.closeSync(handle);
        try { fs.unlinkSync(lockPath); } catch (_) { /* released */ }
      }
    } catch (error) {
      if (error.code !== 'EEXIST' || Date.now() >= deadline) throw error;
      try {
        const pid = Number(fs.readFileSync(lockPath, 'utf8').trim());
        if (Number.isInteger(pid) && pid > 0) {
          try { process.kill(pid, 0); } catch (_) {
            try { fs.unlinkSync(lockPath); } catch (_) { /* stolen */ }
            continue;
          }
        }
      } catch (_) { /* waiter retries */ }
      waitBriefly(deadline);
    }
  }
}

// Existing installs wrote a plaintext SQLite file. The first open after this
// change encrypts that file in place with the installation key so a stolen
// database is ciphertext, including FTS tokens and vectors.
function encryptUnlocked(filename) {
  const database = new Database(filename, { timeout: 10_000 });
  try {
    database.pragma('busy_timeout = 10000');
    database.pragma('journal_mode = DELETE');
    database.rekey(masterKey());
  } finally {
    database.close();
  }
}

function openKeyedDatabase(filename, options = {}) {
  if (!filename || filename === ':memory:') {
    const database = new Database(filename, options);
    database.key(masterKey());
    return database;
  }
  return withExclusiveLock(`${filename}.open.lock`, () => {
    if (isPlainSqliteFile(filename)) encryptUnlocked(filename);
    const database = new Database(filename, options);
    try {
      database.key(masterKey());
    } catch (error) {
      if (database.open) database.close();
      throw error;
    }
    return database;
  });
}

module.exports = { Database, openKeyedDatabase, isPlainSqliteFile };
