'use strict';

const { z } = require('zod');

// The day's cumulative summary, written as its own small request.
//
// It carries prose and nothing else. Which local date it covers and which
// timezone that date is in are facts the server already knows from the
// conversations it selected, so asking a model to restate them only creates a
// way for the answer to disagree with the evidence — which used to fail the
// whole consolidation. The model writes the sentence; the server writes the
// date.
const dailySummarySchema = z.object({
  summaryEn: z.string().min(1),
});

const dailySummaryJsonSchema = {
  type: 'object', additionalProperties: false, required: ['summaryEn'],
  properties: { summaryEn: { type: 'string', minLength: 1 } },
};

module.exports = { dailySummarySchema, dailySummaryJsonSchema };
