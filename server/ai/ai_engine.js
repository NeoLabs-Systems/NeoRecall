'use strict';

const { provider } = require('./provider_registry');
const { consolidationSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps } = require('./schemas/consolidation_schema');
const { conversationPreviewSchema, conversationPreviewJsonSchema } = require('./schemas/conversation_preview_schema');
const { answerSchema } = require('./schemas/answer_schema');
const { prepareConsolidationRequest, restoreReferenceIds } = require('./prompts/consolidate_memories');
const { conversationPreviewMessages } = require('./prompts/preview_conversation');
const { answerMessages } = require('./prompts/answer_question');
const { getConfig } = require('../config');
const { getDatabase } = require('../db/database');

function markValidationFailed(requestId, code) {
  getDatabase().prepare("UPDATE ai_requests SET state='failed',error_code=? WHERE id=?").run(code, requestId);
}

/// Failures that a fresh sample of the same request may simply not repeat.
///
/// Measured against a live model over three hours of real audio: two of seven
/// consolidation requests failed on the first attempt, once with no message
/// content at all and once with a completion that ran out of budget. Neither
/// says anything is wrong with the input, and without a retry each one costs a
/// paid request and postpones every memory to the next scheduler tick.
///
/// A contract violation is deliberately not in this list. Resending an input the
/// model could not partition reproduces the failure, which is what the narrowing
/// and quarantine policy exists to handle instead.
const TRANSIENT_AI_CODES = Object.freeze([
  'AI_TIMEOUT', 'AI_HTTP_ERROR', 'AI_REQUEST_FAILED', 'AI_EMPTY_RESPONSE', 'AI_PROVIDER_ERROR',
]);

async function consolidateOnce(userId, prepared, segmentIds) {
  const config = getConfig();
  const response = await provider().chatJSON({
    userId, purpose: 'consolidation', model: config.aiDefaultModel, messages: prepared.messages,
    maxTokens: config.aiConsolidationMaxOutputTokens,
    responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_memory_consolidation', strict: true,
      schema: consolidationJsonSchemaFor(segmentIds) } },
  });
  const parsed = consolidationSchema.safeParse(response.value);
  if (!parsed.success) {
    markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
    const error = new Error('OpenRouter consolidation output did not match the required schema.');
    error.code = 'AI_SCHEMA_INVALID'; error.details = parsed.error.flatten(); error.aiRequestId = response.requestId; throw error;
  }
  try {
    return {
      value: restoreReferenceIds(normalizeConsolidationTimestamps(parsed.data), prepared.references),
      requestId: response.requestId,
      // Alias -> durable speaker cluster id, so a person entity's speakerAlias
      // (still just the string the model was given, e.g. "speaker2") can be
      // resolved to an actual voice after the response comes back.
      speakerClusters: prepared.references.reverseSpeakerAliases,
    };
  } catch (cause) {
    markValidationFailed(response.requestId, 'AI_TEMPORAL_INVALID');
    const error = new Error(`OpenRouter consolidation output contained an invalid local date-time: ${cause.message}`);
    error.code = 'AI_TEMPORAL_INVALID'; error.aiRequestId = response.requestId; throw error;
  }
}

async function consolidate(userId, input) {
  const prepared = prepareConsolidationRequest(input);
  const segmentIds = [...prepared.references.reverseSegmentAliases.keys()];
  const retries = getConfig().aiMaxRetries;
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await consolidateOnce(userId, prepared, segmentIds);
    } catch (error) {
      lastError = error;
      if (attempt === retries || !TRANSIENT_AI_CODES.includes(error.code)) throw error;
    }
  }
  throw lastError;
}

async function previewConversation(userId, { conversation, previousInsight = null, timezone }) {
  const config = getConfig();
  const response = await provider().chatJSON({
    userId, purpose: 'conversation_preview', model: config.aiPreviewModel,
    messages: conversationPreviewMessages({ conversation, previousInsight, timezone }),
    maxTokens: config.aiPreviewMaxOutputTokens,
    responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_conversation_preview', strict: true,
      schema: conversationPreviewJsonSchema } },
  });
  const parsed = conversationPreviewSchema.safeParse(response.value);
  if (!parsed.success) {
    markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
    const error = new Error('OpenRouter conversation preview did not match the required schema.');
    error.code = 'AI_SCHEMA_INVALID'; error.details = parsed.error.flatten(); error.aiRequestId = response.requestId; throw error;
  }
  return { value: parsed.data, requestId: response.requestId };
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
      if (attempt === retries || !TRANSIENT_AI_CODES.includes(error.code)) throw error;
    }
  }
  throw lastError;
}

module.exports = { consolidate, previewConversation, answer, TRANSIENT_AI_CODES };
