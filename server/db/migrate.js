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
  // Applied migrations are keyed by version, so two files sharing a number make
  // the second one unreachable: the first is recorded as that version and the
  // second is skipped forever, silently, on every install. Refuse to start
  // instead of running a partial schema.
  const seen = new Map();
  for (const filename of files) {
    const version = Number(filename.slice(0, 3));
    if (seen.has(version)) {
      throw new Error(
        `Duplicate migration version ${version}: ${seen.get(version)} and ${filename}. `
        + 'Renumber one of them; a shared version silently skips the second.',
      );
    }
    seen.set(version, filename);
  }
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
