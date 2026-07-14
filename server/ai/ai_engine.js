'use strict';

const { provider } = require('./provider_registry');
const { consolidationSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps } = require('./schemas/consolidation_schema');
const { answerSchema } = require('./schemas/answer_schema');
const { prepareConsolidationRequest, restoreReferenceIds } = require('./prompts/consolidate_memories');
const { answerMessages } = require('./prompts/answer_question');
const { getConfig } = require('../config');
const { getDatabase } = require('../db/database');

function markValidationFailed(requestId, code) {
  getDatabase().prepare("UPDATE ai_requests SET state='failed',error_code=? WHERE id=?").run(code, requestId);
}

async function consolidate(userId, input) {
  const prepared = prepareConsolidationRequest(input);
  const conversationIds = [...prepared.references.reverseConversationAliases.keys()];
  const segmentIds = [...prepared.references.reverseSegmentAliases.keys()];
  const response = await provider().chatJSON({
    userId, purpose: 'consolidation', model: getConfig().aiDefaultModel, messages: prepared.messages,
    responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_memory_consolidation', strict: true,
      schema: consolidationJsonSchemaFor(conversationIds, segmentIds) } },
  });
  const parsed = consolidationSchema.safeParse(response.value);
  if (!parsed.success) {
    markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
    const error = new Error('OpenRouter consolidation output did not match the required schema.');
    error.code = 'AI_SCHEMA_INVALID'; error.details = parsed.error.flatten(); error.aiRequestId = response.requestId; throw error;
  }
  try {
    return { value: restoreReferenceIds(normalizeConsolidationTimestamps(parsed.data), prepared.references), requestId: response.requestId };
  } catch (cause) {
    markValidationFailed(response.requestId, 'AI_TEMPORAL_INVALID');
    const error = new Error(`OpenRouter consolidation output contained an invalid local date-time: ${cause.message}`);
    error.code = 'AI_TEMPORAL_INVALID'; error.aiRequestId = response.requestId; throw error;
  }
}

async function answer(userId, question, context, beforeAttempt) {
  const retries = getConfig().aiMaxRetries;
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    if (beforeAttempt) beforeAttempt();
    try {
      const response = await provider().chatJSON({ userId, purpose: 'ask', model: getConfig().aiDefaultModel, messages: answerMessages(question, context) });
      const parsed = answerSchema.safeParse(response.value);
      if (!parsed.success) {
        markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
        throw Object.assign(new Error('OpenRouter answer output did not match the required schema.'), { code: 'AI_SCHEMA_INVALID', aiRequestId: response.requestId });
      }
      return { value: parsed.data, requestId: response.requestId };
    } catch (error) {
      lastError = error;
      if (attempt === retries || !['AI_TIMEOUT', 'AI_HTTP_ERROR', 'AI_REQUEST_FAILED'].includes(error.code)) throw error;
    }
  }
  throw lastError;
}

module.exports = { consolidate, answer };
