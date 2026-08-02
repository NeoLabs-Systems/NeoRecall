'use strict';

const { z } = require('zod');
const { MEMORY_TYPES } = require('./consolidation_schema');

const TITLE_MAX = 160;
const SUMMARY_MAX = 2_000;
const EMOJI_MAX = 16;

const memoryMergeSchema = z.object({
  type: z.enum(MEMORY_TYPES),
  titleEn: z.string().min(1).max(TITLE_MAX),
  summaryEn: z.string().min(1).max(SUMMARY_MAX),
  emoji: z.string().min(1).max(EMOJI_MAX),
});

const memoryMergeJsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['type', 'titleEn', 'summaryEn', 'emoji'],
  properties: {
    type: { type: 'string', enum: [...MEMORY_TYPES] },
    titleEn: { type: 'string', minLength: 1, maxLength: TITLE_MAX },
    summaryEn: { type: 'string', minLength: 1, maxLength: SUMMARY_MAX },
    emoji: { type: 'string', minLength: 1, maxLength: EMOJI_MAX },
  },
};

module.exports = {
  memoryMergeSchema,
  memoryMergeJsonSchema,
  TITLE_MAX,
  SUMMARY_MAX,
  EMOJI_MAX,
};
