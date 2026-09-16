'use strict';

const { Database, openKeyedDatabase } = require('./sqlite');
const sqliteVec = require('sqlite-vec');
const expectedVecVersion = require('../../package.json').dependencies['sqlite-vec'];
const { ensureRuntimeDirs } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { createLogger } = require('../utils/logger');

const logger = createLogger('database');
let connection;
let vectorReady = false;

function waitForUnlock(deadline) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.min(50, Math.max(1, deadline - Date.now())));
}

function openDatabase(filename) {
  const deadline = Date.now() + 10_000;
  for (;;) {
    let database;
    try {
      database = openKeyedDatabase(filename, { timeout: 10_000 });
      try {
        database.pragma('busy_timeout = 10000');
        database.pragma('journal_mode = WAL');
      } catch (error) {
        if (database.open) database.close();
        if (error && /not a database|file is not a database|SQLITE_NOTADB|malformed/i.test(String(error.message))) {
          throw new Error(
            'NeoRecall could not unlock the database. The file is encrypted with the '
            + 'installation secret.key; restore that key or restore a backup.',
          );
        }
        throw error;
      }
      database.pragma('foreign_keys = ON');
      database.pragma('synchronous = FULL');
      database.pragma('trusted_schema = OFF');
      try {
        sqliteVec.load(database);
        const actualVersion = database.prepare('SELECT vec_version() AS version').get().version;
        if (String(actualVersion).replace(/^v/, '') !== String(expectedVecVersion).replace(/^v/, '')) {
          throw new Error(`sqlite-vec ${actualVersion} loaded, but lockfile expects ${expectedVecVersion}.`);
        }
        vectorReady = true;
      } catch (error) {
        if (getConfig().requireVector) {
          database.close();
          throw error;
        }
        logger.warn('sqlite-vec is unavailable; semantic search is disabled', { error: error.message });
      }
      return database;
    } catch (error) {
      if (database && database.open) database.close();
      if (error && error.code === 'SQLITE_BUSY') {
        if (Date.now() < deadline) {
          waitForUnlock(deadline);
          continue;
        }
        throw new Error(
          `Another process is still using the NeoRecall database at ${filename}. `
          + 'Stop the running NeoRecall (neorecall stop) and try again.',
        );
      }
      throw error;
    }
  }
}

// Verifying that the vector extension loads needs *a* database, not *the*
// database. Opening the runtime file contends with a running NeoRecall (and
// fails the whole update when that install is mid-write), so probe against an
// in-memory database, which exercises the same extension load path.
function probeVectorExtension() {
  const database = new Database(':memory:');
  try {
    sqliteVec.load(database);
    const version = String(database.prepare('SELECT vec_version() AS version').get().version);
    if (version.replace(/^v/, '') !== String(expectedVecVersion).replace(/^v/, '')) {
      throw new Error(`sqlite-vec ${version} loaded, but lockfile expects ${expectedVecVersion}.`);
    }
    return version;
  } finally {
    database.close();
  }
}

function getDatabase() {
  if (!connection || !connection.open) connection = openDatabase(ensureRuntimeDirs().database);
  return connection;
}

function closeDatabase() {
  if (connection && connection.open) connection.close();
  connection = undefined;
  vectorReady = false;
}

function isVectorReady() { return vectorReady; }

module.exports = { getDatabase, closeDatabase, openDatabase, probeVectorExtension, isVectorReady, expectedVecVersion };
