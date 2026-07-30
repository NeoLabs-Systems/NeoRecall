'use strict';

const crypto = require('crypto');
const { getDatabase } = require('../../db/database');

const sourcesService = {
  init() {
    try {
      const db = getDatabase();
      const stmt = db.prepare('SELECT * FROM sources WHERE enabled = 1 AND type = ?');
      const rows = stmt.all('discord');
      for (const row of rows) {
        const source = {
          ...row,
          config: JSON.parse(row.config_json),
          enabled: row.enabled === 1,
        };
        require('./discord_source').startSource(source);
      }
    } catch (error) {
      console.error('[Sources] Failed to initialize sources:', error.message);
    }
  },

  list(userId) {
    const db = getDatabase();
    const stmt = db.prepare('SELECT * FROM sources WHERE user_id = ? ORDER BY created_at DESC');
    const rows = stmt.all(userId);
    return rows.map(row => ({
      ...row,
      config: JSON.parse(row.config_json),
      enabled: row.enabled === 1,
    }));
  },

  get(userId, id) {
    const db = getDatabase();
    const stmt = db.prepare('SELECT * FROM sources WHERE user_id = ? AND id = ?');
    const row = stmt.get(userId, id);
    if (!row) throw new Error('Source not found');
    return {
      ...row,
      config: JSON.parse(row.config_json),
      enabled: row.enabled === 1,
    };
  },

  create(userId, data) {
    const db = getDatabase();
    
    // Enforce one source per platform per user
    const existingCount = db.prepare('SELECT COUNT(*) as count FROM sources WHERE user_id = ? AND type = ?').get(userId, data.type);
    if (existingCount.count > 0) {
      throw new Error(`A source of type ${data.type} is already configured. You can only have one per platform.`);
    }

    const id = crypto.randomUUID();
    const configJson = JSON.stringify(data.config || {});
    const enabled = data.enabled ? 1 : 0;
    
    const stmt = db.prepare(`
      INSERT INTO sources (id, user_id, type, name, config_json, enabled)
      VALUES (?, ?, ?, ?, ?, ?)
    `);
    stmt.run(id, userId, data.type, data.name, configJson, enabled);
    
    const newSource = this.get(userId, id);
    if (newSource.type === 'discord' && newSource.enabled) {
      require('./discord_source').startSource(newSource);
    }
    
    return newSource;
  },

  update(userId, id, data) {
    const db = getDatabase();
    const existing = this.get(userId, id);
    
    const name = data.name ?? existing.name;
    const configJson = data.config ? JSON.stringify(data.config) : existing.config_json;
    const enabled = data.enabled !== undefined ? (data.enabled ? 1 : 0) : (existing.enabled ? 1 : 0);
    const updatedAt = new Date().toISOString();

    const stmt = db.prepare(`
      UPDATE sources
      SET name = ?, config_json = ?, enabled = ?, updated_at = ?
      WHERE user_id = ? AND id = ?
    `);
    stmt.run(name, configJson, enabled, updatedAt, userId, id);
    
    const updatedSource = this.get(userId, id);
    if (updatedSource.type === 'discord') {
      if (updatedSource.enabled) {
        require('./discord_source').startSource(updatedSource);
      } else {
        require('./discord_source').stopSource(updatedSource.id);
      }
    }
    
    return updatedSource;
  },

  delete(userId, id) {
    const db = getDatabase();
    const existing = this.get(userId, id);
    if (existing.type === 'discord') {
      require('./discord_source').stopSource(id);
    }
    const stmt = db.prepare('DELETE FROM sources WHERE user_id = ? AND id = ?');
    stmt.run(userId, id);
  }
};

module.exports = sourcesService;
