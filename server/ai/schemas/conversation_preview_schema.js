'use strict';

const { z } = require('zod');
const {
  conversationInsightFields,
  conversationInsightJsonProperties,
  conversationInsightRequired,
} = require('./consolidation_schema');

// A preview is the conversation insight consolidation would produce, minus the
// evidence partitioning: the conversation is still recording, so there is no
// stable segment partition to address and no memory to anchor yet. Sharing the
// field definitions keeps a provisional title and a final title interchangeable
// wherever NeoRecall renders one.
const conversationPreviewSchema = z.object(conversationInsightFields).strict();

const conversationPreviewJsonSchema = {
  type: 'object',
  additionalProperties: false,
  required: [...conversationInsightRequired],
  properties: { ...conversationInsightJsonProperties },
};

module.exports = { conversationPreviewSchema, conversationPreviewJsonSchema };
