'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const bcrypt = require('bcrypt');
const { ensureRuntimeDirs } = require('../../runtime/paths');

function randomToken(bytes = 32) { return crypto.randomBytes(bytes).toString('base64url'); }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
/// Digests a file without holding it in memory.
///
/// A day of recording decodes to thousands of chunks, and reading each one whole
/// only to hash it makes peak memory a function of the longest recording rather
/// than of the block size.
function sha256File(filename, blockSize = 1024 * 1024) {
  const hash = crypto.createHash('sha256');
  const buffer = Buffer.allocUnsafe(blockSize);
  const handle = fs.openSync(filename, 'r');
  try {
    let read = fs.readSync(handle, buffer, 0, blockSize, null);
    while (read > 0) {
      hash.update(buffer.subarray(0, read));
      read = fs.readSync(handle, buffer, 0, blockSize, null);
    }
  } finally {
    fs.closeSync(handle);
  }
  return hash.digest('hex');
}
function timingSafeStringEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
async function hashPassword(password) { return bcrypt.hash(password, 12); }
async function verifyPassword(password, hash) { return bcrypt.compare(password, hash); }

function masterKey() {
  const { secretKey } = ensureRuntimeDirs();
  if (!fs.existsSync(secretKey)) {
    fs.writeFileSync(secretKey, crypto.randomBytes(32), { mode: 0o600, flag: 'wx' });
  }
  const key = fs.readFileSync(secretKey);
  if (key.length !== 32) throw new Error('NeoRecall secret.key must contain exactly 32 bytes.');
  return key;
}

function encryptString(plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', masterKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(String(plaintext), 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64url');
}

function decryptString(payload) {
  const bytes = Buffer.from(payload, 'base64url');
  if (bytes.length < 29) throw new Error('Encrypted value is malformed.');
  const decipher = crypto.createDecipheriv('aes-256-gcm', masterKey(), bytes.subarray(0, 12));
  decipher.setAuthTag(bytes.subarray(12, 28));
  return Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString('utf8');
}

module.exports = {
  randomToken, sha256, sha256File, timingSafeStringEqual, hashPassword, verifyPassword, encryptString, decryptString,
};
