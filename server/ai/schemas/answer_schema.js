'use strict';

const { z } = require('zod');
const answerSchema = z.object({
  answer: z.string().min(1),
  citations: z.array(z.object({ sourceId: z.string().min(1) })).default([]),
});

const answerJsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['answer', 'citations'],
  properties: {
    answer: { type: 'string', minLength: 1 },
    citations: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['sourceId'],
        properties: { sourceId: { type: 'string', minLength: 1 } },
      },
    },
  },
};

module.exports = { answerSchema, answerJsonSchema };
