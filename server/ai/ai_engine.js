'use strict';

const { provider } = require('./provider_registry');
const { consolidationSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps } = require('./schemas/consolidation_schema');
const { conversationPreviewSchema, conversationPreviewJsonSchema } = require('./schemas/conversation_preview_schema');
const { answerSchema } = require('./schemas/answer_schema');
const { memoryMergeSchema, memoryMergeJsonSchema } = require('./schemas/memory_merge_schema');
const { prepareConsolidationRequest, restoreReferenceIds, carryOverFor } = require('./prompts/consolidate_memories');
const { conversationPreviewMessages } = require('./prompts/preview_conversation');
const { answerMessages } = require('./prompts/answer_question');
const { mergeMemoryMessages } = require('./prompts/merge_memories');
const { inputBudgetCharacters } = require('./context_budget');
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
/// says anything is wrong with the input, and without a retry each one postpones
/// every memory to the next scheduler tick.
///
/// A contract violation is deliberately not in this list. Resending an input the
/// model could not partition reproduces the failure, which is what the narrowing
/// and quarantine policy exists to handle instead.
const TRANSIENT_AI_CODES = Object.freeze([
  'AI_TIMEOUT', 'AI_HTTP_ERROR', 'AI_REQUEST_FAILED', 'AI_EMPTY_RESPONSE', 'AI_PROVIDER_ERROR',
]);

async function withRetries(work) {
  const retries = getConfig().aiMaxRetries;
  let lastError;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await work(attempt);
    } catch (error) {
      lastError = error;
      if (attempt === retries || !TRANSIENT_AI_CODES.includes(error.code)) throw error;
    }
  }
  throw lastError;
}

async function consolidateWindowOnce(userId, window, carryOver) {
  const config = getConfig();
  const response = await provider().chatJSON({
    userId, purpose: 'consolidation', messages: window.messages(carryOver),
    maxTokens: config.aiConsolidationMaxOutputTokens,
    responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_memory_consolidation', strict: true,
      schema: consolidationJsonSchemaFor(window.segmentIds) } },
  });
  const parsed = consolidationSchema.safeParse(response.value);
  if (!parsed.success) {
    markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
    const error = new Error('Consolidation output did not match the required schema.');
    error.code = 'AI_SCHEMA_INVALID'; error.details = parsed.error.flatten(); error.aiRequestId = response.requestId; throw error;
  }
  try {
    return { value: normalizeConsolidationTimestamps(parsed.data), requestId: response.requestId };
  } catch (cause) {
    markValidationFailed(response.requestId, 'AI_TEMPORAL_INVALID');
    const error = new Error(`Consolidation output contained an invalid local date-time: ${cause.message}`);
    error.code = 'AI_TEMPORAL_INVALID'; error.aiRequestId = response.requestId; throw error;
  }
}

/// Folds one window's answer into the answer built from the windows before it.
///
/// The model marks the section it is carrying on from the previous window, and
/// the memory built from that section, with continuesPrevious. Merging is
/// therefore a join rather than a guess: cited segments are appended in order,
/// and the prose written for the wider view replaces the prose written for the
/// narrower one, because the model was asked to describe the whole occasion each
/// time — the same rolling-description contract live previews already use.
///
/// Only the trailing section may be continued, so a claim anywhere else is
/// ignored and becomes a new section. That keeps section coverage contiguous no
/// matter what the model returns.
function mergeWindow(merged, output) {
  const prefix = `w${merged.windowCount + 1}/`;
  const entityRef = (ref) => `${prefix}${ref}`;
  merged.entities.push(...output.entities.map((entity) => ({ ...entity, ref: entityRef(entity.ref) })));

  const memories = output.memories.map((memory) => ({
    ...memory,
    entities: memory.entities.map((item) => ({ ...item, ref: entityRef(item.ref) })),
    miniMemories: memory.miniMemories.map((mini) => ({
      ...mini, entities: mini.entities.map((item) => ({ ...item, ref: entityRef(item.ref) })),
    })),
  }));

  output.conversationSections.forEach((section, index) => {
    const previous = merged.conversationSections.at(-1);
    if (index === 0 && section.continuesPrevious && previous) {
      previous.titleEn = section.titleEn;
      previous.summaryEn = section.summaryEn;
      previous.topics = section.topics;
      previous.memoryWorthy = section.memoryWorthy;
      previous.sourceSegmentIds.push(...section.sourceSegmentIds);
      return;
    }
    merged.conversationSections.push({ ...section, sourceSegmentIds: [...section.sourceSegmentIds] });
  });

  memories.forEach((memory, index) => {
    const previous = merged.memories.at(-1);
    if (index === 0 && memory.continuesPrevious && previous) {
      previous.type = memory.type;
      previous.titleEn = memory.titleEn;
      previous.summaryEn = memory.summaryEn;
      previous.emoji = memory.emoji;
      previous.importance = memory.importance;
      previous.topics = memory.topics;
      previous.sourceSegmentIds.push(...memory.sourceSegmentIds);
      previous.entities.push(...memory.entities);
      previous.miniMemories.push(...memory.miniMemories);
      return;
    }
    merged.memories.push({ ...memory, sourceSegmentIds: [...memory.sourceSegmentIds] });
  });

  if (output.dailySummary) merged.dailySummary = output.dailySummary;
  merged.windowCount += 1;
  return merged;
}

/// Reads one candidate set, in as many passes as the model's context requires.
///
/// A single window is the ordinary case and behaves exactly as one request. A
/// transcript longer than the context is read in order, each pass told what the
/// occasion looked like when the previous pass stopped, and the passes are folded
/// back into one answer — so a four-hour lecture still becomes one section and
/// one memory rather than one per pass.
async function consolidate(userId, input) {
  const config = getConfig();
  // Two separate limits, and the smaller wins: what the context can physically
  // hold, and how much input the configured output budget can afford to answer.
  const windowCharacters = Math.min(
    config.consolidationWindowCharacters,
    inputBudgetCharacters(config.aiConsolidationMaxOutputTokens),
  );
  const prepared = prepareConsolidationRequest(input, windowCharacters);
  const merged = { conversationSections: [], entities: [], memories: [], dailySummary: null, windowCount: 0 };
  let requestId = null;
  for (const window of prepared.windows) {
    const carryOver = merged.windowCount ? carryOverFor(merged) : null;
    const response = await withRetries(() => consolidateWindowOnce(userId, window, carryOver));
    requestId = response.requestId;
    mergeWindow(merged, response.value);
  }
  const { windowCount, ...value } = merged;
  return {
    value: restoreReferenceIds(value, prepared.references),
    requestId,
    windows: windowCount,
    // Alias -> durable speaker cluster id, so a person entity's speakerAlias
    // (still just the string the model was given, e.g. "speaker2") can be
    // resolved to an actual voice after the response comes back.
    speakerClusters: prepared.references.reverseSpeakerAliases,
  };
}

async function previewConversation(userId, { conversation, previousInsight = null, timezone }) {
  const config = getConfig();
  const response = await provider().chatJSON({
    userId, purpose: 'conversation_preview',
    messages: conversationPreviewMessages({ conversation, previousInsight, timezone }),
    maxTokens: config.aiPreviewMaxOutputTokens,
    responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_conversation_preview', strict: true,
      schema: conversationPreviewJsonSchema } },
  });
  const parsed = conversationPreviewSchema.safeParse(response.value);
  if (!parsed.success) {
    markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
    const error = new Error('Conversation preview did not match the required schema.');
    error.code = 'AI_SCHEMA_INVALID'; error.details = parsed.error.flatten(); error.aiRequestId = response.requestId; throw error;
  }
  return { value: parsed.data, requestId: response.requestId };
}

async function answer(userId, question, context, beforeAttempt) {
  return withRetries(async () => {
    if (beforeAttempt) beforeAttempt();
    const response = await provider().chatJSON({ userId, purpose: 'ask', messages: answerMessages(question, context) });
    const parsed = answerSchema.safeParse(response.value);
    if (!parsed.success) {
      markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
      throw Object.assign(new Error('Answer output did not match the required schema.'), { code: 'AI_SCHEMA_INVALID', aiRequestId: response.requestId });
    }
    return { value: parsed.data, requestId: response.requestId };
  });
}

/// Rewrite title/summary/emoji/type for a user-initiated multi-memory merge.
/// Small structured output; uses the preview token budget rather than full
/// consolidation, because the answer is a single card of prose.
async function rewriteMergedMemory(userId, memories) {
  const config = getConfig();
  return withRetries(async () => {
    const response = await provider().chatJSON({
      userId,
      purpose: 'memory_merge',
      messages: mergeMemoryMessages(memories),
      maxTokens: config.aiPreviewMaxOutputTokens,
      responseFormat: {
        type: 'json_schema',
        json_schema: {
          name: 'neorecall_memory_merge',
          strict: true,
          schema: memoryMergeJsonSchema,
        },
      },
    });
    const parsed = memoryMergeSchema.safeParse(response.value);
    if (!parsed.success) {
      markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
      throw Object.assign(new Error('Memory-merge output did not match the required schema.'), {
        code: 'AI_SCHEMA_INVALID',
        details: parsed.error.flatten(),
        aiRequestId: response.requestId,
      });
    }
    return { value: parsed.data, requestId: response.requestId };
  });
}

module.exports = {
  consolidate, previewConversation, answer, rewriteMergedMemory, mergeWindow, TRANSIENT_AI_CODES,
};
