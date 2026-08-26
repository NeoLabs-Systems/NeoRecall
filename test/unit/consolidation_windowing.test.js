'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { prepareConsolidationRequest, windowConversations, carryOverFor } = require('../../server/ai/prompts/consolidate_memories');
const { mergeWindow } = require('../../server/ai/ai_engine');
const { consolidationSchema } = require('../../server/ai/schemas/consolidation_schema');

const base = Date.parse('2026-08-05T09:00:00.000Z');

function segment(index, text) {
  return {
    id: `seg-${index}`,
    started_at: new Date(base + index * 60_000).toISOString(),
    ended_at: new Date(base + index * 60_000 + 55_000).toISOString(),
    text,
    language: 'en',
    speakerClusterId: 'cluster-a',
  };
}

function conversation(count, textLength) {
  return {
    id: 'conv-1',
    sessionId: 'sess-1',
    startedAt: new Date(base).toISOString(),
    endedAt: new Date(base + count * 60_000).toISOString(),
    segments: Array.from({ length: count }, (_, index) => segment(index, 'x'.repeat(textLength))),
  };
}

test('a transcript that fits the context is still exactly one request', () => {
  const prepared = prepareConsolidationRequest(
    { timezone: 'UTC', previousDailySummary: null, conversations: [conversation(4, 100)] },
    100_000,
  );
  assert.equal(prepared.windows.length, 1);
  assert.deepEqual(prepared.windows[0].segmentIds, ['s1', 's2', 's3', 's4']);
  const messages = prepared.windows[0].messages(null);
  assert.equal(JSON.parse(messages[1].content).carryOver, undefined, 'The first window has nothing to carry over.');
});

test('a transcript longer than the context is split in order, without losing or repeating a segment', () => {
  const prepared = prepareConsolidationRequest(
    { timezone: 'UTC', previousDailySummary: null, conversations: [conversation(40, 400)] },
    4_000,
  );
  assert.ok(prepared.windows.length > 1, 'The fixture must actually exceed one window.');
  const covered = prepared.windows.flatMap((window) => window.segmentIds);
  assert.deepEqual(covered, Array.from({ length: 40 }, (_, index) => `s${index + 1}`),
    'Every segment appears exactly once, in recording order.');
  for (const window of prepared.windows) assert.ok(window.segmentIds.length > 0);
});

test('a segment larger than a whole window is sent alone rather than dropped', () => {
  // One recognized utterance cannot be split further. Sending it alone lets the
  // provider decide whether it truly does not fit; dropping it would lose
  // evidence silently.
  const windows = windowConversations(
    [{ id: 'c1', stream: 'stream1', recorded: {}, segments: [
      { id: 's1', text: 'a'.repeat(50) },
      { id: 's2', text: 'b'.repeat(5_000) },
      { id: 's3', text: 'c'.repeat(50) },
    ] }],
    500,
  );
  const flat = windows.map((window) => window.flatMap((item) => item.segments.map((entry) => entry.id)));
  assert.deepEqual(flat.flat(), ['s1', 's2', 's3']);
  assert.ok(flat.some((ids) => ids.length === 1 && ids[0] === 's2'));
});

test('later windows are told only about the occasion still in progress', () => {
  const merged = {
    conversationSections: [
      { titleEn: 'Earlier chat', summaryEn: 'Done.', topics: [], memoryWorthy: false, sourceSegmentIds: ['s1'] },
      { titleEn: 'The lecture', summaryEn: 'Half of it.', topics: ['Physics'], memoryWorthy: true, sourceSegmentIds: ['s2', 's3'] },
    ],
    memories: [
      { type: 'lesson', titleEn: 'The lecture', summaryEn: 'Half of it.', emoji: '📚', importance: 7, topics: ['Physics'], sourceSegmentIds: ['s2', 's3'] },
    ],
  };
  const carry = carryOverFor(merged);
  assert.equal(carry.section.titleEn, 'The lecture', 'Only the trailing section can be continued.');
  assert.equal(carry.memory.titleEn, 'The lecture');
  assert.equal(JSON.stringify(carry).includes('Earlier chat'), false,
    'Carry-over must not grow with the number of windows already processed.');
});

test('a section a window says it is continuing is folded into the previous one, not appended', () => {
  const merged = { conversationSections: [], entities: [], memories: [], dailySummary: null, windowCount: 0 };

  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Lecture', summaryEn: 'The first half.', memoryWorthy: true, topics: ['Physics'], continuesPrevious: false, sourceSegmentIds: ['s1', 's2'] }],
    entities: [{ ref: 'p1', kind: 'person', canonicalNameEn: 'Maria', displayName: null, aliases: [], speakerAlias: null }],
    memories: [{ type: 'lesson', continuesPrevious: false, titleEn: 'Lecture', summaryEn: 'The first half.', emoji: '📚', importance: 7,
      sourceSegmentIds: ['s1', 's2'], topics: ['Physics'], entities: [{ ref: 'p1', role: 'teacher' }],
      miniMemories: [{ kind: 'task', textEn: 'Maria will send the course notes.', importance: 5, confidence: 0.9, sourceSegmentIds: ['s1'], entities: [] }] }],
    dailySummary: null,
  }));

  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Lecture', summaryEn: 'The whole lecture.', memoryWorthy: true, topics: ['Physics', 'Optics'], continuesPrevious: true, sourceSegmentIds: ['s3', 's4'] }],
    entities: [{ ref: 'p1', kind: 'person', canonicalNameEn: 'Maria', displayName: null, aliases: [], speakerAlias: null }],
    memories: [{ type: 'lesson', continuesPrevious: true, titleEn: 'Lecture', summaryEn: 'The whole lecture.', emoji: '📚', importance: 8,
      sourceSegmentIds: ['s3', 's4'], topics: ['Physics', 'Optics'], entities: [{ ref: 'p1', role: 'teacher' }],
      miniMemories: [{ kind: 'promise', textEn: 'Maria promised to share the optics worksheet.', importance: 4, confidence: 0.8, sourceSegmentIds: ['s4'], entities: [] }] }],
    dailySummary: null,
  }));

  assert.equal(merged.conversationSections.length, 1, 'One occasion stays one section across windows.');
  assert.deepEqual(merged.conversationSections[0].sourceSegmentIds, ['s1', 's2', 's3', 's4']);
  assert.equal(merged.conversationSections[0].summaryEn, 'The whole lecture.',
    'The description written for the wider view replaces the narrower one.');

  assert.equal(merged.memories.length, 1, 'One occasion stays one memory across windows.');
  assert.deepEqual(merged.memories[0].sourceSegmentIds, ['s1', 's2', 's3', 's4']);
  assert.equal(merged.memories[0].miniMemories.length, 2, 'Evidence from both windows is kept.');
  assert.equal(merged.dailySummary, null, 'No window writes the day; a separate request does, once.');

  // Entity refs are response-local, so two windows can both call their first
  // entity "p1" while meaning different people. Namespacing keeps every citation
  // pointing at the entity its own window described.
  assert.deepEqual(merged.entities.map((entity) => entity.ref), ['w1/p1', 'w2/p1']);
  assert.deepEqual(merged.memories[0].entities.map((item) => item.ref), ['w1/p1', 'w2/p1']);
});

test('a window that opens a new occasion adds a section instead of extending the previous one', () => {
  const merged = { conversationSections: [], entities: [], memories: [], dailySummary: null, windowCount: 0 };
  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Standup', summaryEn: 'The standup.', memoryWorthy: true, topics: [], continuesPrevious: false, sourceSegmentIds: ['s1'] }],
    entities: [], memories: [], dailySummary: null,
  }));
  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Lunch', summaryEn: 'Unrelated chat.', memoryWorthy: false, topics: [], continuesPrevious: false, sourceSegmentIds: ['s2'] }],
    entities: [], memories: [], dailySummary: null,
  }));
  assert.deepEqual(merged.conversationSections.map((section) => section.titleEn), ['Standup', 'Lunch']);
});

test('only the first section of a window may claim to continue the previous one', () => {
  // Coverage has to stay contiguous whatever the model returns: a later section
  // that claims continuation would otherwise be spliced into a range it does not
  // adjoin.
  const merged = { conversationSections: [], entities: [], memories: [], dailySummary: null, windowCount: 0 };
  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [{ titleEn: 'A', summaryEn: 'First.', memoryWorthy: false, topics: [], continuesPrevious: false, sourceSegmentIds: ['s1'] }],
    entities: [], memories: [], dailySummary: null,
  }));
  mergeWindow(merged, consolidationSchema.parse({
    conversationSections: [
      { titleEn: 'B', summaryEn: 'Second.', memoryWorthy: false, topics: [], continuesPrevious: false, sourceSegmentIds: ['s2'] },
      { titleEn: 'C', summaryEn: 'Third.', memoryWorthy: false, topics: [], continuesPrevious: true, sourceSegmentIds: ['s3'] },
    ],
    entities: [], memories: [], dailySummary: null,
  }));
  assert.deepEqual(merged.conversationSections.map((section) => section.sourceSegmentIds), [['s1'], ['s2'], ['s3']]);
});

test('segments a window left uncited join the section they adjoin instead of failing the run', () => {
  // Measured against a real transcript on a small local model: a window of
  // thirty-five segments came back with fifteen cited and the rest missing.
  // Validation rejects a partition with a hole, so without this the whole
  // consolidation is discarded and the conversation eventually quarantined.
  const { completeCoverage } = require('../../server/ai/ai_engine');
  const sections = [
    { titleEn: 'Opening', sourceSegmentIds: ['s1', 's2'] },
    { titleEn: 'Decisions', sourceSegmentIds: ['s5'] },
  ];
  const repaired = completeCoverage(sections, ['s1', 's2', 's3', 's4', 's5', 's6', 's7']);
  assert.deepEqual(repaired.map((section) => section.sourceSegmentIds), [
    ['s1', 's2', 's3', 's4'],
    ['s5', 's6', 's7'],
  ], 'An unclaimed segment joins the section that owns the segment before it.');
});

test('coverage completion keeps every segment exactly once and in recording order', () => {
  const { completeCoverage } = require('../../server/ai/ai_engine');
  const segmentIds = ['s1', 's2', 's3', 's4'];
  const repaired = completeCoverage([
    // Reordered, duplicated across sections, and missing s3 — every way the
    // partition contract can be broken at once.
    { titleEn: 'B', sourceSegmentIds: ['s4', 's2'] },
    { titleEn: 'A', sourceSegmentIds: ['s2', 's1'] },
  ], segmentIds);
  const covered = repaired.flatMap((section) => section.sourceSegmentIds);
  assert.deepEqual([...covered].sort(), segmentIds, 'Nothing is dropped and nothing is duplicated.');
  for (const section of repaired) {
    const positions = section.sourceSegmentIds.map((id) => segmentIds.indexOf(id));
    assert.deepEqual(positions, [...positions].sort((a, b) => a - b), 'Each section stays in recording order.');
  }
});

test('a window whose sections cite nothing recognizable still covers the window', () => {
  const { completeCoverage } = require('../../server/ai/ai_engine');
  const repaired = completeCoverage([{ titleEn: 'Only section', sourceSegmentIds: ['not-in-this-window'] }], ['s1', 's2']);
  assert.deepEqual(repaired.map((section) => section.sourceSegmentIds), [['s1', 's2']]);
});
