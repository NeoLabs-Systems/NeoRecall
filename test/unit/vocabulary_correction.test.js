'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { correctText } = require('../../server/transcription/vocabulary_correction');

const options = { minimumLength: 8, maximumDistance: 2, similarityThreshold: 0.84, ambiguityMargin: 0.08 };

test('conservatively corrects a close misspelling of a long vocabulary word', () => {
  assert.equal(correctText('We deployed NeoRecal yesterday.', ['NeoRecall'], options), 'We deployed NeoRecall yesterday.');
});

test('does not alter short, distant, multi-word, or differently-prefixed words', () => {
  assert.equal(correctText('Recall the product and the new recallable feature.', ['NeoRecall', 'Ada Lovelace'], options),
    'Recall the product and the new recallable feature.');
});

test('refuses an ambiguous correction', () => {
  assert.equal(correctText('Use transcriptiom.', ['transcription', 'transcriptome'], options), 'Use transcriptiom.');
});

test('supports Unicode words without disturbing surrounding punctuation', () => {
  assert.equal(correctText('Das ist Übertragunh, genau.', ['Übertragung'], options), 'Das ist Übertragung, genau.');
});
