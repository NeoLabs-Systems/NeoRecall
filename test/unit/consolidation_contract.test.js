'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  consolidationSchema, consolidationJsonSchema, consolidationJsonSchemaFor,
  normalizeConsolidationTimestamps, GENERATED_MINI_MEMORY_KINDS,
} = require('../../server/ai/schemas/consolidation_schema');
const { localTimestamp, prepareConsolidationRequest, restoreReferenceIds } = require('../../server/ai/prompts/consolidate_memories');
const { conversationPreviewMessages } = require('../../server/ai/prompts/preview_conversation');
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
  assert.equal(prepared.windows.length, 1, 'Input that fits needs exactly one request.');
  const messages = prepared.windows[0].messages(null);
  assert.match(messages[0].content, /concrete responsible person/);
  assert.match(messages[0].content, /Prefer \[\]/);
  assert.match(messages[0].content, /unaccepted requests/);
  const payload = JSON.parse(messages[1].content);
  assert.equal(payload.conversations[0].id, 'c1');
  assert.equal(payload.conversations[0].segments[0].id, 's1');
  assert.equal(payload.conversations[0].segments[0].speaker, 'speaker1');
  assert.equal(messages[1].content.includes(conversationId), false);
  assert.equal(messages[1].content.includes(segmentId), false);
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

test('an entity may report which speaker label its voice belongs to', () => {
  const parsed = consolidationSchema.parse({
    conversationSections: [{ titleEn: 'Introduction', summaryEn: 'Sumner introduced himself.', memoryWorthy: true, topics: [], sourceSegmentIds: ['segment-1'] }],
    entities: [
      { ref: 'person-1', kind: 'person', canonicalNameEn: 'Sumner Tilton', displayName: null, aliases: [], speakerAlias: 'speaker1' },
      { ref: 'loc-1', kind: 'location', canonicalNameEn: 'City Hall', displayName: null, aliases: [] },
    ],
    memories: [], dailySummary: null,
  });
  assert.equal(parsed.entities[0].speakerAlias, 'speaker1');
  assert.equal(parsed.entities[1].speakerAlias, undefined);
  assert.deepEqual(consolidationJsonSchema.properties.entities.items.required, ['ref', 'kind', 'canonicalNameEn', 'displayName', 'aliases', 'speakerAlias']);
});

test('compactInput exposes speaker aliases in both directions so a response can be resolved back to a cluster', () => {
  const prepared = prepareConsolidationRequest({ timezone: 'UTC', previousDailySummary: null, conversations: [{
    id: 'conv-1', startedAt: '2026-07-14T08:00:00.000Z', endedAt: '2026-07-14T08:01:00.000Z', segments: [{
      id: 'seg-1', started_at: '2026-07-14T08:00:00.000Z', ended_at: '2026-07-14T08:00:05.000Z',
      text: 'My name is Sumner Tilton.', language: 'en', speakerClusterId: 'cluster-abc',
    }],
  }] });
  assert.equal(prepared.references.reverseSpeakerAliases.get('speaker1'), 'cluster-abc');
});

test('recurring voice identity stays stable across sessions and continuation cards', () => {
  const prepared = prepareConsolidationRequest({ timezone: 'UTC', previousDailySummary: null,
    conversations: [{
      id: 'conv-1', sessionId: 'new-session', startedAt: '2026-07-14T08:00:00.000Z', endedAt: '2026-07-14T08:01:00.000Z',
      segments: [{ id: 'seg-1', started_at: '2026-07-14T08:00:00.000Z', ended_at: '2026-07-14T08:00:05.000Z',
        text: 'Let us continue the design review.', language: 'en', speakerClusterId: 'new-cluster', speakerVoiceprintId: 'stable-voice' }],
    }],
    continuationCandidates: [{ publicId: 'memory-1', type: 'meeting', titleEn: 'Design review', summaryEn: 'The review began.',
      startedAt: '2026-07-14T07:30:00.000Z', endedAt: '2026-07-14T07:53:00.000Z', topics: ['Design'], highlights: [],
      sessionIds: ['old-session'], speakerIdentities: ['stable-voice'] }],
  });
  const payload = JSON.parse(prepared.windows[0].messages(null)[1].content);
  const inputSpeaker = payload.conversations[0].segments[0].speaker;
  assert.equal(payload.continuationCandidates[0].speakers[0], inputSpeaker,
    'the model can see that the same anonymized voice occurs on both sides of a recording restart');
  assert.equal(prepared.references.reverseSpeakerAliases.get(inputSpeaker), 'new-cluster');
});

test('preview and consolidation share title guidance that ignores capture artifacts', () => {
  const conversation = { id: 'conv-1', startedAt: '2026-07-14T08:00:00.000Z', endedAt: '2026-07-14T08:01:00.000Z',
    segments: [{ id: 'seg-1', started_at: '2026-07-14T08:00:00.000Z', ended_at: '2026-07-14T08:00:05.000Z',
      text: 'We need to adjust the integrator circuit.', language: 'en', speakerClusterId: 'cluster-1' }] };
  const prepared = prepareConsolidationRequest({ timezone: 'UTC', previousDailySummary: null, conversations: [conversation] });
  const consolidationInstructions = prepared.windows[0].messages(null)[0].content;
  const previewInstructions = conversationPreviewMessages({ conversation, timezone: 'UTC' })[0].content;
  for (const instructions of [consolidationInstructions, previewInstructions]) {
    assert.match(instructions, /human subject and purpose/);
    assert.match(instructions, /Speaker fields are metadata/);
    assert.match(instructions, /Do not diagnose the transcript in the title/);
  }
});

test('dynamic consolidation schema restricts every transcript reference to compact segment aliases', () => {
  const schema = consolidationJsonSchemaFor(['s1', 's2']);
  assert.deepEqual(schema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum, ['s1', 's2']);
  assert.deepEqual(schema.properties.memories.items.properties.sourceSegmentIds.items.enum, ['s1', 's2']);
  assert.notStrictEqual(schema.properties.conversationSections.items.properties.sourceSegmentIds.items,
    schema.properties.memories.items.properties.sourceSegmentIds.items);
  assert.equal(consolidationJsonSchema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum, undefined);
  assert.deepEqual(
    schema.properties.memories.items.properties.miniMemories.items.properties.kind.enum,
    [...GENERATED_MINI_MEMORY_KINDS],
    'new highlights can only be action items',
  );
  assert.deepEqual(
    schema.properties.memories.items.properties.miniMemories.items.properties.status.enum,
    ['open'],
  );
  assert.equal(
    schema.properties.memories.items.properties.miniMemories.items.properties.occurredAt.type,
    'null',
  );
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

test('only actionable LLM highlights survive normalization before persistence', () => {
  const output = { memories: [{ miniMemories: [
    { kind: 'task', dueAt: { localDateTime: '2026-07-16T17:30:00', timezone: 'Europe/Berlin' }, occurredAt: null, status: 'open' },
    { kind: 'fact', dueAt: null, occurredAt: null, status: 'completed' },
    { kind: 'promise', dueAt: null, occurredAt: null, status: 'completed' },
  ] }] };
  normalizeConsolidationTimestamps(output);
  assert.equal(output.memories[0].miniMemories.length, 1);
  assert.equal(output.memories[0].miniMemories[0].dueAt, '2026-07-16T15:30:00.000Z');
  assert.equal(output.memories[0].miniMemories[0].status, 'open');
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
