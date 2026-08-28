'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { compactSegment, compactSegments } = require('../../server/transcription/transcript_quality');

const options = {
  minimumRepeats: 8,
  maximumPatternWords: 8,
  minimumCoverage: 0.8,
  maximumWordsPerSecond: 5,
};

test('compacts a dominant impossible-rate repeated token template without knowing its words', () => {
  const text = Array.from({ length: 60 }, () => 'Arbitrary 51,').join(' ');
  const result = compactSegment({ text, startMs: 0, endMs: 18_000, language: 'en' }, options);

  assert.equal(result.changed, true);
  assert.equal(result.segment.text, 'Arbitrary 51,');
  assert.equal(result.removedWords, 118);
  assert.equal(result.segment.language, 'en');
});

test('recognizes a structurally repeated template even when its numeric value changes', () => {
  const text = Array.from({ length: 40 }, (_, index) => `Kennung ${index + 10},`).join(' ');
  const result = compactSegment({ text, startMs: 0, endMs: 10_000 }, options);

  assert.equal(result.changed, true);
  assert.equal(result.segment.text, 'Kennung 10,');
});

test('keeps normal emphasis, countdowns, and repetitions at a credible speaking rate', () => {
  for (const segment of [
    { text: 'Das ist wirklich wirklich wichtig.', startMs: 0, endMs: 2_000 },
    { text: '20 Sekunden, 5, 4, 3, 2, 1.', startMs: 0, endMs: 5_000 },
    { text: Array.from({ length: 10 }, () => 'la').join(' '), startMs: 0, endMs: 10_000 },
  ]) {
    assert.equal(compactSegment(segment, options).changed, false);
  }
});

test('requires a repeated run to dominate the segment', () => {
  const repeated = Array.from({ length: 8 }, () => 'alpha beta').join(' ');
  const surrounding = Array.from({ length: 20 }, (_, index) => `unique${index}`).join(' ');
  const segment = { text: `${repeated} ${surrounding}`, startMs: 0, endMs: 5_000 };
  assert.equal(compactSegment(segment, options).changed, false);
});

test('compacts multiple segments and reports aggregate suppression without dropping evidence', () => {
  const settings = {
    transcriptRepetitionMinimumRepeats: 8,
    transcriptRepetitionMaximumPatternWords: 8,
    transcriptRepetitionMinimumCoverage: 0.8,
    transcriptMaximumWordsPerSecond: 5,
  };
  const pathological = { text: Array.from({ length: 30 }, () => 'x y').join(' '), startMs: 0, endMs: 5_000 };
  const normal = { text: 'Ein normaler Satz.', startMs: 5_000, endMs: 8_000 };
  const result = compactSegments([pathological, normal], settings);

  assert.equal(result.changedSegments, 1);
  assert.equal(result.removedWords, 58);
  assert.equal(result.segments.length, 2);
  assert.equal(result.segments[0].text, 'x y');
  assert.equal(result.segments[1], normal);
});
