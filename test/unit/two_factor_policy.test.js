'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { generateRecoveryCode, generateRecoveryCodes, lockAfterInvalidAttempt } = require('../../server/services/auth/two_factor_policy');

test('recovery codes are dashed alphanumeric groups without URL-alphabet punctuation', () => {
  const codes = generateRecoveryCodes(10);
  assert.equal(codes.length, 10);
  assert.equal(new Set(codes).size, 10);
  for (const code of codes) {
    assert.match(code, /^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}$/);
    assert.doesNotMatch(code, /[_]/);
  }
  assert.match(generateRecoveryCode(), /^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}$/);
});

test('the fifth invalid 2FA attempt locks for the configured window', () => {
  const unlocked = lockAfterInvalidAttempt(3);
  assert.equal(unlocked.attempts, 4);
  assert.equal(unlocked.lockedUntil, null);
  const locked = lockAfterInvalidAttempt(4);
  assert.equal(locked.attempts, 5);
  assert.ok(Date.parse(locked.lockedUntil) > Date.now());
});
