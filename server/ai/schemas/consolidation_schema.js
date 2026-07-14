'use strict';

const { z } = require('zod');
const { localDateTimeToUtc } = require('../../utils/time');

const sourceIds = z.array(z.string().min(1)).min(1);
const aliases = z.preprocess((value) => {
  if (!Array.isArray(value)) return value;
  return value.map((alias) => typeof alias === 'string' ? { value: alias, language: null } : alias);
}, z.array(z.object({ value: z.string().min(1), language: z.string().nullable().optional() })));
const entity = z.object({
  ref: z.string().min(1), kind: z.enum(['person', 'organization', 'project', 'location', 'other']),
  canonicalNameEn: z.string().min(1), displayName: z.string().min(1).nullable().optional(), aliases: aliases.default([]),
});
const temporalReference = z.union([
  z.string().datetime(),
  z.object({
    localDateTime: z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/),
    timezone: z.string().min(1),
  }),
]).nullable();
const miniMemory = z.object({
  kind: z.enum(['fact', 'event', 'location', 'person', 'relationship', 'task', 'promise']),
  textEn: z.string().min(1), importance: z.number().min(1).max(10), confidence: z.number().min(0).max(1),
  dueAt: temporalReference.optional(), occurredAt: temporalReference.optional(),
  status: z.enum(['open', 'completed', 'cancelled']).nullable().optional(), sourceSegmentIds: sourceIds,
  entities: z.array(z.object({ ref: z.string().min(1), role: z.string().min(1) })).default([]),
});
const memory = z.object({
  type: z.enum(['meeting', 'conversation', 'project_discussion', 'introduction', 'decision', 'experience', 'other']),
  titleEn: z.string().min(1), summaryEn: z.string().min(1), importance: z.number().min(1).max(10),
  startedAt: z.string().datetime(), endedAt: z.string().datetime(), sourceConversationIds: z.array(z.string().min(1)).min(1),
  sourceSegmentIds: sourceIds, topics: z.array(z.string().min(1)).default([]),
  entities: z.array(z.object({ ref: z.string().min(1), role: z.string().min(1) })).default([]),
  miniMemories: z.array(miniMemory).default([]),
});

const consolidationSchema = z.object({
  conversationAssessments: z.array(z.object({ conversationId: z.string().min(1), memoryWorthy: z.boolean() })),
  entities: z.array(entity).default([]), memories: z.array(memory).default([]),
  dailySummary: z.object({ localDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/), timezone: z.string().min(1),
    summaryEn: z.string().min(1), coverageStartedAt: z.string().datetime().nullable(), coverageEndedAt: z.string().datetime().nullable(),
    sourceCount: z.number().int().nonnegative() }).nullable(),
});

const nullableString = { anyOf: [{ type: 'string' }, { type: 'null' }] };
const nullableDateTime = { anyOf: [{ type: 'string', format: 'date-time' }, { type: 'null' }] };
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

const consolidationJsonSchema = {
  type: 'object', additionalProperties: false,
  required: ['conversationAssessments', 'entities', 'memories', 'dailySummary'],
  properties: {
    conversationAssessments: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['conversationId', 'memoryWorthy'],
        properties: { conversationId: { type: 'string', minLength: 1 }, memoryWorthy: { type: 'boolean' } },
      },
    },
    entities: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['ref', 'kind', 'canonicalNameEn', 'displayName', 'aliases'],
        properties: {
          ref: { type: 'string', minLength: 1 },
          kind: { type: 'string', enum: ['person', 'organization', 'project', 'location', 'other'] },
          canonicalNameEn: { type: 'string', minLength: 1 }, displayName: nullableString,
          aliases: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false, required: ['value', 'language'],
              properties: { value: { type: 'string', minLength: 1 }, language: nullableString },
            },
          },
        },
      },
    },
    memories: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['type', 'titleEn', 'summaryEn', 'importance', 'startedAt', 'endedAt', 'sourceConversationIds', 'sourceSegmentIds', 'topics', 'entities', 'miniMemories'],
        properties: {
          type: { type: 'string', enum: ['meeting', 'conversation', 'project_discussion', 'introduction', 'decision', 'experience', 'other'] },
          titleEn: { type: 'string', minLength: 1 }, summaryEn: { type: 'string', minLength: 1 },
          importance: { type: 'number', minimum: 1, maximum: 10 },
          startedAt: { type: 'string', format: 'date-time' }, endedAt: { type: 'string', format: 'date-time' },
          sourceConversationIds: sourceIdsJsonSchema, sourceSegmentIds: sourceIdsJsonSchema,
          topics: { type: 'array', items: { type: 'string', minLength: 1 } },
          entities: { type: 'array', items: entityReferenceJsonSchema },
          miniMemories: {
            type: 'array',
            items: {
              type: 'object', additionalProperties: false,
              required: ['kind', 'textEn', 'importance', 'confidence', 'dueAt', 'occurredAt', 'status', 'sourceSegmentIds', 'entities'],
              properties: {
                kind: { type: 'string', enum: ['fact', 'event', 'location', 'person', 'relationship', 'task', 'promise'] },
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
        required: ['localDate', 'timezone', 'summaryEn', 'coverageStartedAt', 'coverageEndedAt', 'sourceCount'],
        properties: {
          localDate: { type: 'string', pattern: '^\\d{4}-\\d{2}-\\d{2}$' }, timezone: { type: 'string', minLength: 1 },
          summaryEn: { type: 'string', minLength: 1 }, coverageStartedAt: nullableDateTime, coverageEndedAt: nullableDateTime,
          sourceCount: { type: 'integer', minimum: 0 },
        },
      }],
    },
  },
};

function consolidationJsonSchemaFor(conversationIds, segmentIds) {
  // JSON serialization intentionally breaks shared object references in the static schema.
  // Each source-ID field needs its own enum in the provider contract.
  const schema = JSON.parse(JSON.stringify(consolidationJsonSchema));
  const assessments = schema.properties.conversationAssessments;
  assessments.minItems = conversationIds.length;
  assessments.maxItems = conversationIds.length;
  assessments.items.properties.conversationId.enum = conversationIds;
  const memory = schema.properties.memories.items;
  memory.properties.sourceConversationIds.items.enum = conversationIds;
  memory.properties.sourceSegmentIds.items.enum = segmentIds;
  memory.properties.miniMemories.items.properties.sourceSegmentIds.items.enum = segmentIds;
  return schema;
}

function normalizeTemporalReference(value) {
  if (!value) return null;
  if (typeof value === 'string') return new Date(value).toISOString();
  return localDateTimeToUtc(value.localDateTime, value.timezone);
}

function normalizeConsolidationTimestamps(output) {
  for (const memory of output.memories) {
    for (const mini of memory.miniMemories) {
      mini.dueAt = normalizeTemporalReference(mini.dueAt);
      mini.occurredAt = normalizeTemporalReference(mini.occurredAt);
      if (!['task', 'promise'].includes(mini.kind)) mini.status = null;
    }
  }
  return output;
}

module.exports = { consolidationSchema, consolidationJsonSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps };
