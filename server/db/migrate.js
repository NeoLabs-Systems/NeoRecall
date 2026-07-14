'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('./database');
const { createLogger } = require('../utils/logger');

const logger = createLogger('migrations');

function migrate(database = getDatabase()) {
  database.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`);
  const migrationsPath = path.join(__dirname, 'migrations');
  const files = fs.readdirSync(migrationsPath).filter((name) => /^\d{3}_.+\.js$/.test(name)).sort();
  for (const filename of files) {
    const version = Number(filename.slice(0, 3));
    if (database.prepare('SELECT 1 FROM schema_migrations WHERE version = ?').get(version)) continue;
    const migration = require(path.join(migrationsPath, filename));
    database.transaction(() => {
      migration.up(database);
      database.prepare('INSERT INTO schema_migrations (version, name) VALUES (?, ?)').run(version, filename);
    })();
    logger.info('Applied migration', { version, filename });
  }
}

module.exports = { migrate };
