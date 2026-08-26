'use strict';

const crypto = require('crypto');
const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { paths } = require('../../../runtime/paths');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('sources');

// Registry of source types.
//
// Every type is a module exposing `startSource(source)` / `stopSource(id)`.
// Adding a source means adding one entry here — the lifecycle below (restore on
// boot, create, update, delete) is type-agnostic, so no new branch is needed in
// four different places. Loaded lazily so one connector's dependencies cannot
// break the whole service at require time.
const SOURCE_TYPES = {
  discord: () => require('./discord_source'),
  plaud: () => require('./plaud_source'),
};

// Config keys that hold credentials and must never be echoed back to a client.
const SECRET_CONFIG_KEYS = new Set(['token', 'accessToken', 'refreshToken', 'password', 'apiKey']);

// Removed connectors cannot start and should not remain visible in clients.
const RETIRED_SOURCE_TYPES = Object.freeze(['google_meet', 'zoom', 'microsoft_teams', 'meeting']);

function driverFor(type) {
  const load = SOURCE_TYPES[type];
  if (!load) return null;
  try {
    return load();
  } catch (error) {
    logger.error('Source type could not be loaded', { type, error });
    return null;
  }
}

// Starts or stops a source according to its enabled flag, never throwing: one
// misbehaving connector must not take down the request or the boot sequence.
function applyLifecycle(source) {
  const driver = driverFor(source.type);
  if (!driver) return;
  const onError = (error) =>
    logger.error('Source transition failed', { action: source.enabled ? 'start' : 'stop', sourceId: source.id, type: source.type, error });
  try {
    const result = source.enabled ? driver.startSource(source) : driver.stopSource(source.id);
    Promise.resolve(result).catch(onError);
  } catch (error) {
    onError(error);
  }
}

function hydrate(row) {
  return { ...row, config: JSON.parse(row.config_json), enabled: row.enabled === 1 };
}

// Strips credentials from a source before it leaves the API. The owner already
// supplied them; echoing them back only widens where they can leak.
function redact(source) {
  const config = {};
  for (const [key, value] of Object.entries(source.config)) {
    config[key] = SECRET_CONFIG_KEYS.has(key) ? '••••••••' : value;
  }
  const { config_json: _configJson, ...rest } = source;
  return { ...rest, config, configuredSecrets: Object.keys(source.config).filter((key) => SECRET_CONFIG_KEYS.has(key)) };
}

const sourcesService = {
  // Source types this build can run, for the client to offer.
  availableTypes() {
    return Object.keys(SOURCE_TYPES);
  },

  // Validates a type's credentials before the source is stored. Types whose
  // driver exposes no `verifyAccess` are accepted as-is.
  async verifyConfig(type, config) {
    const driver = driverFor(type);
    if (!driver) throw new Error(`Unknown source type: ${type}`);
    if (typeof driver.verifyAccess !== 'function') return {};
    const details = await driver.verifyAccess(config);
    return details && typeof details === 'object' ? { account: details } : {};
  },

  init() {
    try {
      const db = getDatabase();
      try {
        const placeholders = RETIRED_SOURCE_TYPES.map(() => '?').join(',');
        const removed = db.prepare(`DELETE FROM sources WHERE type IN (${placeholders})`).run(...RETIRED_SOURCE_TYPES);
        if (removed.changes > 0) {
          logger.info('Removed retired sources', { removed: removed.changes });
        }
      } catch (cleanupError) {
        logger.error('Failed to clean up retired sources', { error: cleanupError });
      }

      try {
        const meetingProfiles = path.join(paths().home, 'meeting_profiles');
        if (fs.existsSync(meetingProfiles)) {
          fs.rmSync(meetingProfiles, { recursive: true, force: true });
          logger.info('Removed retired meeting account profiles');
        }
      } catch (cleanupError) {
        logger.error('Failed to clean up retired meeting account profiles', { error: cleanupError });
      }

      for (const row of db.prepare('SELECT * FROM sources WHERE enabled = 1').all()) {
        let source;
        try {
          source = hydrate(row);
        } catch (parseError) {
          logger.error('Skipping source with invalid config', { sourceId: row.id, error: parseError });
          continue;
        }
        applyLifecycle(source);
      }
    } catch (error) {
      logger.error('Failed to initialize sources', { error });
    }
  },

  list(userId) {
    const db = getDatabase();
    const rows = db.prepare('SELECT * FROM sources WHERE user_id = ? ORDER BY created_at DESC').all(userId);
    return rows.map((row) => redact(hydrate(row)));
  },

  // Full record including secrets — for server-side use only, never a response.
  get(userId, id) {
    const db = getDatabase();
    const row = db.prepare('SELECT * FROM sources WHERE user_id = ? AND id = ?').get(userId, id);
    if (!row) throw new Error('Source not found');
    return hydrate(row);
  },

  // Safe projection for API responses.
  getPublic(userId, id) {
    return redact(this.get(userId, id));
  },

  create(userId, data) {
    const db = getDatabase();
    if (!SOURCE_TYPES[data.type]) {
      throw new Error(`Unknown source type: ${data.type}`);
    }

    const existingCount = db.prepare('SELECT COUNT(*) as count FROM sources WHERE user_id = ? AND type = ?').get(userId, data.type);
    if (existingCount.count > 0) {
      throw new Error(`A source of type ${data.type} is already configured. You can only have one per platform.`);
    }

    const id = crypto.randomUUID();
    db.prepare(`
      INSERT INTO sources (id, user_id, type, name, config_json, enabled)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(id, userId, data.type, data.name, JSON.stringify(data.config || {}), data.enabled ? 1 : 0);

    const created = this.get(userId, id);
    applyLifecycle(created);
    return redact(created);
  },

  update(userId, id, data) {
    const db = getDatabase();
    const existing = this.get(userId, id);

    // A config update replaces the stored object, so merge it onto the existing
    // one: the client never receives secrets back and would otherwise blank them
    // out by round-tripping a redacted config.
    const config = data.config ? { ...existing.config, ...data.config } : existing.config;
    // Never persist redacted placeholders as real secrets.
    for (const key of SECRET_CONFIG_KEYS) {
      if (config[key] === '••••••••') config[key] = existing.config[key];
    }
    const name = data.name ?? existing.name;
    const enabled = data.enabled !== undefined ? (data.enabled ? 1 : 0) : (existing.enabled ? 1 : 0);

    db.prepare(`
      UPDATE sources
      SET name = ?, config_json = ?, enabled = ?, updated_at = ?
      WHERE user_id = ? AND id = ?
    `).run(name, JSON.stringify(config), enabled, new Date().toISOString(), userId, id);

    const updated = this.get(userId, id);
    applyLifecycle(updated);
    return redact(updated);
  },

  delete(userId, id) {
    const db = getDatabase();
    const existing = this.get(userId, id);
    const driver = driverFor(existing.type);
    if (driver) {
      try {
        Promise.resolve(driver.stopSource(id)).catch(() => { /* teardown is best-effort */ });
      } catch (_) { /* teardown is best-effort */ }
    }
    db.prepare('DELETE FROM sources WHERE user_id = ? AND id = ?').run(userId, id);
  },

  async syncNow(userId, id) {
    const source = this.get(userId, id);
    const driver = driverFor(source.type);
    if (!driver || typeof driver.syncNow !== 'function') {
      throw new Error('This source does not support manual sync.');
    }
    const result = await driver.syncNow(source);
    return { ok: true, ...result };
  },
};

module.exports = sourcesService;
