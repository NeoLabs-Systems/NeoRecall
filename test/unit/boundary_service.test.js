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
