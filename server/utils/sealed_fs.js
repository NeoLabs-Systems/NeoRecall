'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { ensureRuntimeDirs } = require('../../runtime/paths');
const {
  FILE_MAGIC, isEncryptedFileSync, encryptFileSync, decryptFileSync, decryptFileToBuffer,
} = require('./crypto');

function isSealed(filename) {
  return Boolean(filename) && isEncryptedFileSync(filename, FILE_MAGIC);
}

function sealInPlace(filename) {
  if (!filename || !fs.existsSync(filename) || isSealed(filename)) return filename;
  const temporary = `${filename}.sealing-${crypto.randomUUID()}`;
  encryptFileSync(filename, temporary, FILE_MAGIC);
  fs.renameSync(temporary, filename);
  try { fs.chmodSync(filename, 0o600); } catch (_) { /* best effort */ }
  return filename;
}

function readFileSync(filename, options) {
  if (!isSealed(filename)) return fs.readFileSync(filename, options);
  const bytes = decryptFileToBuffer(filename, FILE_MAGIC);
  if (options === 'utf8' || (options && options.encoding === 'utf8')) return bytes.toString('utf8');
  return bytes;
}

function copyPlain(filename, destination) {
  if (isSealed(filename)) decryptFileSync(filename, destination, FILE_MAGIC);
  else fs.copyFileSync(filename, destination);
  try { fs.chmodSync(destination, 0o600); } catch (_) { /* best effort */ }
  return destination;
}

function materialize(filename) {
  if (!filename) return { path: filename, cleanup() {} };
  if (!isSealed(filename)) return { path: filename, cleanup() {} };
  const extension = path.extname(filename) || '.bin';
  const plain = path.join(ensureRuntimeDirs().audioWork, `plain-${crypto.randomUUID()}${extension}`);
  copyPlain(filename, plain);
  return {
    path: plain,
    cleanup() {
      try { fs.unlinkSync(plain); } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    },
  };
}

function withPlain(filename, run) {
  const opened = materialize(filename);
  try {
    return run(opened.path);
  } finally {
    opened.cleanup();
  }
}

async function withPlainAsync(filename, run) {
  const opened = materialize(filename);
  try {
    return await run(opened.path);
  } finally {
    opened.cleanup();
  }
}

module.exports = { isSealed, sealInPlace, readFileSync, copyPlain, materialize, withPlain, withPlainAsync };
