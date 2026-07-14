'use strict';

const { z } = require('zod');
const answerSchema = z.object({
  answer: z.string().min(1),
  citations: z.array(z.object({ sourceId: z.string().min(1) })).default([]),
});
module.exports = { answerSchema };
