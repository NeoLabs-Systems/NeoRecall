'use strict';

const crypto = require('node:crypto');

// RFC 4648 base32, no padding. Authenticator apps decode the otpauth secret
// this way; otplib's own generate/check pair can agree while a phone still
// rejects the same code if the two sides ever diverge.
const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function normalizeTotpCode(value) {
  return String(value || '').replace(/[\s-]+/g, '').trim();
}

function normalizeSecret(secret) {
  return String(secret || '').toUpperCase().replace(/[\s-]+/g, '').replace(/=+$/g, '');
}

function base32Encode(bytes) {
  let bits = '';
  for (const byte of bytes) bits += byte.toString(2).padStart(8, '0');
  let encoded = '';
  for (let i = 0; i + 5 <= bits.length; i += 5) {
    encoded += BASE32_ALPHABET[parseInt(bits.slice(i, i + 5), 2)];
  }
  if (bits.length % 5) {
    encoded += BASE32_ALPHABET[parseInt(bits.slice(-(bits.length % 5)).padEnd(5, '0'), 2)];
  }
  return encoded;
}

function base32Decode(secret) {
  const cleaned = normalizeSecret(secret);
  let bits = '';
  for (const ch of cleaned) {
    const value = BASE32_ALPHABET.indexOf(ch);
    if (value < 0) return null;
    bits += value.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}

function hotp(secretBytes, counter, digits = 6) {
  const msg = Buffer.alloc(8);
  msg.writeUInt32BE(Math.floor(counter / 0x100000000), 0);
  msg.writeUInt32BE(counter >>> 0, 4);
  const hmac = crypto.createHmac('sha1', secretBytes).update(msg).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const bin = ((hmac[offset] & 0x7f) << 24)
    | ((hmac[offset + 1] & 0xff) << 16)
    | ((hmac[offset + 2] & 0xff) << 8)
    | (hmac[offset + 3] & 0xff);
  return String(bin % (10 ** digits)).padStart(digits, '0');
}

function totpAt(secretBytes, epochMs, step = 30) {
  return hotp(secretBytes, Math.floor(epochMs / 1000 / step));
}

function generateTotp(secret, epochMs = Date.now()) {
  const secretBytes = base32Decode(secret);
  if (!secretBytes || secretBytes.length === 0) return null;
  return totpAt(secretBytes, epochMs);
}

// Adjacent 30-second steps cover a phone whose clock is a few seconds off,
// and a code typed just as the period rolls over. Window 0 rejects both.
const TOTP_WINDOW = 1;

function verifyTotp(code, secret, epochMs = Date.now()) {
  const normalized = normalizeTotpCode(code);
  if (!/^\d{6}$/.test(normalized)) return false;
  const secretBytes = base32Decode(secret);
  if (!secretBytes || secretBytes.length === 0) return false;
  const expected = Buffer.from(normalized);
  for (let offset = -TOTP_WINDOW; offset <= TOTP_WINDOW; offset += 1) {
    const candidate = totpAt(secretBytes, epochMs + offset * 30_000);
    if (crypto.timingSafeEqual(expected, Buffer.from(candidate))) return true;
  }
  return false;
}

function generateSecret(bytes = 20) {
  return base32Encode(crypto.randomBytes(bytes));
}

function otpauthUri(account, issuer, secret) {
  const label = `${encodeURIComponent(issuer)}:${encodeURIComponent(account)}`;
  // SHA1 / 6 digits / 30s are the defaults every authenticator already uses.
  // Putting algorithm=SHA1 in the URI makes some apps ignore the secret.
  const query = new URLSearchParams({
    secret: normalizeSecret(secret),
    issuer,
    period: '30',
    digits: '6',
  });
  return `otpauth://totp/${label}?${query.toString()}`;
}

module.exports = {
  TOTP_WINDOW,
  normalizeTotpCode,
  normalizeSecret,
  verifyTotp,
  generateTotp,
  generateSecret,
  otpauthUri,
};
