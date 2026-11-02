'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { planWindows } = require('../../server/transcription/local_asr/windowing');
const { wordsToSegments } = require('../../server/transcription/local_asr/word_segments');

const RATE = 16_000;
const tone = (seconds) => Float32Array.from({ length: Math.round(seconds * RATE) }, (_, index) => 0.5 * Math.sin(index / 7));

test('a chunk inside the limit is one window', () => {
  const windows = planWindows(tone(20), { windowMs: 28_000, searchMs: 4_000 });
  assert.deepEqual(windows, [{ startSample: 0, endSample: 20 * RATE }]);
});

test('windows tile the chunk exactly and none exceeds the limit', () => {
  const samples = tone(95);
  const windows = planWindows(samples, { windowMs: 28_000, searchMs: 4_000 });
  assert.equal(windows[0].startSample, 0);
  assert.equal(windows.at(-1).endSample, samples.length);
  for (let index = 1; index < windows.length; index += 1) assert.equal(windows[index].startSample, windows[index - 1].endSample);
  for (const window of windows) assert.ok(window.endSample - window.startSample <= 28 * RATE);
  assert.ok(windows.length >= 4);
});

test('a cut lands in the pause rather than through speech', () => {
  const samples = tone(60);
  // A pause between 25.0 s and 25.4 s, inside the search span before 28 s.
  samples.fill(0, 25 * RATE, Math.round(25.4 * RATE));
  const [first] = planWindows(samples, { windowMs: 28_000, searchMs: 4_000 });
  assert.ok(first.endSample >= 25 * RATE && first.endSample <= 25.4 * RATE, `cut at ${first.endSample / RATE}s`);
});

test('with no pause at all the cut falls on the limit', () => {
  const [first] = planWindows(tone(40), { windowMs: 28_000, searchMs: 0 });
  assert.equal(first.endSample, 28 * RATE);
});

const words = (...items) => items.map(([word, start, end, probability = 0.9]) => ({ word, start, end, probability }));
const grouping = { gapMs: 800, maxMs: 15_000 };

test('words end a segment at a sentence mark, at a silence, and at the ceiling', () => {
  const segments = wordsToSegments(words(['Hello', 0, 0.4], ['there.', 0.4, 0.9], ['Next', 1.0, 1.3], ['one', 1.3, 1.6], ['later', 3.0, 3.4]), grouping);
  assert.deepEqual(segments.map((segment) => segment.text), ['Hello there.', 'Next one', 'later']);
  const long = wordsToSegments(Array.from({ length: 40 }, (_, index) => ({ word: 'w', start: index, end: index + 0.9, probability: 1 })), grouping);
  assert.ok(long.length >= 3 && long.every((segment) => segment.endMs - segment.startMs <= 16_000));
});

test('sentence marks of other scripts and a closing quote also end a segment', () => {
  const segments = wordsToSegments(words(['Wirklich?', 0, 0.5], ['Ja!"', 0.5, 0.9], ['Fertig。', 1.0, 1.4], ['Rest', 1.4, 1.8]), grouping);
  assert.deepEqual(segments.map((segment) => segment.text), ['Wirklich?', 'Ja!"', 'Fertig。', 'Rest']);
});

test('times are placed on the chunk timeline and confidence is the mean word probability', () => {
  const [segment] = wordsToSegments(words(['a', 0.5, 1.0, 0.8], ['b.', 1.0, 1.5, 0.6]), { ...grouping, offsetMs: 28_000, language: 'de' });
  assert.equal(segment.startMs, 28_500);
  assert.equal(segment.endMs, 29_500);
  assert.equal(segment.language, 'de');
  assert.ok(Math.abs(segment.asrConfidence - 0.7) < 1e-9);
});

test('blank and malformed words are ignored', () => {
  assert.deepEqual(wordsToSegments([{ word: ' ', start: 0, end: 1 }, null, { start: 1, end: 2 }], grouping), []);
});
