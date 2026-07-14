'use strict';

const Database = require('better-sqlite3');
const sqliteVec = require('sqlite-vec');
const expectedVecVersion = require('../../package.json').dependencies['sqlite-vec'];
const { ensureRuntimeDirs } = require('../../runtime/paths');
const { getConfig } = require('../config');
const { createLogger } = require('../utils/logger');

const logger = createLogger('database');
let connection;
let vectorReady = false;

function openDatabase(filename) {
  const database = new Database(filename);
  database.pragma('journal_mode = WAL');
  database.pragma('foreign_keys = ON');
  database.pragma('busy_timeout = 10000');
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

module.exports = { getDatabase, closeDatabase, openDatabase, isVectorReady, expectedVecVersion };
