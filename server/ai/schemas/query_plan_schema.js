'use strict';

const { z } = require('zod');
const { DOCUMENT_KINDS } = require('../../services/search/document_kinds');

const LOCAL_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/;
const localDateTime = z.union([z.string().regex(LOCAL_DATE_TIME), z.null()]).default(null);

const queryPlanSchema = z.object({
  searchQueries: z.array(z.string().trim().min(1)).min(1).max(8),
  fromLocal: localDateTime,
  toLocal: localDateTime,
  kinds: z.array(z.enum(DOCUMENT_KINDS)).default([]),
  // True when the question is about a stretch of time as a whole rather than
  // about a topic inside it — "what did I do today" wants the day, not the
  // documents that happen to resemble the words "do" and "today".
  wholePeriod: z.boolean().default(false),
});

const queryPlanJsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['searchQueries', 'fromLocal', 'toLocal', 'kinds', 'wholePeriod'],
  properties: {
    searchQueries: { type: 'array', minItems: 1, maxItems: 8, items: { type: 'string' } },
    fromLocal: { type: ['string', 'null'] },
    toLocal: { type: ['string', 'null'] },
    kinds: { type: 'array', items: { type: 'string', enum: [...DOCUMENT_KINDS] } },
    wholePeriod: { type: 'boolean' },
  },
};

module.exports = { queryPlanSchema, queryPlanJsonSchema };
