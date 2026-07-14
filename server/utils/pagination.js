'use strict';

function encodeCursor(value) { return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url'); }
function decodeCursor(cursor) {
  if (!cursor) return null;
  try { return JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8')); } catch (_) { return null; }
}
function pageLimit(raw, maximum = 100, fallback = 50) {
  const value = Number(raw || fallback);
  return Number.isInteger(value) ? Math.min(maximum, Math.max(1, value)) : fallback;
}

module.exports = { encodeCursor, decodeCursor, pageLimit };
