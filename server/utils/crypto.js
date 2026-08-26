'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const stream = require('node:stream/promises');
const bcrypt = require('bcrypt');
const { ensureRuntimeDirs } = require('../../runtime/paths');

function randomToken(bytes = 32) { return crypto.randomBytes(bytes).toString('base64url'); }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
// Digests a file without holding it in memory.
//
// A day of recording decodes to thousands of chunks, and reading each one whole
// only to hash it makes peak memory a function of the longest recording rather
// than of the block size.
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


// Sealed blob layout: version(1) | iv(12) | tag(16) | ciphertext.
//
// The version byte lets a later key rotation add a format without a migration,
// and `unsealBuffer` tolerates unsealed input so a half-applied migration or a
// restore from an older backup still reads. Detection is by trial decryption
// rather than by the marker byte alone: a raw float vector can start with 0x01,
// but it cannot forge a GCM tag.
const SEAL_VERSION = 1;
const SEAL_HEADER = 29; // version + iv + tag

function sealBuffer(plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', masterKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([Buffer.from([SEAL_VERSION]), iv, cipher.getAuthTag(), ciphertext]);
}

function unsealBuffer(payload) {
  if (!payload) return payload;
  const bytes = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  if (bytes.length < SEAL_HEADER || bytes[0] !== SEAL_VERSION) return bytes;
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', masterKey(), bytes.subarray(1, 13));
    decipher.setAuthTag(bytes.subarray(13, SEAL_HEADER));
    return Buffer.concat([decipher.update(bytes.subarray(SEAL_HEADER)), decipher.final()]);
  } catch (_) {
    // Not sealed after all: the marker byte collided with real payload data.
    return bytes;
  }
}

function isSealed(payload) {
  if (!payload || payload.length < SEAL_HEADER || payload[0] !== SEAL_VERSION) return false;
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', masterKey(), payload.subarray(1, 13));
    decipher.setAuthTag(payload.subarray(13, SEAL_HEADER));
    Buffer.concat([decipher.update(payload.subarray(SEAL_HEADER)), decipher.final()]);
    return true;
  } catch (_) { return false; }
}

// Streaming file encryption for backup artifacts.
//
// A database that has been recording for months does not fit in memory twice,
// and a backup is the one artifact most likely to be copied somewhere with
// weaker access control than the runtime directory, so it never leaves here in
// the clear. Layout: magic(4) | iv(12) | ciphertext... | tag(16), with the tag
// trailing because GCM only produces it after the final block.
const BACKUP_MAGIC = Buffer.from('NRB1', 'ascii');

async function encryptFileStream(source, destination) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', masterKey(), iv);
  const output = fs.createWriteStream(destination, { mode: 0o600 });
  await new Promise((resolve, reject) => {
    output.on('error', reject);
    output.write(Buffer.concat([BACKUP_MAGIC, iv]), (error) => (error ? reject(error) : resolve()));
  });
  await stream.pipeline(fs.createReadStream(source), cipher, output, { end: false });
  await new Promise((resolve, reject) => output.end(cipher.getAuthTag(), (error) => (error ? reject(error) : resolve())));
}

async function decryptFileStream(source, destination) {
  const { size } = await fs.promises.stat(source);
  if (size < BACKUP_MAGIC.length + 12 + 16) throw new Error('Backup file is truncated.');
  const handle = await fs.promises.open(source, 'r');
  try {
    const header = Buffer.alloc(BACKUP_MAGIC.length + 12);
    await handle.read(header, 0, header.length, 0);
    if (!header.subarray(0, BACKUP_MAGIC.length).equals(BACKUP_MAGIC)) throw new Error('Backup file has an unrecognized format.');
    const tag = Buffer.alloc(16);
    await handle.read(tag, 0, 16, size - 16);
    const decipher = crypto.createDecipheriv('aes-256-gcm', masterKey(), header.subarray(BACKUP_MAGIC.length));
    decipher.setAuthTag(tag);
    await stream.pipeline(
      fs.createReadStream(source, { start: header.length, end: size - 17 }),
      decipher,
      fs.createWriteStream(destination, { mode: 0o600 }),
    );
  } finally {
    await handle.close();
  }
}

module.exports = {
  randomToken, sha256, sha256File, timingSafeStringEqual, hashPassword, verifyPassword, encryptString, decryptString,
  sealBuffer, unsealBuffer, isSealed, encryptFileStream, decryptFileStream,
};
