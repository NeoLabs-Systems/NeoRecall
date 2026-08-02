'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  consolidationSchema,
  consolidationJsonSchema,
  defaultEmojiForType,
} = require('../../server/ai/schemas/consolidation_schema');
const { presentMemory } = require('../../server/services/memories/memory_service');

test('memory consolidation requires a consumer emoji', () => {
  const parsed = consolidationSchema.parse({
    conversationSections: [{
      titleEn: 'Standup', summaryEn: 'Team standup.', memoryWorthy: true, topics: [], sourceSegmentIds: ['s1'],
    }],
    entities: [],
    memories: [{
      type: 'meeting',
      titleEn: 'Standup',
      summaryEn: 'Team standup covered blockers.',
      emoji: '🤝',
      importance: 5,
      sourceSegmentIds: ['s1'],
      topics: [],
      entities: [],
      miniMemories: [],
    }],
    dailySummary: null,
  });
  assert.equal(parsed.memories[0].emoji, '🤝');
  assert.equal(
    consolidationJsonSchema.properties.memories.items.required.includes('emoji'),
    true,
  );
});

test('missing stored emoji falls back by memory type for the consumer UI', () => {
  const presented = presentMemory({
    public_id: 'abc',
    type: 'lesson',
    title_en: 'History class',
    summary_en: 'Covered the Renaissance.',
    emoji: null,
    pinned: 1,
    archived: 0,
    importance: 6,
    topics_csv: 'History||Art',
    mini_count: 2,
  });
  assert.equal(presented.emoji, defaultEmojiForType('lesson'));
  assert.equal(presented.emoji, '📚');
  assert.equal(presented.pinned, true);
  assert.equal(presented.archived, false);
  assert.deepEqual(presented.topics, ['History', 'Art']);
  assert.equal(presented.mini_count, 2);
});
