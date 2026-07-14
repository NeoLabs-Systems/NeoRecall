'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { exponentialRecency, score } = require('../../server/services/search/retrieval_scorer');

test('recency decays to one half at the configured half-life', () => {
  const now = new Date('2026-07-31T00:00:00Z');
  assert.ok(Math.abs(exponentialRecency('2026-07-01T00:00:00Z', now, 30) - 0.5) < 1e-10);
});

test('memory retrieval combines normalized relevance, recency, and importance', () => {
  const value = score({ relevance: 1, occurredAt: '2026-07-31T00:00:00Z', importance: 10 }, {
    searchHalfLifeDays: 30, searchWeights: { relevance: 0.5, recency: 0.25, importance: 0.25 },
  }, new Date('2026-07-31T00:00:00Z'));
  assert.equal(value, 1);
});
