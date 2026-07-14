'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { detectBoundaries } = require('../../server/services/conversations/boundary_service');

test('hard time gaps split conversations without keyword rules', () => {
  const groups = detectBoundaries([
    { id: 1, startedAt: '2026-07-13T10:00:00Z', endedAt: '2026-07-13T10:01:00Z', embedding: new Float32Array([1, 0]), speakerId: 'a' },
    { id: 2, startedAt: '2026-07-13T10:01:01Z', endedAt: '2026-07-13T10:02:00Z', embedding: new Float32Array([1, 0]), speakerId: 'b' },
    { id: 3, startedAt: '2026-07-13T10:10:00Z', endedAt: '2026-07-13T10:11:00Z', embedding: new Float32Array([0, 1]), speakerId: 'a' },
  ], { hardGapMs: 180000, minimumDurationMs: 30000, valleyQuantile: 0.25 });
  assert.equal(groups.length, 2);
  assert.deepEqual(groups.map((group) => group.segmentIds), [[1, 2], [3]]);
});
