'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');

function serialize(row) {
  if (!row) return null;
  return { ...row, capabilities: JSON.parse(row.capabilities_json || '{}'), capabilities_json: undefined };
}

function register(userId, input) {
  const db = getDatabase();
  const existing = db.prepare('SELECT * FROM devices WHERE user_id=? AND client_uuid=?').get(userId, input.clientUuid);
  if (existing) {
    if (existing.revoked_at) throw new HttpError(403, 'DEVICE_REVOKED', 'This device has been revoked.');
    db.prepare(`UPDATE devices SET name=?,platform=?,kind=?,capabilities_json=? WHERE id=?`)
      .run(input.name, input.platform, input.kind, JSON.stringify(input.capabilities || {}), existing.id);
    return serialize(db.prepare('SELECT * FROM devices WHERE id=?').get(existing.id));
  }
  const id = input.id || crypto.randomUUID();
  db.prepare(`INSERT INTO devices (id,user_id,client_uuid,name,platform,kind,capabilities_json)
    VALUES (?,?,?,?,?,?,?)`).run(id, userId, input.clientUuid, input.name, input.platform, input.kind, JSON.stringify(input.capabilities || {}));
  return serialize(db.prepare('SELECT * FROM devices WHERE id=?').get(id));
}

function list(userId) {
  return getDatabase().prepare('SELECT * FROM devices WHERE user_id=? ORDER BY created_at DESC').all(userId).map(serialize);
}

function get(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM devices WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Device not found.');
  return serialize(row);
}

function rename(userId, id, name) {
  const result = getDatabase().prepare('UPDATE devices SET name=? WHERE id=? AND user_id=? AND revoked_at IS NULL').run(name, id, userId);
  if (!result.changes) throw new HttpError(404, 'NOT_FOUND', 'Device not found.');
  return get(userId, id);
}

function revoke(userId, id) {
  const result = getDatabase().prepare("UPDATE devices SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=? AND revoked_at IS NULL").run(id, userId);
  if (!result.changes) throw new HttpError(404, 'NOT_FOUND', 'Device not found.');
}

function heartbeat(userId, id, input) {
  const serverReceivedAt = new Date().toISOString();
  get(userId, id);
  const offset = Number.isFinite(input.clockOffsetMs) ? input.clockOffsetMs : null;
  const rtt = Number.isFinite(input.clockRttMs) ? input.clockRttMs : null;
  getDatabase().prepare(`UPDATE devices SET last_heartbeat_at=?,clock_offset_ms=COALESCE(?,clock_offset_ms),
    clock_rtt_ms=COALESCE(?,clock_rtt_ms) WHERE id=? AND user_id=?`).run(serverReceivedAt, offset, rtt, id, userId);
  return { serverReceivedAt, serverSentAt: new Date().toISOString() };
}

module.exports = { register, list, get, rename, revoke, heartbeat };
