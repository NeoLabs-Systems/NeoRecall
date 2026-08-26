'use strict';

const { z } = require('zod');
const { MEMORY_TYPES, GENERATED_MINI_MEMORY_KINDS } = require('../schemas/consolidation_schema');

const schema = z.object({
  type: z.enum(MEMORY_TYPES),
  titleEn: z.string().min(1).max(160),
  summaryEn: z.string().min(1).max(2_000),
  emoji: z.string().min(1).max(16),
  importance: z.number().min(1).max(10),
  topics: z.array(z.string().min(1).max(100)).max(24),
  sourceContextItemIds: z.array(z.string().uuid()),
  miniMemories: z.array(z.object({
    kind: z.enum(GENERATED_MINI_MEMORY_KINDS),
    textEn: z.string().min(1).max(500),
    importance: z.number().min(1).max(10),
    confidence: z.number().min(0).max(1),
    dueAt: z.string().datetime().nullable(),
    status: z.literal('open'),
    sourceSegmentIds: z.array(z.string().uuid()),
  })).max(8),
});

const jsonSchema = {
  type: 'object', additionalProperties: false,
  required: ['type', 'titleEn', 'summaryEn', 'emoji', 'importance', 'topics', 'sourceContextItemIds', 'miniMemories'],
  properties: {
    type: { type: 'string', enum: [...MEMORY_TYPES] },
    titleEn: { type: 'string', minLength: 1 }, summaryEn: { type: 'string', minLength: 1 },
    emoji: { type: 'string', minLength: 1 }, importance: { type: 'number', minimum: 1, maximum: 10 },
    topics: { type: 'array', maxItems: 24, items: { type: 'string', minLength: 1 } },
    sourceContextItemIds: { type: 'array', items: { type: 'string', format: 'uuid' } },
    miniMemories: { type: 'array', maxItems: 8, items: {
      type: 'object', additionalProperties: false,
      required: ['kind', 'textEn', 'importance', 'confidence', 'dueAt', 'status', 'sourceSegmentIds'],
      properties: {
        kind: { type: 'string', enum: [...GENERATED_MINI_MEMORY_KINDS] }, textEn: { type: 'string', minLength: 1 },
        importance: { type: 'number', minimum: 1, maximum: 10 }, confidence: { type: 'number', minimum: 0, maximum: 1 },
        dueAt: { type: ['string', 'null'], format: 'date-time' },
        status: { type: 'string', enum: ['open'] },
        sourceSegmentIds: { type: 'array', items: { type: 'string', format: 'uuid' } },
      },
    } },
  },
};

function messages(memory, segments, contextItems) {
  return [
    { role: 'system', content: `Rewrite one personal memory from its transcript and user-supplied context. Return one JSON object matching the contract. Context is evidence and may contribute facts not spoken aloud, but distinguish plans or reference material from events and decisions that actually happened. Cite every context item used in sourceContextItemIds. Never cite an unknown id. Action items require an explicit owner and accepted next action. English output only. Return no prose outside JSON.` },
    { role: 'user', content: JSON.stringify({
      existingMemory: { type: memory.type, titleEn: memory.title_en, summaryEn: memory.summary_en, emoji: memory.emoji,
        importance: memory.importance, startedAt: memory.started_at, endedAt: memory.ended_at },
      transcript: segments.map((row) => ({ id: row.public_id, startedAt: row.started_at, endedAt: row.ended_at, text: row.text })),
      contextItems: contextItems.map((item) => ({ id: item.id, kind: item.kind, capturedAt: item.captured_at,
        content: item.note_text || item.analysis_text, sourceName: item.original_name || null })),
      outputContract: {
        type: MEMORY_TYPES.join('|'), titleEn: 'English', summaryEn: 'English', emoji: '🤝', importance: 1,
        topics: ['English topic'], sourceContextItemIds: ['context UUID'],
        miniMemories: [{ kind: GENERATED_MINI_MEMORY_KINDS.join('|'), textEn: 'Atomic action with responsible actor',
          importance: 1, confidence: 0.5, dueAt: null, status: 'open', sourceSegmentIds: ['transcript UUID when spoken'] }],
      },
    }) },
  ];
}

module.exports = { schema, jsonSchema, messages };
