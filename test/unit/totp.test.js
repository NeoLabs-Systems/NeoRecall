'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-totp-'));
const { encryptString, decryptString } = require('../../server/utils/crypto');
const {
  generateSecret,
  generateTotp,
  otpauthUri,
  verifyTotp,
  normalizeTotpCode,
} = require('../../server/utils/totp');

test.after(() => { fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('RFC 6238 SHA1 vectors match a phone authenticator', () => {
  // ASCII "12345678901234567890" as base32, the published SHA1 test key.
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
  assert.equal(generateTotp(secret, 59_000), '287082');
  assert.equal(generateTotp(secret, 1111111109_000), '081804');
  assert.equal(verifyTotp('287082', secret, 59_000), true);
  assert.equal(verifyTotp('081804', secret, 1111111109_000), true);
});

test('codes with spaces still verify and adjacent steps are accepted', () => {
  const secret = generateSecret();
  const now = Date.now();
  const current = generateTotp(secret, now);
  const previous = generateTotp(secret, now - 30_000);
  const next = generateTotp(secret, now + 30_000);
  const far = generateTotp(secret, now + 120_000);

  assert.equal(verifyTotp(` ${current.slice(0, 3)} ${current.slice(3)} `, secret, now), true);
  assert.equal(verifyTotp(previous, secret, now), true);
  assert.equal(verifyTotp(next, secret, now), true);
  assert.equal(verifyTotp(far, secret, now), false);
  assert.equal(verifyTotp('000000', secret, now), false);
});

test('otpauth URIs carry the secret a scanner types by hand', () => {
  const secret = generateSecret();
  const uri = otpauthUri('ada', 'NeoRecall', secret);
  assert.match(uri, new RegExp(`secret=${secret}`));
  assert.doesNotMatch(uri, /algorithm=/i);
  assert.equal(normalizeTotpCode('12 34-56'), '123456');
});

test('an encrypted secret still verifies after decrypt', () => {
  const secret = generateSecret();
  const restored = decryptString(encryptString(secret));
  assert.equal(restored, secret);
  const code = generateTotp(restored);
  assert.equal(verifyTotp(code, restored), true);
});
