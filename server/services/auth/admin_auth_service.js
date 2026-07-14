'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { hashPassword, verifyPassword, randomToken, sha256 } = require('../../utils/crypto');
const { HttpError } = require('../../middleware/error_handler');

async function bootstrap() {
  const username = process.env.ADMIN_USERNAME;
  const password = process.env.ADMIN_PASSWORD;
  if (!username && !password) return null;
  if (!username || !password || password.length < 12) throw new Error('ADMIN_USERNAME and an ADMIN_PASSWORD of at least 12 characters must be provided together.');
  const db = getDatabase();
  const passwordHash = await hashPassword(password);
  const existing = db.prepare('SELECT id FROM admins WHERE username=? COLLATE NOCASE').get(username);
  const id = existing?.id || crypto.randomUUID();
  db.prepare(`INSERT INTO admins (id,username,password_hash,environment_managed) VALUES (?,?,?,1)
    ON CONFLICT(username) DO UPDATE SET password_hash=excluded.password_hash,environment_managed=1,disabled_at=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`).run(id, username, passwordHash);
  return id;
}

async function login(username, password, context = {}) {
  const db = getDatabase();
  const admin = db.prepare('SELECT * FROM admins WHERE username=? COLLATE NOCASE').get(String(username || '').trim());
  if (!admin || admin.disabled_at || !(await verifyPassword(String(password || ''), admin.password_hash))) throw new HttpError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.');
  const token = `nra_${randomToken(32)}`;
  const expiresAt = new Date(Date.now() + Math.min(getConfig().sessionTtlMs, 12 * 60 * 60_000)).toISOString();
  db.prepare(`INSERT INTO admin_sessions (id,admin_id,token_hash,expires_at,ip_address,user_agent) VALUES (?,?,?,?,?,?)`)
    .run(crypto.randomUUID(), admin.id, sha256(token), expiresAt, context.ipAddress || null, context.userAgent || null);
  db.prepare("UPDATE admins SET last_login_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(admin.id);
  return { token, expiresAt, admin: { id: admin.id, username: admin.username } };
}

function authenticate(token) {
  const row = getDatabase().prepare(`SELECT s.id session_id,a.id,a.username FROM admin_sessions s JOIN admins a ON a.id=s.admin_id
    WHERE s.token_hash=? AND s.revoked_at IS NULL AND s.expires_at>? AND a.disabled_at IS NULL`).get(sha256(token || ''), new Date().toISOString());
  return row ? { type: 'admin_session', adminId: row.id, adminSessionId: row.session_id, username: row.username } : null;
}

function logout(sessionId) {
  getDatabase().prepare("UPDATE admin_sessions SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(sessionId);
}

module.exports = { bootstrap, login, authenticate, logout };
