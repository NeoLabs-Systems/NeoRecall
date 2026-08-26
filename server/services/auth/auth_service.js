'use strict';

const crypto = require('node:crypto');
const { authenticator } = require('otplib');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { randomToken, sha256, hashPassword, verifyPassword, encryptString, decryptString } = require('../../utils/crypto');
const audit = require('../audit/audit_service');

function publicUser(user) {
  return user && { id: user.id, username: user.username, email: user.email, role: user.role, createdAt: user.created_at };
}

function contextFields(context) { return [context.ipAddress || null, context.userAgent || null]; }

function createSession(userId, context = {}) {
  const token = `nrs_${randomToken(32)}`;
  const id = crypto.randomUUID();
  const expiresAt = new Date(Date.now() + getConfig().sessionTtlMs).toISOString();
  getDatabase().prepare(`INSERT INTO user_sessions
    (id, user_id, token_hash, expires_at, ip_address, user_agent) VALUES (?, ?, ?, ?, ?, ?)`)
    .run(id, userId, sha256(token), expiresAt, ...contextFields(context));
  return { token, expiresAt };
}

async function register({ username, email, password }, context = {}) {
  if (!getConfig().registrationEnabled) throw new HttpError(403, 'REGISTRATION_DISABLED', 'Registration is disabled.');
  const normalizedUsername = String(username || '').trim();
  const normalizedEmail = email ? String(email).trim().toLowerCase() : null;
  if (normalizedUsername.length < 3 || normalizedUsername.length > 64) throw new HttpError(400, 'INVALID_USERNAME', 'Username must contain 3 to 64 characters.');
  if (String(password || '').length < 12) throw new HttpError(400, 'WEAK_PASSWORD', 'Password must contain at least 12 characters.');
  const db = getDatabase();
  if (db.prepare('SELECT 1 FROM users WHERE username = ? COLLATE NOCASE').get(normalizedUsername)) throw new HttpError(409, 'USERNAME_TAKEN', 'This username is already in use.');
  if (normalizedEmail && db.prepare('SELECT 1 FROM users WHERE email = ? COLLATE NOCASE').get(normalizedEmail)) throw new HttpError(409, 'EMAIL_TAKEN', 'This email is already in use.');
  const passwordHash = await hashPassword(password);
  const id = crypto.randomUUID();
  db.transaction(() => {
    const role = db.prepare('SELECT 1 FROM users LIMIT 1').get() ? 'user' : 'admin';
    db.prepare('INSERT INTO users (id, username, email, password_hash, role) VALUES (?, ?, ?, ?, ?)')
      .run(id, normalizedUsername, normalizedEmail, passwordHash, role);
    audit.record({ actorType: 'user', actorId: id, affectedUserId: id, action: 'user_registered', ipAddress: context.ipAddress });
  })();
  return { user: publicUser(db.prepare('SELECT * FROM users WHERE id = ?').get(id)), session: createSession(id, context) };
}

function normalizeTwoFactorCode(value) {
  // Users (and authenticator UIs) often insert spaces or dashes; recovery codes
  // may be pasted with separators. Strip them before verifying.
  return String(value || '').replace(/[\s-]+/g, '').trim();
}

function recoveryCodeHash(code) {
  return sha256(normalizeTwoFactorCode(code).toUpperCase());
}

function consumeRecoveryCode(userId, code) {
  if (!code) return false;
  const normalized = recoveryCodeHash(code);
  // Legacy rows were hashed with the display form ("XXXXX-XXXXX"); accept both.
  const legacy = sha256(String(code).toUpperCase());
  const row = getDatabase().prepare(`SELECT id FROM user_recovery_codes
    WHERE user_id = ? AND used_at IS NULL AND (code_hash = ? OR code_hash = ?)`).get(userId, normalized, legacy);
  if (!row) return false;
  getDatabase().prepare("UPDATE user_recovery_codes SET used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(row.id);
  return true;
}

function verifySecondFactor(userId, value) {
  const db = getDatabase();
  const factor = db.prepare('SELECT * FROM user_two_factor WHERE user_id = ? AND pending = 0').get(userId);
  if (!factor) return true;
  const code = normalizeTwoFactorCode(value);
  if (!code) throw new HttpError(401, 'TWO_FACTOR_REQUIRED', 'A two-factor authentication code is required.');
  if (factor.locked_until && Date.parse(factor.locked_until) > Date.now()) throw new HttpError(429, 'TWO_FACTOR_LOCKED', 'Two-factor authentication is temporarily locked.');
  const valid = authenticator.check(code, decryptString(factor.secret_encrypted)) || consumeRecoveryCode(userId, code);
  if (valid) {
    db.prepare('UPDATE user_two_factor SET failed_attempts = 0, locked_until = NULL WHERE user_id = ?').run(userId);
    return true;
  }
  const attempts = factor.failed_attempts + 1;
  const lockedUntil = attempts >= 5 ? new Date(Date.now() + 5 * 60_000).toISOString() : null;
  db.prepare('UPDATE user_two_factor SET failed_attempts = ?, locked_until = ? WHERE user_id = ?').run(attempts, lockedUntil, userId);
  throw new HttpError(401, 'INVALID_TWO_FACTOR', 'The two-factor authentication code is invalid.');
}

async function authenticateCredentials({ account, password, twoFactorCode }, context = {}) {
  const db = getDatabase();
  const user = db.prepare('SELECT * FROM users WHERE username = ? COLLATE NOCASE OR email = ? COLLATE NOCASE').get(String(account || '').trim(), String(account || '').trim());
  const valid = user ? await verifyPassword(String(password || ''), user.password_hash) : false;
  if (!valid) {
    audit.record({ actorType: 'system', action: 'login_failed', ipAddress: context.ipAddress });
    throw new HttpError(401, 'INVALID_CREDENTIALS', 'Username or password is incorrect.');
  }
  if (user.disabled_at) throw new HttpError(403, 'ACCOUNT_DISABLED', 'This account is disabled.');
  verifySecondFactor(user.id, twoFactorCode);
  db.prepare("UPDATE users SET last_login_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(user.id);
  audit.record({ actorType: 'user', actorId: user.id, affectedUserId: user.id, action: 'login_succeeded', ipAddress: context.ipAddress });
  return publicUser(user);
}

async function login(input, context = {}) {
  const user = await authenticateCredentials(input, context);
  return { user, session: createSession(user.id, context) };
}

function authenticateToken(token) {
  if (!token) return null;
  const db = getDatabase();
  const row = db.prepare(`SELECT s.id session_id, s.user_id, s.expires_at, u.username, u.email, u.role, u.disabled_at, u.created_at
    FROM user_sessions s JOIN users u ON u.id = s.user_id
    WHERE s.token_hash = ? AND s.revoked_at IS NULL AND s.expires_at > ?`).get(sha256(token), new Date().toISOString());
  if (!row || row.disabled_at) return null;
  db.prepare("UPDATE user_sessions SET last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(row.session_id);
  return { type: 'session', sessionId: row.session_id, userId: row.user_id, scopes: ['*'], user: publicUser({ id: row.user_id, ...row }) };
}

function logout(sessionId) {
  getDatabase().prepare("UPDATE user_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(sessionId);
}

function logoutAll(userId) {
  getDatabase().prepare("UPDATE user_sessions SET revoked_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id = ? AND revoked_at IS NULL").run(userId);
}

async function changePassword(userId, currentPassword, newPassword) {
  const db = getDatabase();
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  if (!user || !(await verifyPassword(currentPassword, user.password_hash))) throw new HttpError(401, 'INVALID_PASSWORD', 'The current password is incorrect.');
  if (String(newPassword || '').length < 12) throw new HttpError(400, 'WEAK_PASSWORD', 'Password must contain at least 12 characters.');
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(await hashPassword(newPassword), userId);
  logoutAll(userId);
}

function getTwoFactorStatus(userId) {
  const row = getDatabase().prepare('SELECT * FROM user_two_factor WHERE user_id = ?').get(userId);
  const codesLeft = getDatabase().prepare('SELECT COUNT(*) AS n FROM user_recovery_codes WHERE user_id = ? AND used_at IS NULL').get(userId).n;
  return {
    enabled: row?.pending === 0,
    pending: row?.pending === 1,
    enabledAt: row?.enabled_at || null,
    recoveryCodesRemaining: codesLeft,
  };
}

function beginTwoFactor(userId, username) {
  const secret = authenticator.generateSecret();
  getDatabase().prepare(`INSERT INTO user_two_factor (user_id, secret_encrypted, pending)
    VALUES (?, ?, 1) ON CONFLICT(user_id) DO UPDATE SET secret_encrypted=excluded.secret_encrypted, pending=1, failed_attempts=0, locked_until=NULL,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`).run(userId, encryptString(secret));
  return { secret, otpauthUri: authenticator.keyuri(username, 'NeoRecall', secret) };
}

function activateTwoFactor(userId, code) {
  const db = getDatabase();
  const factor = db.prepare('SELECT * FROM user_two_factor WHERE user_id = ? AND pending = 1').get(userId);
  if (!factor || !authenticator.check(normalizeTwoFactorCode(code), decryptString(factor.secret_encrypted))) throw new HttpError(400, 'INVALID_TWO_FACTOR', 'The two-factor authentication code is invalid.');
  const codes = Array.from({ length: 10 }, () => randomToken(8).slice(0, 10).toUpperCase());
  db.transaction(() => {
    db.prepare("UPDATE user_two_factor SET pending=0, enabled_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE user_id=?").run(userId);
    db.prepare('DELETE FROM user_recovery_codes WHERE user_id = ?').run(userId);
    const insert = db.prepare('INSERT INTO user_recovery_codes (id, user_id, code_hash) VALUES (?, ?, ?)');
    for (const recoveryCode of codes) insert.run(crypto.randomUUID(), userId, recoveryCodeHash(recoveryCode));
  })();
  return codes;
}

async function disableTwoFactor(userId, password, code) {
  const user = getDatabase().prepare('SELECT * FROM users WHERE id = ?').get(userId);
  if (!user || !(await verifyPassword(password, user.password_hash))) throw new HttpError(401, 'INVALID_PASSWORD', 'The password is incorrect.');
  verifySecondFactor(userId, code);
  getDatabase().transaction(() => {
    getDatabase().prepare('DELETE FROM user_two_factor WHERE user_id = ?').run(userId);
    getDatabase().prepare('DELETE FROM user_recovery_codes WHERE user_id = ?').run(userId);
  })();
}

async function regenerateRecoveryCodes(userId, password, code) {
  const user = getDatabase().prepare('SELECT * FROM users WHERE id = ?').get(userId);
  if (!user || !(await verifyPassword(password, user.password_hash))) throw new HttpError(401, 'INVALID_PASSWORD', 'The password is incorrect.');
  verifySecondFactor(userId, code);
  const codes = Array.from({ length: 10 }, () => {
    let raw = randomToken(8).slice(0, 10).toUpperCase();
    return `${raw.slice(0, 5)}-${raw.slice(5)}`;
  });
  getDatabase().transaction(() => {
    getDatabase().prepare('DELETE FROM user_recovery_codes WHERE user_id = ?').run(userId);
    const insert = getDatabase().prepare('INSERT INTO user_recovery_codes (id, user_id, code_hash) VALUES (?, ?, ?)');
    for (const recoveryCode of codes) insert.run(crypto.randomUUID(), userId, recoveryCodeHash(recoveryCode));
  })();
  return codes;
}

async function deleteAccount(userId, password, code) {
  const db = getDatabase();
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  if (!user || !(await verifyPassword(password, user.password_hash))) throw new HttpError(401, 'INVALID_PASSWORD', 'The password is incorrect.');
  verifySecondFactor(userId, code);
  const paths = [
    ...db.prepare('SELECT temporary_path FROM audio_chunks WHERE user_id=? AND temporary_path IS NOT NULL').all(userId),
    ...db.prepare('SELECT temporary_path FROM imports WHERE user_id=? AND temporary_path IS NOT NULL').all(userId),
    ...db.prepare('SELECT p.temporary_path FROM import_parts p JOIN imports i ON i.id=p.import_id WHERE i.user_id=?').all(userId),
    ...db.prepare('SELECT original_path temporary_path FROM recording_context_items WHERE user_id=? AND original_path IS NOT NULL').all(userId),
  ];
  for (const row of paths) require('../ingest/temp_audio_service').unlinkStrict(row.temporary_path);
  db.transaction(() => {
    require('../../embeddings/search_index_service').removeForUser(db, userId);
    db.prepare('DELETE FROM users WHERE id = ?').run(userId);
  })();
}

module.exports = {
  publicUser, register, login, createSession, authenticateCredentials, authenticateToken, logout, logoutAll, changePassword,
  beginTwoFactor, activateTwoFactor, disableTwoFactor, deleteAccount, verifySecondFactor, getTwoFactorStatus, regenerateRecoveryCodes,
};
