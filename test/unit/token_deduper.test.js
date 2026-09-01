'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  similarity, exactSameUtterance, dedupeExactCrossStream, dedupe,
} = require('../../server/transcription/token_deduper');

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

test('a reported Whisper logprob beats a duplicate that omitted confidence', () => {
  const result = dedupe([
    { text: 'The meeting starts at ten.', startMs: 1000, endMs: 3000, asrConfidence: null },
    { text: 'The meeting starts at ten.', startMs: 1050, endMs: 3050, asrConfidence: -0.4 },
  ], [], { similarityThreshold: 0.8, timeToleranceMs: 500 });
  assert.deepEqual(result.map((item) => item.asrConfidence), [-0.4]);
});

test('cross-stream dedupe requires the same complete multi-word utterance and matching time', () => {
  assert.equal(exactSameUtterance('Danke schön!', 'DANKE schön', 2), true);
  assert.equal(exactSameUtterance('Thanks', 'thanks', 2), false);
  assert.equal(exactSameUtterance('ship the release', 'ship the release today', 2), false);

  const candidates = [
    { text: 'Ship the release.', startMs: 1000, endMs: 2500 },
  ];
  const result = dedupeExactCrossStream([
    { text: 'SHIP the release', startMs: 1100, endMs: 2450 },
    { text: 'Ship the release today', startMs: 1100, endMs: 2450 },
    { text: 'Ship the release.', startMs: 5000, endMs: 6500 },
    { text: 'Thanks', startMs: 1100, endMs: 2450 },
  ], candidates, { timeToleranceMs: 500, minimumWords: 2 });

  assert.deepEqual(result.map((item) => item.text), [
    'Ship the release today',
    'Ship the release.',
    'Thanks',
  ]);
});
