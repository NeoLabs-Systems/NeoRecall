'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { validateConversationSections } = require('../../server/services/conversations/conversation_refinement_service');

function conversation(id, sessionId, segmentIds) {
  return {
    id,
    sessionId,
    segments: segmentIds.map((segmentId, index) => ({
      id: segmentId,
      started_at: `2026-07-13T10:0${index}:00.000Z`,
      ended_at: `2026-07-13T10:0${index}:30.000Z`,
    })),
  };
}

function section(ids) {
  return {
    titleEn: 'A specific topic',
    summaryEn: 'A grounded summary.',
    memoryWorthy: true,
    topics: ['Topic'],
    sourceSegmentIds: ids,
  };
}

test('LLM refinement can merge provisional conversations and split the resulting stream', () => {
  const conversations = [
    conversation('conversation-1', 'stream-1', ['s1', 's2']),
    {
      ...conversation('conversation-2', 'stream-1', ['s3', 's4']),
      segments: [
        { id: 's3', started_at: '2026-07-13T10:02:00.000Z', ended_at: '2026-07-13T10:02:30.000Z' },
        { id: 's4', started_at: '2026-07-13T10:03:00.000Z', ended_at: '2026-07-13T10:03:30.000Z' },
      ],
    },
  ];
  const result = validateConversationSections([
    section(['s1', 's2', 's3']),
    section(['s4']),
  ], conversations);
  assert.deepEqual(result.map((item) => item.sourceSegmentIds), [['s1', 's2', 's3'], ['s4']]);
});

test('LLM refinement rejects missing, reordered, duplicated, and cross-stream evidence', () => {
  const conversations = [
    conversation('conversation-1', 'stream-1', ['s1', 's2']),
    conversation('conversation-2', 'stream-2', ['s3']),
  ];
  assert.throws(() => validateConversationSections([section(['s1']), section(['s3'])], conversations), /omitted/i);
  assert.throws(() => validateConversationSections([section(['s2', 's1']), section(['s3'])], conversations), /contiguous|chronological/i);
  assert.throws(() => validateConversationSections([section(['s1']), section(['s1', 's2']), section(['s3'])], conversations), /more than one/i);
  assert.throws(() => validateConversationSections([section(['s1', 's3']), section(['s2'])], conversations), /streams/i);
});
