'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { importIdFor, normalizeTime } = require('../../server/services/sources/cloud/cloud_import_base');

test('importIdFor is stable and UUID-shaped', () => {
  const a = importIdFor('zoom', 'u1', 's1', 'rec-9');
  const b = importIdFor('zoom', 'u1', 's1', 'rec-9');
  const c = importIdFor('zoom', 'u1', 's1', 'rec-10');
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('normalizeTime accepts ISO and epoch values', () => {
  assert.equal(normalizeTime('2026-07-31T09:00:00Z'), '2026-07-31T09:00:00.000Z');
  assert.equal(normalizeTime(1_722_416_400_000), new Date(1_722_416_400_000).toISOString());
  assert.equal(normalizeTime(1_722_416_400), new Date(1_722_416_400 * 1000).toISOString());
  assert.equal(normalizeTime(null), undefined);
  assert.equal(normalizeTime('not-a-date'), undefined);
});
