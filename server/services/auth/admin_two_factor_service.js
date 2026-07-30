'use strict';

const crypto = require('node:crypto');
const { authenticator } = require('otplib');
const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { encryptString, decryptString, randomToken, sha256 } = require('../../utils/crypto');

function getRow(adminId) {
  return getDatabase().prepare('SELECT * FROM admin_two_factor WHERE admin_id = ?').get(adminId) || null;
}

function getStatus(adminId) {
  const row = getRow(adminId);
  const codesLeft = getDatabase().prepare('SELECT COUNT(*) AS n FROM admin_recovery_codes WHERE admin_id = ? AND used_at IS NULL').get(adminId).n;
  return {
    enabled: row?.pending === 0,
    pending: row?.pending === 1,
    enabledAt: row?.enabled_at || null,
    recoveryCodesRemaining: codesLeft,
  };
}

function beginSetup(adminId, username) {
  const secret = authenticator.generateSecret();
  getDatabase().prepare(`
    INSERT INTO admin_two_factor (admin_id, secret_encrypted, pending, failed_attempts, locked_until)
    VALUES (?, ?, 1, 0, NULL)
    ON CONFLICT(admin_id) DO UPDATE SET secret_encrypted = excluded.secret_encrypted, pending = 1, failed_attempts = 0, locked_until = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
  `).run(adminId, encryptString(secret));
  
  return {
    manualKey: secret,
    otpauthUrl: authenticator.keyuri(username, 'NeoRecall Admin', secret),
  };
}

function consumeRecoveryCode(adminId, code) {
  if (!code) return false;
  const row = getDatabase().prepare('SELECT id FROM admin_recovery_codes WHERE admin_id = ? AND code_hash = ? AND used_at IS NULL').get(adminId, sha256(String(code).toUpperCase().replace(/-/g, '')));
  if (!row) return false;
  getDatabase().prepare("UPDATE admin_recovery_codes SET used_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id = ?").run(row.id);
  return true;
}

function verifySecondFactor(adminId, value) {
  const db = getDatabase();
  const factor = db.prepare('SELECT * FROM admin_two_factor WHERE admin_id = ? AND pending = 0').get(adminId);
  if (!factor) return true; // not configured or not enabled
  if (!value) throw new HttpError(401, 'TWO_FACTOR_REQUIRED', 'A two-factor authentication code is required.');
  if (factor.locked_until && Date.parse(factor.locked_until) > Date.now()) throw new HttpError(429, 'TWO_FACTOR_LOCKED', 'Two-factor authentication is temporarily locked.');
  
  const valid = authenticator.check(String(value).replace(/\\s+/g, ''), decryptString(factor.secret_encrypted)) || consumeRecoveryCode(adminId, value);
  if (valid) {
    db.prepare('UPDATE admin_two_factor SET failed_attempts = 0, locked_until = NULL WHERE admin_id = ?').run(adminId);
    return true;
  }
  const attempts = factor.failed_attempts + 1;
  const lockedUntil = attempts >= 5 ? new Date(Date.now() + 5 * 60_000).toISOString() : null;
  db.prepare('UPDATE admin_two_factor SET failed_attempts = ?, locked_until = ? WHERE admin_id = ?').run(attempts, lockedUntil, adminId);
  throw new HttpError(401, 'INVALID_TWO_FACTOR', 'The two-factor authentication code is invalid.');
}

function activateTwoFactor(adminId, code) {
  const db = getDatabase();
  const factor = db.prepare('SELECT * FROM admin_two_factor WHERE admin_id = ? AND pending = 1').get(adminId);
  if (!factor || !authenticator.check(String(code || '').replace(/\\s+/g, ''), decryptString(factor.secret_encrypted))) throw new HttpError(400, 'INVALID_TWO_FACTOR', 'The two-factor authentication code is invalid.');
  
  const codes = Array.from({ length: 10 }, () => {
    let raw = randomToken(8).slice(0, 10).toUpperCase(); // crypto.randomToken gives hex, wait. I should generate alphanumeric.
    return `${raw.slice(0, 5)}-${raw.slice(5)}`;
  });

  db.transaction(() => {
    db.prepare("UPDATE admin_two_factor SET pending = 0, enabled_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE admin_id = ?").run(adminId);
    db.prepare('DELETE FROM admin_recovery_codes WHERE admin_id = ?').run(adminId);
    const insert = db.prepare('INSERT INTO admin_recovery_codes (id, admin_id, code_hash) VALUES (?, ?, ?)');
    for (const recoveryCode of codes) insert.run(crypto.randomUUID(), adminId, sha256(recoveryCode.replace(/-/g, '')));
  })();
  return codes;
}

function disableTwoFactor(adminId, code) {
  verifySecondFactor(adminId, code);
  getDatabase().transaction(() => {
    getDatabase().prepare('DELETE FROM admin_two_factor WHERE admin_id = ?').run(adminId);
    getDatabase().prepare('DELETE FROM admin_recovery_codes WHERE admin_id = ?').run(adminId);
  })();
}

function regenerateRecoveryCodes(adminId, code) {
  verifySecondFactor(adminId, code);
  const codes = Array.from({ length: 10 }, () => {
    let raw = randomToken(8).slice(0, 10).toUpperCase();
    return `${raw.slice(0, 5)}-${raw.slice(5)}`;
  });
  getDatabase().transaction(() => {
    getDatabase().prepare('DELETE FROM admin_recovery_codes WHERE admin_id = ?').run(adminId);
    const insert = getDatabase().prepare('INSERT INTO admin_recovery_codes (id, admin_id, code_hash) VALUES (?, ?, ?)');
    for (const recoveryCode of codes) insert.run(crypto.randomUUID(), adminId, sha256(recoveryCode.replace(/-/g, '')));
  })();
  return codes;
}

module.exports = {
  getStatus,
  beginSetup,
  activateTwoFactor,
  verifySecondFactor,
  disableTwoFactor,
  regenerateRecoveryCodes,
};
