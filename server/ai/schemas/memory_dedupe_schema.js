'use strict';

const { z } = require('zod');

const REASONING_MAX = 400;

const memoryDedupeSchema = z.object({
  reasoning: z.string().min(1).max(REASONING_MAX),
  sameOccasion: z.boolean(),
});

const memoryDedupeJsonSchema = {
  type: 'object',
  additionalProperties: false,
  // Reasoning first, deliberately: the model writes the evidence before it
  // commits to an answer, rather than justifying one it has already given.
  required: ['reasoning', 'sameOccasion'],
  properties: {
    reasoning: { type: 'string', minLength: 1, maxLength: REASONING_MAX },
    sameOccasion: { type: 'boolean' },
  },
};

module.exports = { memoryDedupeSchema, memoryDedupeJsonSchema, REASONING_MAX };
