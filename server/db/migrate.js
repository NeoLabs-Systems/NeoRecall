'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('./database');
const { createLogger } = require('../utils/logger');

const logger = createLogger('migrations');

function verifyForeignKeys(database, filename) {
  const violations = database.pragma('foreign_key_check');
  if (violations.length) {
    throw new Error(`Migration ${filename} left ${violations.length} dangling foreign key reference(s).`);
  }
}

function withForeignKeysDisabled(database, run) {
  const wasEnabled = database.pragma('foreign_keys', { simple: true }) === 1;
  if (wasEnabled) database.pragma('foreign_keys = OFF');
  try {
    return run();
  } finally {
    if (wasEnabled) database.pragma('foreign_keys = ON');
  }
}

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
    const apply = database.transaction(() => {
      // The already-applied check belongs inside the writer lock. HTTP and the
      // worker both migrate on boot; without it they can both pass the outer
      // read, both apply, and the second hits a missing column mid-rebuild.
      if (database.prepare('SELECT 1 FROM schema_migrations WHERE version = ?').get(version)) return false;
      migration.up(database);
      // Verified inside the transaction: a rebuild that orphaned a reference
      // must roll back, not commit and then report.
      if (migration.rebuildsReferencedTable) verifyForeignKeys(database, filename);
      database.prepare('INSERT INTO schema_migrations (version, name) VALUES (?, ?)').run(version, filename);
      return true;
    });
    const applied = migration.rebuildsReferencedTable
      // SQLite cannot widen a CHECK constraint in place, so such a migration has
      // to recreate the table. Dropping a table that other tables reference runs
      // an implicit delete first, which would fire their ON DELETE actions and
      // silently null the live foreign keys. Enforcement therefore has to be off
      // across the rebuild, and the pragma is a no-op inside a transaction —
      // hence outside it. The rebuild itself stays atomic either way.
      ? withForeignKeysDisabled(database, () => apply.immediate())
      : apply.immediate();
    if (applied) logger.info('Applied migration', { version, filename });
  }
}

module.exports = { migrate };
