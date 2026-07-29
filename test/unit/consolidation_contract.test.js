'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { consolidationSchema, consolidationJsonSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps } = require('../../server/ai/schemas/consolidation_schema');
const { localTimestamp, prepareConsolidationRequest, restoreReferenceIds } = require('../../server/ai/prompts/consolidate_memories');
const { anchorMemoryRanges } = require('../../server/services/memories/consolidation_service');
const { localDateTimeToUtc } = require('../../server/utils/time');

test('legacy string aliases are normalized without changing their meaning', () => {
  const parsed = consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Introduction', summaryEn: 'Mira introduced herself.', memoryWorthy: true, topics: [], sourceSegmentIds: ['segment-1'] }],
    entities: [{ ref: 'person-1', kind: 'person', canonicalNameEn: 'Mira Chen', displayName: 'Mira', aliases: ['Mira'] }],
    memories: [], dailySummary: null,
  });
  assert.deepEqual(parsed.entities[0].aliases, [{ value: 'Mira', language: null }]);
  assert.deepEqual(consolidationJsonSchema.properties.entities.items.properties.aliases.items.required, ['value', 'language']);
});

test('consolidation input uses compact aliases and restores durable IDs', () => {
  const conversationId = 'd9c29231-164a-48f0-a765-e62bad2e4ea2';
  const segmentId = 'af3be2c1-353e-4657-95ea-5104a4c88bd8';
  const prepared = prepareConsolidationRequest({ timezone: 'Europe/Berlin', previousDailySummary: null, conversations: [{
    id: conversationId, startedAt: '2026-07-14T08:00:00.000Z', endedAt: '2026-07-14T08:01:00.000Z', segments: [{
      id: segmentId, started_at: '2026-07-14T08:00:10.000Z', ended_at: '2026-07-14T08:00:20.000Z',
      text: 'Mira übernimmt die Aufgabe.', language: 'de', speakerClusterId: 'durable-speaker-id',
    }],
  }] });
  const payload = JSON.parse(prepared.messages[1].content);
  assert.equal(payload.conversations[0].id, 'c1');
  assert.equal(payload.conversations[0].segments[0].id, 's1');
  assert.equal(payload.conversations[0].segments[0].speaker, 'speaker1');
  assert.equal(prepared.messages[1].content.includes(conversationId), false);
  assert.equal(prepared.messages[1].content.includes(segmentId), false);
  const output = { conversationSections: [{
    titleEn: 'Task assignment', summaryEn: 'Mira accepted a task.', memoryWorthy: true, topics: ['Planning'], sourceSegmentIds: ['s1'],
  }], memories: [{
    sourceSegmentIds: ['s1'], miniMemories: [{ sourceSegmentIds: ['s1'] }],
  }] };
  restoreReferenceIds(output, prepared.references);
  assert.deepEqual(output.conversationSections[0].sourceSegmentIds, [segmentId]);
  assert.deepEqual(output.memories[0].sourceSegmentIds, [segmentId]);
  assert.deepEqual(output.memories[0].miniMemories[0].sourceSegmentIds, [segmentId]);
});

test('dynamic consolidation schema restricts every transcript reference to compact segment aliases', () => {
  const schema = consolidationJsonSchemaFor(['s1', 's2']);
  assert.deepEqual(schema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum, ['s1', 's2']);
  assert.deepEqual(schema.properties.memories.items.properties.sourceSegmentIds.items.enum, ['s1', 's2']);
  assert.notStrictEqual(schema.properties.conversationSections.items.properties.sourceSegmentIds.items,
    schema.properties.memories.items.properties.sourceSegmentIds.items);
  assert.equal(consolidationJsonSchema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum, undefined);
});

test('local timestamp context includes daylight-saving offsets', () => {
  assert.equal(localTimestamp('2026-07-14T15:00:00.000Z', 'Europe/Berlin'), '2026-07-14T17:00:00+02:00');
  assert.equal(localTimestamp('2026-01-14T15:00:00.000Z', 'Europe/Berlin'), '2026-01-14T16:00:00+01:00');
  assert.equal(localTimestamp('2026-07-14T15:00:00.000Z', 'UTC'), '2026-07-14T15:00:00+00:00');
});

test('local wall-clock references convert to UTC without model timezone arithmetic', () => {
  assert.equal(localDateTimeToUtc('2026-07-16T17:30:00', 'Europe/Berlin'), '2026-07-16T15:30:00.000Z');
  assert.equal(localDateTimeToUtc('2026-12-03T09:30:00', 'Europe/Berlin'), '2026-12-03T08:30:00.000Z');
  assert.equal(localDateTimeToUtc('2026-10-19T14:00:00', 'Asia/Tokyo'), '2026-10-19T05:00:00.000Z');
  assert.throws(() => localDateTimeToUtc('2026-03-29T02:30:00', 'Europe/Berlin'));
});

test('LLM temporal objects and status semantics normalize before persistence', () => {
  const output = { memories: [{ miniMemories: [
    { kind: 'task', dueAt: { localDateTime: '2026-07-16T17:30:00', timezone: 'Europe/Berlin' }, occurredAt: null, status: 'open' },
    { kind: 'fact', dueAt: null, occurredAt: null, status: 'completed' },
  ] }] };
  normalizeConsolidationTimestamps(output);
  assert.equal(output.memories[0].miniMemories[0].dueAt, '2026-07-16T15:30:00.000Z');
  assert.equal(output.memories[0].miniMemories[1].status, null);
});

test('episodic memory ranges are anchored to cited transcript evidence', () => {
  const output = { memories: [{ sourceSegmentIds: ['later', 'earlier'], startedAt: '2099-01-01T00:00:00Z', endedAt: '2099-01-01T01:00:00Z' }] };
  const conversations = [{ segments: [
    { id: 'earlier', started_at: '2026-07-14T08:00:00.000Z', ended_at: '2026-07-14T08:01:00.000Z' },
    { id: 'later', started_at: '2026-07-14T08:04:00.000Z', ended_at: '2026-07-14T08:05:00.000Z' },
  ] }];
  anchorMemoryRanges(output, conversations);
  assert.equal(output.memories[0].startedAt, '2026-07-14T08:00:00.000Z');
  assert.equal(output.memories[0].endedAt, '2026-07-14T08:05:00.000Z');
});
