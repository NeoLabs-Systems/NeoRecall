'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const processingSettings = require('../settings/processing_settings_service');
const jobs = require('../jobs/job_service');
const settings = require('../settings/settings_service');
const ai = require('../../ai/ai_engine');
const material = require('./conversation_material_service');

// Live insight for a conversation consolidation will not describe.
//
// A device can stay on all day, so a user must be able to open a conversation
// that has not finished and see what it is. Consolidation cannot answer that: it
// only runs on finished conversations, because a memory anchored to a transcript
// that is still growing would have to be revised or duplicated later. A preview
// therefore writes the same title, summary and topics consolidation writes, but
// marked provisional, and creates no memories. When the conversation finally
// closes, consolidation overwrites the insight and marks it final — so a
// three-hour lecture is visible after a few minutes and still becomes exactly
// one memory.
//
// The same path also rescues a quarantined conversation. Quarantine means
// consolidation gave up on partitioning it, which would otherwise leave an
// unlabelled transcript in the timeline forever. A preview has no partitioning
// constraint to fail, so it can still say what the conversation was.

const PROVISIONAL = 'provisional';
const FINAL = 'final';
const PREVIEWABLE_STATES = Object.freeze(['open', 'closed']);

function thresholds() {
  const config = getConfig();
  const processing = processingSettings.get();
  return {
    minimumCharacters: processing.conversationPreviewMinCharacters,
    minimumAudioMs: processing.minAiAudioMs,
    refreshCharacters: processing.conversationPreviewRefreshCharacters,
    minimumIntervalMs: processing.conversationPreviewMinIntervalMs,
    fullCharacters: processing.conversationPreviewFullCharacters,
    enabled: Boolean(config.openRouterApiKey && config.aiPreviewModel),
  };
}

/// Whether a conversation is one previews are responsible for.
///
/// An open conversation is still growing and consolidation has not seen it yet.
/// A quarantined one is closed but consolidation has permanently given up on it.
/// Everything else either already has a final insight or is about to get one.
function previewOwns(conversation) {
  if (conversation.state === 'open') return true;
  return conversation.state === 'closed' && Boolean(conversation.quarantined_at);
}

/// Whether this conversation is worth spending a preview request on right now.
///
/// The first preview needs enough transcript to describe, every later one needs
/// enough *new* transcript to be worth re-describing, and two previews of the
/// same conversation stay a minimum interval apart. On an uninterrupted stream
/// those bounds are what keep preview cost proportional to new speech rather
/// than to elapsed time.
///
/// The interval is measured from the last *attempt*, not the last success.
/// Measuring successes would leave a conversation whose previews keep failing
/// permanently due, and the scheduler would spend a request a minute on it.
function previewDue(conversation, characters, limits, now = Date.now()) {
  if (conversation.insight_state === FINAL) return false;
  // A short recording never reaches a model at all, however dense its speech.
  if (material.durationMs(conversation) < limits.minimumAudioMs) return false;
  if (characters < limits.minimumCharacters) return false;
  const attemptedAt = conversation.insight_attempted_at || conversation.insight_updated_at;
  if (attemptedAt && now - Date.parse(attemptedAt) < limits.minimumIntervalMs) return false;
  if (conversation.insight_state !== PROVISIONAL) return true;
  return characters - conversation.insight_characters >= limits.refreshCharacters;
}

function due(userId, database = getDatabase()) {
  const limits = thresholds();
  if (!limits.enabled) return [];
  const now = Date.now();
  return material.listByState(userId, PREVIEWABLE_STATES, database, { includeQuarantined: true })
    .filter(previewOwns)
    .map((conversation) => ({ conversation, characters: material.transcriptCharacters(userId, conversation.id, database) }))
    .filter(({ conversation, characters }) => previewDue(conversation, characters, limits, now))
    .filter(({ conversation }) => material.isComplete(userId, conversation.id, database));
}

/// Queues a preview for every conversation that is due one.
///
/// Enqueueing is idempotent per conversation: the job table rejects a second
/// active job for the same resource, so a scheduler tick during a running
/// preview adds nothing.
function request(userId, database = getDatabase()) {
  const queued = [];
  for (const { conversation } of due(userId, database)) {
    jobs.enqueue({
      userId,
      resourceType: 'conversation',
      resourceId: conversation.id,
      type: 'preview_conversation',
      priority: 40,
    }, database);
    queued.push(conversation.id);
  }
  return { queued };
}

/// Chooses what to send for this refresh.
///
/// Below the full-read threshold the whole transcript goes out, which is exact.
/// Above it, only the speech recorded since the last preview goes out together
/// with the description written then, so the request stays the same size no
/// matter how long the conversation has been running. A conversation that was
/// split by boundary detection can end up not containing the text its previous
/// preview described; that is detected here and falls back to a full read.
function previewInput(userId, conversation, limits, database = getDatabase()) {
  const all = material.material(userId, conversation, database);
  const rolling = conversation.insight_state === PROVISIONAL
    && conversation.insight_covered_through
    && conversation.title_en
    && conversation.summary_en
    && all.characters > limits.fullCharacters;
  if (!rolling) return { conversation: all, previousInsight: null, characters: all.characters };
  const fresh = material.segmentsAfter(userId, conversation.id, conversation.insight_covered_through, database);
  if (!fresh.length || fresh.length === all.segments.length) {
    return { conversation: all, previousInsight: null, characters: all.characters };
  }
  let topics = [];
  try { topics = JSON.parse(conversation.topics_json || '[]'); } catch { topics = []; }
  return {
    conversation: { ...all, segments: fresh },
    previousInsight: { titleEn: conversation.title_en, summaryEn: conversation.summary_en, topics },
    characters: all.characters,
  };
}

/// Records that a request is about to go out, before it does.
///
/// Committed on its own so a request that never returns still counts as an
/// attempt; otherwise a failing preview would be due again on the next tick.
function markAttempted(userId, conversationId, database = getDatabase()) {
  database.prepare(`UPDATE conversations SET insight_attempted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id=? AND user_id=?`).run(conversationId, userId);
}

function persist(userId, conversationId, preview, { characters, coveredThrough, aiRequestId }, database = getDatabase()) {
  return database.transaction(() => {
    // A preview may land after consolidation refined the same conversation, and
    // a provisional insight must never replace a final one. Refinement can also
    // have replaced this conversation entirely, in which case the row is gone
    // and the update is a no-op.
    const changes = database.prepare(`UPDATE conversations SET title_en=?,summary_en=?,topics_json=?,memory_worthy=?,
      insight_state=?,insight_characters=?,insight_covered_through=?,insight_request_id=?,
      insight_updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE id=? AND user_id=? AND insight_state<>?`)
      .run(preview.titleEn, preview.summaryEn, JSON.stringify(preview.topics), Number(preview.memoryWorthy),
        PROVISIONAL, characters, coveredThrough, aiRequestId || null, conversationId, userId, FINAL).changes;
    if (!changes) return { superseded: true };
    database.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
      VALUES (?,'conversation.insight','conversation',?,?,?)`).run(userId, conversationId, JSON.stringify({
      conversationId, insightState: PROVISIONAL, titleEn: preview.titleEn, memoryWorthy: preview.memoryWorthy,
    }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
    return { superseded: false };
  })();
}

async function execute(userId, conversationId) {
  const database = getDatabase();
  const limits = thresholds();
  if (!limits.enabled) return { skipped: 'ai_not_configured' };
  const conversation = material.findInState(userId, conversationId, PREVIEWABLE_STATES, database, { includeQuarantined: true });
  // Consolidated or refined away between queueing and execution: the final pass
  // owns the insight from here on, so there is nothing left to preview.
  if (!conversation || !previewOwns(conversation)) return { skipped: 'not_previewable' };
  // Re-checked here because the queue is not the authority: the conversation may
  // have been previewed, split or extended since the job was created.
  if (!previewDue(conversation, material.transcriptCharacters(userId, conversationId, database), limits)) return { skipped: 'not_due' };
  if (!material.isComplete(userId, conversationId, database)) return { skipped: 'incomplete' };
  const input = previewInput(userId, conversation, limits, database);
  const coveredThrough = input.conversation.segments.at(-1)?.ended_at || conversation.ended_at;
  markAttempted(userId, conversationId, database);
  const response = await ai.previewConversation(userId, {
    conversation: input.conversation,
    previousInsight: input.previousInsight,
    timezone: settings.get(userId).timezone,
  });
  return {
    conversationId,
    rolling: Boolean(input.previousInsight),
    ...persist(userId, conversationId, response.value, {
      characters: input.characters, coveredThrough, aiRequestId: response.requestId,
    }, database),
  };
}

module.exports = {
  due, request, execute, persist, thresholds, previewDue, previewOwns, previewInput, PROVISIONAL, FINAL,
};
