'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { similarity, dedupe } = require('../../server/transcription/token_deduper');

test('token overlap similarity is multilingual and not phrase-list based', () => {
  assert.ok(similarity('Wir besprechen morgen das Projekt.', 'Wir besprechen morgen das Projekt') > 0.9);
  assert.ok(similarity('A completely different sentence', 'Eine andere Aussage') < 0.5);
});

test('dedupe removes only time-aligned duplicate leakage', () => {
  const result = dedupe([
    { text: 'The meeting starts at ten.', startMs: 1000, endMs: 3000, asrConfidence: 0.8 },
    { text: 'A later independent statement.', startMs: 9000, endMs: 11000, asrConfidence: 0.8 },
  ], [{ text: 'The meeting starts at ten', startMs: 1100, endMs: 3050, asrConfidence: 0.9 }], { similarityThreshold: 0.8, timeToleranceMs: 500 });
  assert.deepEqual(result.map((item) => item.text), ['A later independent statement.']);
});
