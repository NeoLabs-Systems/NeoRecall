'use strict';

// Admin is the `role` on the account row. authenticateToken re-reads it on every
// request, so granting or revoking it takes effect immediately. The first account
// on an install becomes admin when it registers; every later change goes through
// grantAdmin() / revokeAdmin(), driven by the operator (the `neorecall admin`
// CLI or the NEORECALL_ADMIN_USERS list), never from inside the app.

const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const audit = require('../audit/audit_service');

const ADMIN_USERS_ENV_KEY = 'NEORECALL_ADMIN_USERS';

function isAdminUser(userId) {
  return getDatabase().prepare('SELECT role FROM users WHERE id = ?').get(userId)?.role === 'admin';
}

function listAdmins() {
  return getDatabase().prepare("SELECT id, username FROM users WHERE role = 'admin' ORDER BY created_at").all();
}

function findAccount(username) {
  const name = String(username || '').trim();
  const user = getDatabase().prepare('SELECT id, username, role FROM users WHERE username = ? COLLATE NOCASE').get(name);
  if (!user) throw new HttpError(404, 'NOT_FOUND', `No account named "${name}".`);
  return user;
}

function setRole(username, role, { source }) {
  const user = findAccount(username);
  if (user.role === role) return { username: user.username, changed: false };
  const db = getDatabase();
  db.transaction(() => {
    db.prepare('UPDATE users SET role = ? WHERE id = ?').run(role, user.id);
    audit.record({
      actorType: 'system',
      affectedUserId: user.id,
      action: role === 'admin' ? 'admin_granted' : 'admin_revoked',
      metadata: { source },
    });
  })();
  return { username: user.username, changed: true };
}

function grantAdmin(username, { source }) {
  return setRole(username, 'admin', { source });
}

function revokeAdmin(username, { source }) {
  return setRole(username, 'user', { source });
}

function envAdminUsernames(env = process.env) {
  return String(env[ADMIN_USERS_ENV_KEY] || '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
}

// Usernames compare the way SQLite's NOCASE does: ASCII letters only. Folding
// with toLowerCase() would treat "JÖRG" and "Jörg" as one name here while the
// grant treats them as two, and a listed name could then be registered by
// someone else and granted admin on the next start.
function sameUsername(left, right) {
  const fold = (value) => String(value).replace(/[A-Z]/g, (letter) => letter.toLowerCase());
  return fold(left) === fold(right);
}

// A name in NEORECALL_ADMIN_USERS with no account behind it would hand admin to
// whoever registers it before the next start, so nobody may take it.
function isReservedAdminUsername(username, env = process.env) {
  const name = String(username || '').trim();
  const db = getDatabase();
  return envAdminUsernames(env).some((listed) => sameUsername(listed, name)
    && !db.prepare('SELECT 1 FROM users WHERE username = ? COLLATE NOCASE').get(listed));
}

function wasRevokedByOperator(userId) {
  const last = getDatabase().prepare(`SELECT action FROM audit_log
    WHERE affected_user_id = ? AND action IN ('admin_granted', 'admin_revoked')
    ORDER BY id DESC LIMIT 1`).get(userId);
  return last?.action === 'admin_revoked';
}

/**
 * Grants admin to every username listed in NEORECALL_ADMIN_USERS. Additive only:
 * removing a name from the list does not revoke it (use `neorecall admin revoke`),
 * and an account the operator revoked stays revoked until granted with the CLI.
 */
function applyEnvAdminGrants(env = process.env) {
  const granted = [];
  const missing = [];
  const revoked = [];
  const db = getDatabase();
  for (const name of envAdminUsernames(env)) {
    const user = db.prepare('SELECT id, role FROM users WHERE username = ? COLLATE NOCASE').get(name);
    if (!user) {
      missing.push(name);
    } else if (user.role !== 'admin' && wasRevokedByOperator(user.id)) {
      revoked.push(name);
    } else if (grantAdmin(name, { source: 'env' }).changed) {
      granted.push(name);
    }
  }
  return { granted, missing, revoked };
}

// True when accounts exist but none of them can open the Admin page -- an
// install whose admin was revoked or deleted. Startup and the CLI surface a hint.
function needsAdminGrant() {
  const row = getDatabase().prepare(`SELECT COUNT(*) accounts,
    COALESCE(SUM(role = 'admin'), 0) admins FROM users`).get();
  return row.accounts > 0 && row.admins === 0;
}

module.exports = {
  ADMIN_USERS_ENV_KEY,
  isAdminUser,
  listAdmins,
  grantAdmin,
  revokeAdmin,
  applyEnvAdminGrants,
  isReservedAdminUsername,
  needsAdminGrant,
};
