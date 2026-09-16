'use strict';

const crypto = require('node:crypto');
const { getConfig } = require('../../config');

// 32 symbols so each random byte maps without bias. Ambiguous 0/O/1/I are omitted.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function generateRecoveryCode() {
  const bytes = crypto.randomBytes(10);
  let raw = '';
  for (let i = 0; i < 10; i += 1) raw += ALPHABET[bytes[i] & 31];
  return `${raw.slice(0, 5)}-${raw.slice(5)}`;
}

function generateRecoveryCodes(count = getConfig().twoFactorRecoveryCodeCount) {
  const n = Math.max(1, Number(count) || getConfig().twoFactorRecoveryCodeCount);
  return Array.from({ length: n }, generateRecoveryCode);
}

function lockAfterInvalidAttempt(failedAttempts) {
  const { twoFactorLockAfterFailures, twoFactorLockMs } = getConfig();
  const attempts = failedAttempts + 1;
  return {
    attempts,
    lockedUntil: attempts >= twoFactorLockAfterFailures
      ? new Date(Date.now() + twoFactorLockMs).toISOString()
      : null,
  };
}

module.exports = { generateRecoveryCode, generateRecoveryCodes, lockAfterInvalidAttempt };
