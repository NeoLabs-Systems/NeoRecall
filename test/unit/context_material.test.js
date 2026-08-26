'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const material = require('../../server/services/context/context_material_service');

test('recording context follows the closest transcript moment', () => {
  const conversation = {
    segments: [
      { id: 'early', started_at: '2026-08-26T08:00:00.000Z', ended_at: '2026-08-26T08:00:10.000Z' },
      { id: 'late', started_at: '2026-08-26T08:00:50.000Z', ended_at: '2026-08-26T08:01:00.000Z' },
    ],
  };
  assert.equal(material.nearestSegmentId({ captured_at: '2026-08-26T08:00:08.000Z' }, conversation), 'early');
  assert.equal(material.nearestSegmentId({ captured_at: '2026-08-26T08:00:48.000Z' }, conversation), 'late');
});
