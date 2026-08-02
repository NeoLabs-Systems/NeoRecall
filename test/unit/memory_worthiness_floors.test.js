'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { applyMemoryWorthinessFloors } = require('../../server/services/memories/consolidation_service');

function segment(id, text, startedAt, endedAt) {
  return { id, text, started_at: startedAt, ended_at: endedAt };
}

test('short sections are demoted so they cannot become memory cards', () => {
  const conversations = [{
    id: 'c1',
    segments: [
      segment('s1', 'Hi — can you send the file?', '2026-07-14T08:00:00.000Z', '2026-07-14T08:00:20.000Z'),
      segment('s2', 'Sure, sending now.', '2026-07-14T08:00:20.000Z', '2026-07-14T08:00:35.000Z'),
    ],
  }];
  const output = {
    conversationSections: [{
      titleEn: 'File request',
      summaryEn: 'A brief request to send a file.',
      memoryWorthy: true,
      topics: ['Files'],
      sourceSegmentIds: ['s1', 's2'],
    }],
    memories: [{
      type: 'conversation',
      titleEn: 'File request',
      summaryEn: 'A brief request to send a file.',
      emoji: '💬',
      importance: 3,
      sourceSegmentIds: ['s1', 's2'],
      topics: ['Files'],
      entities: [],
      miniMemories: [{
        kind: 'task',
        textEn: 'Send the file.',
        importance: 4,
        confidence: 0.9,
        sourceSegmentIds: ['s1'],
        entities: [],
      }],
    }],
    dailySummary: { localDate: '2026-07-14', timezone: 'UTC', summaryEn: 'A file was requested.' },
  };

  applyMemoryWorthinessFloors(output, conversations, {
    minMemoryEvidenceMs: 120_000,
    minMemoryEvidenceChars: 400,
  });

  assert.equal(output.conversationSections[0].memoryWorthy, false);
  assert.equal(output.memories.length, 0);
  assert.equal(output.dailySummary, null);
});

test('substantial sections remain memory-worthy and keep their memories', () => {
  const longText = 'x'.repeat(500);
  const conversations = [{
    id: 'c1',
    segments: [
      segment('s1', longText, '2026-07-14T08:00:00.000Z', '2026-07-14T08:03:00.000Z'),
    ],
  }];
  const output = {
    conversationSections: [{
      titleEn: 'Planning session',
      summaryEn: 'A full planning discussion.',
      memoryWorthy: true,
      topics: ['Planning'],
      sourceSegmentIds: ['s1'],
    }],
    memories: [{
      type: 'meeting',
      titleEn: 'Planning session',
      summaryEn: 'A full planning discussion.',
      emoji: '📋',
      importance: 7,
      sourceSegmentIds: ['s1'],
      topics: ['Planning'],
      entities: [],
      miniMemories: [],
    }],
    dailySummary: { localDate: '2026-07-14', timezone: 'UTC', summaryEn: 'Planning happened.' },
  };

  applyMemoryWorthinessFloors(output, conversations, {
    minMemoryEvidenceMs: 120_000,
    minMemoryEvidenceChars: 400,
  });

  assert.equal(output.conversationSections[0].memoryWorthy, true);
  assert.equal(output.memories.length, 1);
  assert.ok(output.dailySummary);
});
