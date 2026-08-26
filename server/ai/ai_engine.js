'use strict';

const { provider } = require('./provider_registry');
const { consolidationSchema, consolidationJsonSchemaFor, normalizeConsolidationTimestamps } = require('./schemas/consolidation_schema');
const { conversationPreviewSchema, conversationPreviewJsonSchema } = require('./schemas/conversation_preview_schema');
const { answerSchema } = require('./schemas/answer_schema');
const { memoryMergeSchema, memoryMergeJsonSchema } = require('./schemas/memory_merge_schema');
const { dailySummarySchema, dailySummaryJsonSchema } = require('./schemas/daily_summary_schema');
const { prepareConsolidationRequest, restoreReferenceIds, carryOverFor } = require('./prompts/consolidate_memories');
const { conversationPreviewMessages } = require('./prompts/preview_conversation');
const { dailySummaryMessages } = require('./prompts/daily_summary');
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
      schema: consolidationJsonSchemaFor(window.segmentIds, window.continuationMemoryIds) } },
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

/// Makes a window's sections cover the window, exactly once, in order.
///
/// The contract asks the model to partition every segment it was given into
/// contiguous sections, and validation rejects a consolidation that omits,
/// duplicates or reorders one. A model does not always comply:
/// measured against a real transcript, one window of thirty-five segments came
/// back with fifteen of them cited and the rest simply missing, which would have
/// thrown the whole run away.
///
/// So the model's partition is honoured where it made one, and completed where
/// it did not. A segment nobody claimed joins the section that owns the segment
/// before it — the conversation it actually adjoins — and a segment two sections
/// both claimed stays with the first. Nothing is invented and no evidence is
/// dropped: every segment ends up in exactly one section, in recording order,
/// which is what makes the result addressable at all. The affected section's
/// summary may not mention the segments that joined it; that is a smaller loss
/// than discarding a correct answer and eventually quarantining the
/// conversation.
function completeCoverage(sections, segmentIds) {
  const owner = new Map();
  sections.forEach((section, index) => {
    for (const id of section.sourceSegmentIds) if (!owner.has(id)) owner.set(id, index);
  });
  let running = null;
  const assigned = segmentIds.map((id) => {
    if (owner.has(id)) running = owner.get(id);
    return running;
  });
  // Segments before the first one anybody claimed have no predecessor to join,
  // so they join the earliest section that claimed anything.
  const firstOwner = assigned.find((value) => value !== null) ?? 0;
  const resolved = assigned.map((value) => (value === null ? firstOwner : value));
  sections.forEach((section, index) => {
    section.sourceSegmentIds = segmentIds.filter((_, position) => resolved[position] === index);
  });
  return sections.filter((section) => section.sourceSegmentIds.length > 0);
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
function mergeWindow(merged, output, segmentIds = null) {
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

  const sections = segmentIds ? completeCoverage(output.conversationSections, segmentIds) : output.conversationSections;
  sections.forEach((section, index) => {
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
      previous.continuesMemoryIds = [...new Set([
        ...previous.continuesMemoryIds,
        ...memory.continuesMemoryIds,
      ])];
      previous.sourceSegmentIds.push(...memory.sourceSegmentIds);
      previous.entities.push(...memory.entities);
      previous.miniMemories.push(...memory.miniMemories);
      return;
    }
    merged.memories.push({ ...memory, sourceSegmentIds: [...memory.sourceSegmentIds] });
  });

  merged.windowCount += 1;
  return merged;
}

/// Writes the day's summary from the finished picture.
///
/// Deliberately its own request. A window only ever sees its own slice, so
/// asking the last one to summarise the day asks it to write about material it
/// was never shown — and when it declined, the missing summary failed the whole
/// run. This reads the memory-worthy sections the run actually produced, which
/// is short input and a short answer.
async function writeDailySummary(userId, { sections, previousDailySummary, timezone }) {
  const config = getConfig();
  return withRetries(async () => {
    const response = await provider().chatJSON({
      userId, purpose: 'consolidation',
      // A long recording is read in many windows and yields many sections, so
      // this grows with the day rather than staying the size of one request.
      messages: dailySummaryMessages({
        sections: contextWithinBudget(sections, inputBudgetCharacters(config.aiPreviewMaxOutputTokens) - 2_000),
        previousDailySummary,
        timezone,
      }),
      maxTokens: config.aiPreviewMaxOutputTokens,
      responseFormat: { type: 'json_schema', json_schema: { name: 'neorecall_daily_summary', strict: true, schema: dailySummaryJsonSchema } },
    });
    const parsed = dailySummarySchema.safeParse(response.value);
    if (!parsed.success) {
      markValidationFailed(response.requestId, 'AI_SCHEMA_INVALID');
      throw Object.assign(new Error('Daily summary output did not match the required schema.'), {
        code: 'AI_SCHEMA_INVALID', details: parsed.error.flatten(), aiRequestId: response.requestId,
      });
    }
    return parsed.data;
  });
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
  const continuationCharacters = JSON.stringify(input.continuationCandidates || []).length;
  // Two separate limits, and the smaller wins: what the context can physically
  // hold, and how much input the configured output budget can afford to answer.
  // Continuation cards ride in every window, so their exact size is reserved
  // before the remaining budget is spent on transcript segments.
  const windowCharacters = Math.min(
    config.consolidationWindowCharacters,
    Math.max(1, inputBudgetCharacters(config.aiConsolidationMaxOutputTokens) - continuationCharacters),
  );
  const prepared = prepareConsolidationRequest(input, windowCharacters);
  const merged = { conversationSections: [], entities: [], memories: [], dailySummary: null, windowCount: 0 };
  let requestId = null;
  for (const window of prepared.windows) {
    const carryOver = merged.windowCount ? carryOverFor(merged) : null;
    const response = await withRetries(() => consolidateWindowOnce(userId, window, carryOver));
    requestId = response.requestId;
    mergeWindow(merged, response.value, window.segmentIds);
  }
  const worthySections = merged.conversationSections.filter((section) => section.memoryWorthy);
  merged.dailySummary = worthySections.length
    ? await writeDailySummary(userId, { sections: worthySections, previousDailySummary: input.previousDailySummary, timezone: input.timezone })
    : null;
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

/// Trims retrieved context to what the model can actually read.
///
/// Search returns its results best-first, so dropping from the end drops the
/// least relevant evidence — which is the right thing to lose when something has
/// to go. Without this the prompt is whatever sixteen results happen to weigh:
/// a handful of long memories and daily summaries can exceed a modest context on
/// their own, and the request is then rejected outright rather than answered
/// from slightly less evidence.
function contextWithinBudget(context, budgetCharacters) {
  const kept = [];
  let used = 0;
  for (const item of context) {
    const size = JSON.stringify(item).length;
    if (kept.length && used + size > budgetCharacters) break;
    kept.push(item);
    used += size;
  }
  return kept;
}

async function answer(userId, question, context, beforeAttempt) {
  const config = getConfig();
  // The question and the instructions ride along with the evidence, so they come
  // out of the same budget before it is spent.
  const budget = inputBudgetCharacters(config.aiPreviewMaxOutputTokens) - String(question || '').length - 1_000;
  const bounded = contextWithinBudget(context, Math.max(1_000, budget));
  return withRetries(async () => {
    if (beforeAttempt) beforeAttempt();
    const response = await provider().chatJSON({
      userId, purpose: 'ask', maxTokens: config.aiPreviewMaxOutputTokens, messages: answerMessages(question, bounded),
    });
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
  consolidate, previewConversation, answer, rewriteMergedMemory, writeDailySummary, mergeWindow, completeCoverage, contextWithinBudget, TRANSIENT_AI_CODES,
};
