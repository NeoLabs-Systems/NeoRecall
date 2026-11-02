'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { repairConsolidation } = require('../../server/ai/repair_consolidation');
const { consolidationSchema } = require('../../server/ai/schemas/consolidation_schema');

const segmentIds = ['s1', 's2', 's3', 's4'];
const section = (over = {}) => ({ titleEn: 'Planning', summaryEn: 'They planned the release.', memoryWorthy: true, topics: ['release'], continuesPrevious: false, sourceSegmentIds: ['s1', 's2'], ...over });
const memory = (over = {}) => ({
  type: 'meeting', continuesPrevious: false, continuationReasoning: null, continuesMemoryIds: [], titleEn: 'Release planning', summaryEn: 'Planned.',
  emoji: '🤝', importance: 6, sourceSegmentIds: ['s1', 's2'], topics: [], entities: [], miniMemories: [], ...over,
});
const mini = (over = {}) => ({ kind: 'task', textEn: 'Send the notes', importance: 5, confidence: 0.8, status: 'open', sourceSegmentIds: ['s2'], entities: [], ...over });
const repair = (raw) => repairConsolidation(raw, { segmentIds, continuationMemoryIds: ['m1'] });

test('a fully valid answer passes through unchanged in meaning', () => {
  const { value, dropped } = repair({ conversationSections: [section()], entities: [], memories: [memory({ miniMemories: [mini()] })], dailySummary: null });
  assert.equal(consolidationSchema.safeParse(value).success, true);
  assert.deepEqual(dropped, { sections: 0, entities: 0, memories: 0, miniMemories: 0 });
  assert.equal(value.memories[0].miniMemories.length, 1);
});

test('one malformed action item no longer costs the whole answer', () => {
  const { value, dropped } = repair({
    conversationSections: [section()], entities: [],
    memories: [memory({ miniMemories: [mini(), mini({ kind: 'not-a-kind' }), mini({ textEn: '' })] })],
  });
  assert.equal(value.memories[0].miniMemories.length, 1);
  assert.equal(dropped.miniMemories, 2);
});

test('numbers sent as text and single ids sent as lists are read as intended', () => {
  const { value } = repair({ conversationSections: [section({ sourceSegmentIds: 's1' })], memories: [memory({ importance: '7', sourceSegmentIds: 's2', topics: 'release' })] });
  assert.equal(value.memories[0].importance, 7);
  assert.deepEqual(value.memories[0].sourceSegmentIds, ['s2']);
  assert.deepEqual(value.memories[0].topics.length, 1);
});

test('citations outside the window are removed, and a memory left with none is dropped', () => {
  const { value, dropped } = repair({
    conversationSections: [section()],
    memories: [memory({ sourceSegmentIds: ['s1', 'invented'] }), memory({ sourceSegmentIds: ['invented'] })],
  });
  assert.deepEqual(value.memories[0].sourceSegmentIds, ['s1']);
  assert.equal(value.memories.length, 1);
  assert.equal(dropped.memories, 1);
});

test('references to undefined entities and unknown continuation cards are removed rather than fatal', () => {
  const { value } = repair({
    conversationSections: [section()],
    memories: [memory({ entities: [{ ref: 'ghost', role: 'speaker' }], continuesMemoryIds: ['m1', 'nope'], miniMemories: [mini({ entities: [{ ref: 'ghost', role: 'x' }] })] })],
  });
  assert.deepEqual(value.memories[0].entities, []);
  assert.deepEqual(value.memories[0].continuesMemoryIds, ['m1']);
  assert.deepEqual(value.memories[0].miniMemories[0].entities, []);
});

test('a memory in a section the model called not worth remembering makes that section memory-worthy', () => {
  const { value } = repair({ conversationSections: [section({ memoryWorthy: false })], memories: [memory()] });
  assert.equal(value.conversationSections[0].memoryWorthy, true);
});

test('with no usable section the memory carries its words over the whole window', () => {
  const { value } = repair({ conversationSections: [{ nonsense: true }], memories: [memory()] });
  assert.equal(value.conversationSections.length, 1);
  assert.equal(value.conversationSections[0].titleEn, 'Release planning');
  assert.deepEqual(value.conversationSections[0].sourceSegmentIds, segmentIds);
});

test('the daily summary is never taken from a window', () => {
  assert.equal(repair({ conversationSections: [section()], dailySummary: { anything: 1 } }).value.dailySummary, null);
});

test('an answer with nothing usable is still refused', () => {
  assert.equal(repair({ conversationSections: [], memories: [] }).value, null);
  assert.equal(repair('not json').value, null);
  assert.equal(repair({ conversationSections: [{ titleEn: '' }] }).value, null);
});

test('a daily summary under another field name, or in a list, is still read', () => {
  const { repairDailySummary } = require('../../server/ai/repair_consolidation');
  assert.deepEqual(repairDailySummary({ summary: ' They shipped. ' }), { summaryEn: 'They shipped.' });
  assert.deepEqual(repairDailySummary({ summaryEn: ['One.', 'Two.'] }), { summaryEn: 'One. Two.' });
  assert.equal(repairDailySummary({ summaryEn: 5 }), null);
  assert.equal(repairDailySummary('x'), null);
});
