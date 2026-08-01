'use strict';

const { z } = require('zod');
const { localDateTimeToUtc } = require('../../utils/time');

const TITLE_MAX_LENGTH = 160;
const SUMMARY_MAX_LENGTH = 2_000;
const TOPIC_MAX_LENGTH = 100;
const TOPIC_MAX_COUNT = 12;
const sourceIds = z.array(z.string().min(1)).min(1);
const aliases = z.preprocess((value) => {
  if (!Array.isArray(value)) return value;
  return value.map((alias) => typeof alias === 'string' ? { value: alias, language: null } : alias);
}, z.array(z.object({ value: z.string().min(1), language: z.string().nullable().optional() })));
const entity = z.object({
  ref: z.string().min(1), kind: z.enum(['person', 'organization', 'project', 'location', 'other']),
  canonicalNameEn: z.string().min(1), displayName: z.string().min(1).nullable().optional(), aliases: aliases.default([]),
  // The input speaker label (e.g. "speaker2") whose voice this person entity was
  // identified as, when the transcript itself supports the link. Resolved back
  // to the durable speaker cluster and used to name a voiceprint at no extra AI
  // cost, since this rides along on the consolidation request already made.
  speakerAlias: z.string().min(1).nullable().optional(),
});
const temporalReference = z.union([
  z.string().datetime(),
  z.object({
    localDateTime: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/),
    timezone: z.string().min(1),
  }),
]).nullable();
const entityReference = z.object({ ref: z.string().min(1), role: z.string().min(1) });
// Exported so prompts describe exactly the taxonomy the schema enforces instead
// of restating it in prose that can drift out of sync.
const MEMORY_TYPES = Object.freeze([
  'meeting', 'lesson', 'conversation', 'project_discussion', 'introduction', 'decision', 'experience', 'other',
]);
const MINI_MEMORY_KINDS = Object.freeze([
  'fact', 'event', 'location', 'person', 'relationship', 'task', 'promise',
]);
const ENTITY_KINDS = Object.freeze(['person', 'organization', 'project', 'location', 'other']);
const miniMemory = z.object({
  kind: z.enum(MINI_MEMORY_KINDS),
  textEn: z.string().min(1), importance: z.number().min(1).max(10), confidence: z.number().min(0).max(1),
  dueAt: temporalReference.optional(), occurredAt: temporalReference.optional(),
  status: z.enum(['open', 'completed', 'cancelled']).nullable().optional(), sourceSegmentIds: sourceIds,
  entities: z.array(entityReference).default([]),
});
const memory = z.object({
  type: z.enum(MEMORY_TYPES),
  titleEn: z.string().min(1).max(TITLE_MAX_LENGTH), summaryEn: z.string().min(1).max(SUMMARY_MAX_LENGTH), importance: z.number().min(1).max(10),
  sourceSegmentIds: sourceIds, topics: z.array(z.string().min(1).max(TOPIC_MAX_LENGTH)).max(TOPIC_MAX_COUNT).default([]),
  entities: z.array(entityReference).default([]), miniMemories: z.array(miniMemory).default([]),
});
// What NeoRecall shows for a conversation. Consolidation derives it for a final,
// evidence-partitioned section; the live preview derives the same shape for a
// conversation that is still recording, so both write the same columns.
const conversationInsightFields = {
  titleEn: z.string().min(1).max(TITLE_MAX_LENGTH),
  summaryEn: z.string().min(1).max(SUMMARY_MAX_LENGTH),
  memoryWorthy: z.boolean(),
  topics: z.array(z.string().min(1).max(TOPIC_MAX_LENGTH)).max(TOPIC_MAX_COUNT).default([]),
};
const conversationSection = z.object({ ...conversationInsightFields, sourceSegmentIds: sourceIds });

const consolidationSchema = z.object({
  conversationSections: z.array(conversationSection).min(1),
  entities: z.array(entity).default([]),
  memories: z.array(memory).default([]),
  dailySummary: z.object({
    localDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    timezone: z.string().min(1),
    summaryEn: z.string().min(1),
  }).nullable(),
});

const nullableString = { anyOf: [{ type: 'string' }, { type: 'null' }] };
const temporalReferenceJsonSchema = { anyOf: [{ type: 'null' }, {
  type: 'object', additionalProperties: false, required: ['localDateTime', 'timezone'],
  properties: {
    localDateTime: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}$' },
    timezone: { type: 'string', minLength: 1 },
  },
}] };
const entityReferenceJsonSchema = {
  type: 'object', additionalProperties: false, required: ['ref', 'role'],
  properties: { ref: { type: 'string', minLength: 1 }, role: { type: 'string', minLength: 1 } },
};
const sourceIdsJsonSchema = { type: 'array', minItems: 1, items: { type: 'string', minLength: 1 } };
const topicsJsonSchema = {
  type: 'array', maxItems: TOPIC_MAX_COUNT,
  items: { type: 'string', minLength: 1, maxLength: TOPIC_MAX_LENGTH },
};
const conversationInsightRequired = Object.freeze(['titleEn', 'summaryEn', 'memoryWorthy', 'topics']);
const conversationInsightJsonProperties = Object.freeze({
  titleEn: { type: 'string', minLength: 1, maxLength: TITLE_MAX_LENGTH },
  summaryEn: { type: 'string', minLength: 1, maxLength: SUMMARY_MAX_LENGTH },
  memoryWorthy: { type: 'boolean' },
  topics: topicsJsonSchema,
});

const consolidationJsonSchema = {
  type: 'object', additionalProperties: false,
  required: ['conversationSections', 'entities', 'memories', 'dailySummary'],
  properties: {
    conversationSections: {
      type: 'array', minItems: 1,
      items: {
        type: 'object', additionalProperties: false,
        required: [...conversationInsightRequired, 'sourceSegmentIds'],
        properties: { ...conversationInsightJsonProperties, sourceSegmentIds: sourceIdsJsonSchema },
      },
    },
    entities: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['ref', 'kind', 'canonicalNameEn', 'displayName', 'aliases', 'speakerAlias'],
        properties: {
          ref: { type: 'string', minLength: 1 },
          kind: { type: 'string', enum: [...ENTITY_KINDS] },
          canonicalNameEn: { type: 'string', minLength: 1 }, displayName: nullableString,
          aliases: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false, required: ['value', 'language'],
              properties: { value: { type: 'string', minLength: 1 }, language: nullableString },
            },
          },
          speakerAlias: nullableString,
        },
      },
    },
    memories: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['type', 'titleEn', 'summaryEn', 'importance', 'sourceSegmentIds', 'topics', 'entities', 'miniMemories'],
        properties: {
          type: { type: 'string', enum: [...MEMORY_TYPES] },
          titleEn: { type: 'string', minLength: 1, maxLength: TITLE_MAX_LENGTH },
          summaryEn: { type: 'string', minLength: 1, maxLength: SUMMARY_MAX_LENGTH },
          importance: { type: 'number', minimum: 1, maximum: 10 },
          sourceSegmentIds: sourceIdsJsonSchema,
          topics: topicsJsonSchema,
          entities: { type: 'array', items: entityReferenceJsonSchema },
          miniMemories: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false,
              required: ['kind', 'textEn', 'importance', 'confidence', 'dueAt', 'occurredAt', 'status', 'sourceSegmentIds', 'entities'],
              properties: {
                kind: { type: 'string', enum: [...MINI_MEMORY_KINDS] },
                textEn: { type: 'string', minLength: 1 }, importance: { type: 'number', minimum: 1, maximum: 10 },
                confidence: { type: 'number', minimum: 0, maximum: 1 }, dueAt: temporalReferenceJsonSchema, occurredAt: temporalReferenceJsonSchema,
                status: { anyOf: [{ type: 'string', enum: ['open', 'completed', 'cancelled'] }, { type: 'null' }] },
                sourceSegmentIds: sourceIdsJsonSchema, entities: { type: 'array', items: entityReferenceJsonSchema },
              },
            },
          },
        },
      },
    },
    dailySummary: {
      anyOf: [{ type: 'null' }, {
        type: 'object', additionalProperties: false,
        required: ['localDate', 'timezone', 'summaryEn'],
        properties: {
          localDate: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}$' },
          timezone: { type: 'string', minLength: 1 },
          summaryEn: { type: 'string', minLength: 1 },
        },
      }],
    },
  },
};

function consolidationJsonSchemaFor(segmentIds) {
  const schema = JSON.parse(JSON.stringify(consolidationJsonSchema));
  schema.properties.conversationSections.items.properties.sourceSegmentIds.items.enum = segmentIds;
  const memorySchema = schema.properties.memories.items;
  memorySchema.properties.sourceSegmentIds.items.enum = segmentIds;
  memorySchema.properties.miniMemories.items.properties.sourceSegmentIds.items.enum = segmentIds;
  return schema;
}

function normalizeTemporalReference(value) {
  if (!value) return null;
  if (typeof value === 'string') return new Date(value).toISOString();
  return localDateTimeToUtc(value.localDateTime, value.timezone);
}

function normalizeConsolidationTimestamps(output) {
  for (const memoryItem of output.memories) {
    for (const mini of memoryItem.miniMemories) {
      mini.dueAt = normalizeTemporalReference(mini.dueAt);
      mini.occurredAt = normalizeTemporalReference(mini.occurredAt);
      if (!['task', 'promise'].includes(mini.kind)) mini.status = null;
    }
  }
  return output;
}

module.exports = {
  consolidationSchema,
  consolidationJsonSchema,
  consolidationJsonSchemaFor,
  normalizeConsolidationTimestamps,
  conversationInsightFields,
  conversationInsightJsonProperties,
  conversationInsightRequired,
  MEMORY_TYPES,
  MINI_MEMORY_KINDS,
  ENTITY_KINDS,
};
