'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { detectBoundaries } = require('../../server/services/conversations/boundary_service');

const options = {
  hardGapMs: 180000,
  softGapMs: 60000,
  minimumDurationMs: 30000,
  valleyQuantile: 0.25,
  semanticSimilarityThreshold: 0.58,
  semanticValleyProminence: 0.1,
  semanticContextSegments: 1,
  maximumDurationMs: 4 * 60 * 60_000,
  maximumCharacters: 40_000,
};

test('hard time gaps split conversations without keyword rules', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: new Float32Array([1, 0]), speakerId: 'a' },
    { id: 2, startedAt: '2026-07-13T10:01:01Z', endedAt: '2026-07-13T10:02:00Z', embedding: new Float32Array([1, 0]), speakerId: 'b' },
    { id: 3, startedAt: '2026-07-13T10:10:00Z', endedAt: '2026-07-13T10:11:00Z', embedding: new Float32Array([0, 1]), speakerId: 'a' },
  ], options);
  assert.equal(groups.length, 2);
  assert.deepEqual(groups.map((group) => group.segmentIds), [[1, 2], [3]]);
});

test('a strong contextual embedding valley splits a topic without requiring a speaker change', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: new Float32Array([1, 0]), speakerId: 'a' },
    { id: 2, startedAt: '2026-07-13T10:01:01Z', endedAt: '2026-07-13T10:02:00Z', embedding: new Float32Array([1, 0]), speakerId: 'a' },
    { id: 3, startedAt: '2026-07-13T10:02:01Z', endedAt: '2026-07-13T10:03:00Z', embedding: new Float32Array([0, 1]), speakerId: 'a' },
    { id: 4, startedAt: '2026-07-13T10:03:01Z', endedAt: '2026-07-13T10:04:00Z', embedding: new Float32Array([0, 1]), speakerId: 'a' },
  ], options);
  assert.deepEqual(groups.map((group) => group.segmentIds), [[1, 2], [3, 4]]);
});

test('missing embeddings do not manufacture semantic boundaries', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: null, speakerId: 'a' },
    { id: 2, startedAt: '2026-07-13T10:01:01Z', endedAt: '2026-07-13T10:02:00Z', embedding: null, speakerId: 'b' },
  ], options);
  assert.equal(groups.length, 1);
});

test('safety ceilings stay intact when a neighboring group is short', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: null, characterCount: 25 },
    { id: 2, startedAt: '2026-07-13T10:01:01Z', endedAt: '2026-07-13T10:02:00Z', embedding: null, characterCount: 25 },
    { id: 3, startedAt: '2026-07-13T10:02:01Z', endedAt: '2026-07-13T10:02:10Z', embedding: null, characterCount: 10 },
  ], { ...options, maximumCharacters: 40 });
  assert.deepEqual(groups.map((group) => group.segmentIds), [[1], [2, 3]]);
});

// The rules the recording flow actually runs with, rather than the ones this
// file's older cases pin. Read from configuration so a threshold change has to
// be made once, in the place that validates it.
const shipping = (() => {
  const config = require('../../server/config').getConfig();
  return {
    hardGapMs: config.conversationHardGapMs,
    softGapMs: config.conversationSoftGapMs,
    minimumDurationMs: config.conversationMinimumMs,
    valleyQuantile: config.conversationValleyQuantile,
    semanticSimilarityThreshold: config.conversationSemanticSimilarityThreshold,
    semanticValleyProminence: config.conversationSemanticValleyProminence,
    semanticContextSegments: config.conversationSemanticContextSegments,
    maximumDurationMs: config.conversationMaximumMs,
    maximumCharacters: config.conversationMaximumCharacters,
  };
})();

// One subject, spoken about with ordinary breaks in it. Every pause is shorter
// than the gap that separates two sittings, so none of them may cut anything.
function oneSubject(pauseSeconds) {
  const blocks = [];
  let clock = Date.parse('2026-07-13T10:00:00Z');
  for (let index = 0; index < 12; index += 1) {
    blocks.push({
      id: index + 1,
      startedAt: new Date(clock).toISOString(),
      endedAt: new Date(clock + 60_000).toISOString(),
      embedding: Float32Array.from([1, 0.2, 0.05 * (index % 3)]),
      characterCount: 300,
    });
    clock += 60_000 + pauseSeconds[index % pauseSeconds.length] * 1000;
  }
  return blocks;
}

test('pauses inside one sitting never split it, however long the recording runs', () => {
  const groups = detectBoundaries(oneSubject([4, 90, 4, 240, 4, 200]), shipping);
  assert.equal(groups.length, 1, 'A pause is not a topic change.');
});

test('a pause past the hard gap separates two sittings even without embeddings', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:06:00Z', embedding: null, characterCount: 900 },
    { id: 2, startedAt: '2026-07-13T10:20:00Z', endedAt: '2026-07-13T10:26:00Z', embedding: null, characterCount: 900 },
  ], shipping);
  assert.equal(groups.length, 2);
});

test('a sitting is never absorbed across the gap that separated it', () => {
  // Both sittings are shorter than the minimum duration, so the merge pass is
  // what decides here. Folding them together would put two recordings hours
  // apart into one conversation.
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: null, characterCount: 200 },
    { id: 2, startedAt: '2026-07-13T13:00:00Z', endedAt: '2026-07-13T13:01:00Z', embedding: null, characterCount: 200 },
  ], shipping);
  assert.deepEqual(groups.map((group) => group.segmentIds), [[1], [2]]);
});

test('a long pause alone does not split when the subject carries across it', () => {
  const blocks = oneSubject([4]);
  // One pause well past the soft gap, in the middle of one subject.
  const shifted = blocks.map((block, index) => (index < 6 ? block : {
    ...block,
    startedAt: new Date(Date.parse(block.startedAt) + 420_000).toISOString(),
    endedAt: new Date(Date.parse(block.endedAt) + 420_000).toISOString(),
  }));
  assert.equal(detectBoundaries(shifted, shipping).length, 1);
});

test('a missing embedding is not evidence of a change, whatever the pause', () => {
  const blocks = oneSubject([4]).map((block) => ({ ...block, embedding: null }));
  const shifted = blocks.map((block, index) => (index < 6 ? block : {
    ...block,
    startedAt: new Date(Date.parse(block.startedAt) + 420_000).toISOString(),
    endedAt: new Date(Date.parse(block.endedAt) + 420_000).toISOString(),
  }));
  assert.equal(detectBoundaries(shifted, shipping).length, 1,
    'Detection must not depend on whether the embedding job has caught up.');
});

test('grouping does not change when embeddings arrive later', () => {
  const withEmbeddings = oneSubject([4, 90, 4, 240]);
  const withoutEmbeddings = withEmbeddings.map((block) => ({ ...block, embedding: null }));
  assert.deepEqual(
    detectBoundaries(withoutEmbeddings, shipping).map((group) => group.segmentIds),
    detectBoundaries(withEmbeddings, shipping).map((group) => group.segmentIds),
  );
});

test('a subject that persists splits; a passing aside does not', () => {
  const other = Float32Array.from([0, 1, 0]);
  const blocks = oneSubject([4]);
  const aside = blocks.map((block, index) => (index === 6 ? { ...block, embedding: other } : block));
  assert.equal(detectBoundaries(aside, shipping).length, 1, 'One utterance about something else is not a new conversation.');

  const moved = blocks.map((block, index) => (index >= 6 ? { ...block, embedding: other } : block));
  assert.equal(detectBoundaries(moved, shipping).length, 2, 'A subject that holds is.');
});
