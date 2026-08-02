'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const settings = require('../settings/settings_service');
const processingSettings = require('../settings/processing_settings_service');
const jobs = require('../jobs/job_service');
const ai = require('../../ai/ai_engine');
const searchIndex = require('../../embeddings/search_index_service');
const refinement = require('../conversations/conversation_refinement_service');
const material = require('../conversations/conversation_material_service');
const speakerIdentity = require('../speakers/speaker_identity_service');

// Failures that mean the model could not produce a valid answer for this exact
// input. Resending the same conversations reproduces them, so they drive the
// narrowing and quarantine policy below; transport failures never do.
//
// A truncated completion belongs here even though nothing was wrong with the
// model's reasoning: it means the answer this input demands did not fit in the
// budget, and carrying fewer conversations next time is exactly the right
// response. If a single conversation still cannot fit, quarantine eventually
// stops the bleeding and the operator raises AI_CONSOLIDATION_MAX_OUTPUT_TOKENS.
const VALIDATION_FAILURE_CODES = Object.freeze([
  'AI_REFERENCE_INVALID', 'AI_SCHEMA_INVALID', 'AI_TEMPORAL_INVALID', 'AI_OUTPUT_TRUNCATED',
]);

function localDate(iso, timezone) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date(iso));
  const byType = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${byType.year}-${byType.month}-${byType.day}`;
}

function lastOutbound(userId) {
  return getDatabase().prepare("SELECT sent_at FROM ai_requests WHERE user_id=? AND purpose='consolidation' AND sent_at IS NOT NULL ORDER BY sent_at DESC LIMIT 1").get(userId);
}

function candidateConversations(userId) {
  return material.listByState(userId, ['closed'])
    .filter((conversation) => material.isComplete(userId, conversation.id));
}

/// True when the most recent consolidation could not be validated.
///
/// Candidates are always taken oldest-first, so a conversation the model cannot
/// partition would otherwise reappear in every later run and stop memory
/// generation for good. After such a failure the next run carries a single
/// conversation, which both isolates the cause and stops a whole batch from
/// being blamed for one bad member.
function narrowingAfterFailure(userId) {
  const previous = getDatabase().prepare('SELECT state,error_code FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT 1').get(userId);
  return Boolean(previous && previous.state === 'failed' && VALIDATION_FAILURE_CODES.includes(previous.error_code));
}

function buildCandidates(userId) {
  const { maxConsolidationInputChars: maxCharacters, maxConsolidationConversations: maxCount } = processingSettings.get();
  const narrowed = narrowingAfterFailure(userId);
  const output = [];
  let characters = 0;
  for (const conversation of candidateConversations(userId)) {
    if (output.length && (narrowed || output.length >= maxCount)) break;
    const candidate = material.material(userId, conversation);
    if (output.length && characters + candidate.characters > maxCharacters) break;
    const { characters: size, ...rest } = candidate;
    output.push(rest);
    characters += size;
  }
  const audioMs = output.reduce((sum, conversation) => sum + material.durationMs(conversation), 0);
  return { conversations: output, characters, audioMs, narrowed };
}

function eligibility(userId) {
  const config = getConfig();
  const processingConfig = processingSettings.get();
  if (!config.openRouterApiKey || !config.aiDefaultModel) return { eligible: false, reason: 'openrouter_not_configured' };
  const active = getDatabase().prepare("SELECT id FROM consolidation_runs WHERE user_id=? AND state IN ('reserved','running')").get(userId);
  if (active) return { eligible: false, reason: 'already_running', runId: active.id };
  const interval = Math.max(settings.get(userId).consolidationIntervalMs, config.minConsolidationIntervalMs);
  const previous = lastOutbound(userId);
  const nextEligibleAt = previous ? new Date(Date.parse(previous.sent_at) + interval).toISOString() : new Date(0).toISOString();
  if (Date.parse(nextEligibleAt) > Date.now()) return { eligible: false, reason: 'interval', nextEligibleAt };
  const candidates = buildCandidates(userId);
  if (!candidates.conversations.length) {
    return { eligible: false, reason: 'insufficient_material', materialCharacters: 0, requiredCharacters: processingConfig.minNewMaterialChars };
  }
  // A hard floor on what may cause a request. Everything below it — including
  // the waiting-material sweep further down, which exists precisely to
  // consolidate material that never reaches the character threshold — stops
  // here, so a one-minute recording never reaches a model. Once longer material
  // does justify a request, the short conversations still in the candidate set
  // are carried along at no extra cost.
  if (candidates.audioMs < processingConfig.minAiAudioMs) {
    return { eligible: false, reason: 'insufficient_audio', materialAudioMs: candidates.audioMs, requiredAudioMs: processingConfig.minAiAudioMs };
  }
  // The character threshold exists so trivial material does not pay for a
  // request, but on its own it can strand a short conversation indefinitely: a
  // ten-minute call at the end of a day would stay a transcript with no memory
  // until unrelated speech happened to arrive. Waiting material is therefore
  // consolidated anyway once it has waited long enough.
  if (candidates.characters < processingConfig.minNewMaterialChars) {
    const waitingSince = Date.parse(candidates.conversations[0].endedAt);
    const consolidateAfter = new Date(waitingSince + processingConfig.maxConsolidationLatencyMs).toISOString();
    if (Date.now() < Date.parse(consolidateAfter)) {
      return { eligible: false, reason: 'insufficient_material', materialCharacters: candidates.characters,
        requiredCharacters: processingConfig.minNewMaterialChars, consolidateAfter };
    }
  }
  return { eligible: true, nextEligibleAt, ...candidates };
}

/// Records that a consolidation could not be validated.
///
/// Only the conversations the run actually carried are charged, and a
/// conversation that reaches the configured limit is quarantined: it keeps its
/// transcript and stays readable, but it no longer enters candidate sets, so one
/// unpartitionable conversation cannot stop every later memory.
function recordValidationFailure(userId, conversationIds, errorCode) {
  if (!conversationIds.length) return { quarantined: [] };
  const db = getDatabase();
  const limit = processingSettings.get().consolidationMaxFailures;
  return db.transaction(() => {
    const quarantined = [];
    for (const conversationId of conversationIds) {
      const row = db.prepare(`UPDATE conversations SET consolidation_failures=consolidation_failures+1,
        updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=? AND state='closed'
        RETURNING consolidation_failures`).get(conversationId, userId);
      if (!row || row.consolidation_failures < limit) continue;
      db.prepare(`UPDATE conversations SET quarantined_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),quarantine_reason=?
        WHERE id=? AND user_id=?`).run(errorCode, conversationId, userId);
      quarantined.push(conversationId);
    }
    if (quarantined.length) {
      db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
        VALUES (?,'consolidation.quarantined','user',?,?,?)`).run(userId, userId,
        JSON.stringify({ conversationIds: quarantined, errorCode }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
    }
    return { quarantined };
  })();
}

function request(userId, { manual = false } = {}) {
  const state = eligibility(userId);
  if (!state.eligible) {
    if (manual && state.reason === 'interval') {
      const retryAfterSeconds = Math.max(1, Math.ceil((Date.parse(state.nextEligibleAt) - Date.now()) / 1000));
      throw new HttpError(429, 'CONSOLIDATION_INTERVAL', 'The consolidation interval has not elapsed.', { retryAfterSeconds, nextEligibleAt: state.nextEligibleAt });
    }
    if (manual && state.reason === 'openrouter_not_configured') throw new HttpError(503, 'AI_NOT_CONFIGURED', 'OpenRouter and AI_DEFAULT_MODEL must be configured.');
    return state;
  }
  const id = crypto.randomUUID();
  const first = state.conversations[0];
  const last = state.conversations.at(-1);
  const db = getDatabase();
  db.transaction(() => {
    db.prepare(`INSERT INTO consolidation_runs
      (id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at)
      VALUES (?,?,?,?,?,?,'reserved',?)`).run(id, userId, first.startedAt, last.endedAt, state.characters, state.conversations.length, new Date().toISOString());
    jobs.enqueue({ userId, resourceType: 'consolidation_run', resourceId: id, type: 'consolidate_memories', priority: manual ? 80 : 20,
      payload: { runId: id, conversationIds: state.conversations.map((conversation) => conversation.id) }, maxAttempts: 1 }, db);
  })();
  return { eligible: true, queued: true, runId: id };
}

function normalizeIdentity(value) {
  return value.normalize('NFKC').trim().toLocaleLowerCase('en-US').replace(/\s+/g, ' ');
}

function validateReferences(output, conversations) {
  const segmentIds = new Set(conversations.flatMap((conversation) => conversation.segments.map((segment) => segment.id)));
  refinement.validateConversationSections(output.conversationSections, conversations);
  const worthySegmentIds = new Set(output.conversationSections
    .filter((section) => section.memoryWorthy)
    .flatMap((section) => section.sourceSegmentIds));
  const entityRefs = new Set(output.entities.map((entity) => entity.ref));
  for (const memory of output.memories) {
    if (memory.sourceSegmentIds.some((id) => !segmentIds.has(id) || !worthySegmentIds.has(id))) {
      throw Object.assign(new Error('A memory cited a source outside a memory-worthy conversation section.'), { code: 'AI_REFERENCE_INVALID' });
    }
    if (memory.entities.some((item) => !entityRefs.has(item.ref))) throw Object.assign(new Error('A memory cited an undefined entity.'), { code: 'AI_REFERENCE_INVALID' });
    for (const mini of memory.miniMemories) {
      if (mini.sourceSegmentIds.some((id) => !segmentIds.has(id) || !worthySegmentIds.has(id))
        || mini.entities.some((item) => !entityRefs.has(item.ref))) {
        throw Object.assign(new Error('A mini-memory cited an invalid or non-memory-worthy source.'), { code: 'AI_REFERENCE_INVALID' });
      }
    }
  }
}

function anchorMemoryRanges(output, conversations) {
  const segments = new Map(conversations.flatMap((conversation) => conversation.segments.map((segment) => [segment.id, segment])));
  for (const memory of output.memories) {
    const evidence = memory.sourceSegmentIds.map((id) => segments.get(id)).filter(Boolean);
    memory.startedAt = evidence.reduce((earliest, segment) => !earliest || Date.parse(segment.started_at) < Date.parse(earliest) ? segment.started_at : earliest, null);
    memory.endedAt = evidence.reduce((latest, segment) => !latest || Date.parse(segment.ended_at) > Date.parse(latest) ? segment.ended_at : latest, null);
  }
  return output;
}

function persist(userId, runId, output, conversations, aiRequestId, speakerClusters = new Map()) {
  validateReferences(output, conversations);
  anchorMemoryRanges(output, conversations);
  const db = getDatabase();
  const userSettings = settings.get(userId);
  const hasWorthySections = output.conversationSections.some((section) => section.memoryWorthy);
  if (!hasWorthySections) output.dailySummary = null;
  if (hasWorthySections && !output.dailySummary) {
    throw Object.assign(new Error('Memory-worthy material requires a daily summary update.'), { code: 'AI_REFERENCE_INVALID' });
  }
  const entityIds = new Map();
  db.transaction(() => {
    const refined = refinement.applyConversationSections(
      db,
      userId,
      runId,
      output.conversationSections,
      conversations,
    );
    const worthyConversations = refined.conversations.filter((conversation) => conversation.memoryWorthy);
    for (const entity of output.entities) {
      const identity = normalizeIdentity(entity.canonicalNameEn);
      let row = db.prepare('SELECT id FROM entities WHERE user_id=? AND kind=? AND normalized_identity_key=?').get(userId, entity.kind, identity);
      if (!row) {
        const id = crypto.randomUUID();
        db.prepare(`INSERT INTO entities (id,user_id,kind,canonical_name_en,display_name,normalized_identity_key) VALUES (?,?,?,?,?,?)`)
          .run(id, userId, entity.kind, entity.canonicalNameEn, entity.displayName || null, identity);
        row = { id };
      }
      entityIds.set(entity.ref, row.id);
      const aliasInsert = db.prepare('INSERT OR IGNORE INTO entity_aliases (entity_id,alias,language) VALUES (?,?,?)');
      for (const alias of entity.aliases) aliasInsert.run(row.id, alias.value, alias.language || null);
    }
    // Best-effort: names a voiceprint from the same response that just built the
    // entity graph, at no extra AI cost. Never throws — an unresolved alias or a
    // cluster with no voiceprint yet is simply skipped.
    speakerIdentity.linkEntitiesToSpeakers(db, userId, output.entities, entityIds, speakerClusters);
    for (const memory of output.memories) {
      const publicId = crypto.randomUUID();
      const result = db.prepare(`INSERT INTO memories
        (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
        VALUES (?,?,?,?,?,?,?,?,?,?)`).run(publicId, userId, memory.type, memory.titleEn, memory.summaryEn,
        memory.emoji, memory.importance, memory.startedAt, memory.endedAt, runId);
      const memoryId = Number(result.lastInsertRowid);
      const sourceInsert = db.prepare('INSERT OR IGNORE INTO memory_sources (memory_id,conversation_id,segment_id) VALUES (?,?,?)');
      const sourceConversationIds = [...new Set(memory.sourceSegmentIds.map(
        (segmentPublicId) => refined.segmentConversationIds.get(segmentPublicId),
      ))];
      for (const conversationId of sourceConversationIds) sourceInsert.run(memoryId, conversationId, null);
      for (const segmentPublicId of memory.sourceSegmentIds) {
        sourceInsert.run(memoryId, null, db.prepare('SELECT id FROM transcript_segments WHERE public_id=? AND user_id=?').get(segmentPublicId, userId).id);
      }
      const topicInsert = db.prepare('INSERT OR IGNORE INTO memory_topics (memory_id,topic) VALUES (?,?)');
      for (const topic of memory.topics) topicInsert.run(memoryId, topic.trim());
      const memoryEntityInsert = db.prepare('INSERT OR IGNORE INTO memory_entities (memory_id,entity_id,role) VALUES (?,?,?)');
      for (const item of memory.entities) memoryEntityInsert.run(memoryId, entityIds.get(item.ref), item.role);
      for (const mini of memory.miniMemories) {
        const miniPublicId = crypto.randomUUID();
        const miniResult = db.prepare(`INSERT INTO mini_memories
          (public_id,user_id,memory_id,kind,text_en,importance,confidence,due_at,occurred_at,status)
          VALUES (?,?,?,?,?,?,?,?,?,?)`).run(miniPublicId, userId, memoryId, mini.kind, mini.textEn, mini.importance, mini.confidence,
          mini.dueAt || null, mini.occurredAt || null, mini.status || (['task', 'promise'].includes(mini.kind) ? 'open' : null));
        const miniId = Number(miniResult.lastInsertRowid);
        const miniSourceInsert = db.prepare('INSERT INTO mini_memory_sources (mini_memory_id,segment_id) VALUES (?,?)');
        for (const segmentPublicId of mini.sourceSegmentIds) miniSourceInsert.run(miniId, db.prepare('SELECT id FROM transcript_segments WHERE public_id=? AND user_id=?').get(segmentPublicId, userId).id);
        const miniEntityInsert = db.prepare('INSERT OR IGNORE INTO mini_memory_entities (mini_memory_id,entity_id,role) VALUES (?,?,?)');
        for (const item of mini.entities) miniEntityInsert.run(miniId, entityIds.get(item.ref), item.role);
        searchIndex.upsertDocument({ userId, kind: 'mini_memory', sourceId: miniId, body: mini.textEn, occurredAt: mini.occurredAt || memory.startedAt, importance: mini.importance }, db);
      }
      searchIndex.upsertDocument({ userId, kind: 'memory', sourceId: memoryId, title: memory.titleEn, body: memory.summaryEn, occurredAt: memory.startedAt, importance: memory.importance }, db);
    }
    if (output.dailySummary) {
      if (output.dailySummary.timezone !== userSettings.timezone) throw Object.assign(new Error('Daily summary timezone differs from the user setting.'), { code: 'AI_REFERENCE_INVALID' });
      const newestWorthyConversation = worthyConversations.reduce((latest, conversation) => !latest || Date.parse(conversation.endedAt) > Date.parse(latest.endedAt) ? conversation : latest, null);
      const expectedDate = localDate(newestWorthyConversation.endedAt, userSettings.timezone);
      if (output.dailySummary.localDate !== expectedDate) throw Object.assign(new Error('Daily summary local date is inconsistent with its coverage.'), { code: 'AI_REFERENCE_INVALID' });
      const existing = db.prepare('SELECT * FROM daily_summaries WHERE user_id=? AND local_date=? AND timezone=?').get(userId, expectedDate, userSettings.timezone);
      const currentDayConversations = worthyConversations.filter((conversation) => localDate(conversation.endedAt, userSettings.timezone) === expectedDate);
      const coverageStartedAt = [existing?.coverage_started_at, ...currentDayConversations.map((conversation) => conversation.startedAt)]
        .filter(Boolean).reduce((earliest, value) => !earliest || Date.parse(value) < Date.parse(earliest) ? value : earliest, null);
      const coverageEndedAt = [existing?.coverage_ended_at, ...currentDayConversations.map((conversation) => conversation.endedAt)]
        .filter(Boolean).reduce((latest, value) => !latest || Date.parse(value) > Date.parse(latest) ? value : latest, null);
      const sourceCount = Number(existing?.source_count || 0) + currentDayConversations.length;
      const summaryId = existing?.id || crypto.randomUUID();
      db.prepare(`INSERT INTO daily_summaries
        (id,user_id,local_date,timezone,summary_en,coverage_started_at,coverage_ended_at,revision,state,source_count,consolidation_run_id)
        VALUES (?,?,?,?,?,?,?,?,'provisional',?,?)
        ON CONFLICT(user_id,local_date,timezone) DO UPDATE SET summary_en=excluded.summary_en,coverage_started_at=excluded.coverage_started_at,
        coverage_ended_at=excluded.coverage_ended_at,revision=daily_summaries.revision+1,state='provisional',source_count=excluded.source_count,
        consolidation_run_id=excluded.consolidation_run_id,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`)
        .run(summaryId, userId, expectedDate, userSettings.timezone, output.dailySummary.summaryEn, coverageStartedAt,
          coverageEndedAt, existing ? existing.revision + 1 : 1, sourceCount, runId);
      searchIndex.upsertDocument({ userId, kind: 'daily_summary', sourceId: summaryId, title: expectedDate, body: output.dailySummary.summaryEn,
        occurredAt: coverageEndedAt, importance: 5 }, db);
    }
    db.prepare(`UPDATE consolidation_runs SET state='succeeded',ai_request_id=?,memory_count=?,mini_memory_count=?,
      completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`).run(aiRequestId, output.memories.length,
      output.memories.reduce((sum, memory) => sum + memory.miniMemories.length, 0), runId, userId);
    db.prepare(`INSERT INTO event_outbox (user_id,event_type,resource_type,resource_id,payload_json,expires_at)
      VALUES (?,'consolidation.completed','consolidation_run',?,?,?)`).run(userId, runId, JSON.stringify({
      runId,
      memories: output.memories.length,
      conversations: refined.conversations.length,
    }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
  })();
}

async function execute(runId, reservedConversationIds = null) {
  const db = getDatabase();
  const run = db.prepare("SELECT * FROM consolidation_runs WHERE id=? AND state='reserved'").get(runId);
  if (!run) throw Object.assign(new Error('Consolidation run is not reserved.'), { code: 'RUN_NOT_RESERVED' });
  let requestedIds = reservedConversationIds;
  if (!requestedIds) {
    const queuedJob = db.prepare("SELECT payload_json FROM jobs WHERE type='consolidate_memories' AND resource_id=? ORDER BY created_at DESC LIMIT 1").get(runId);
    requestedIds = queuedJob ? JSON.parse(queuedJob.payload_json).conversationIds : null;
  }
  const available = new Map(buildCandidates(run.user_id).conversations.map((conversation) => [conversation.id, conversation]));
  const conversations = requestedIds?.length
    ? requestedIds.map((id) => available.get(id)).filter(Boolean)
    : [...available.values()].filter((conversation) => (
      Date.parse(conversation.startedAt) >= Date.parse(run.candidate_started_at)
      && Date.parse(conversation.endedAt) <= Date.parse(run.candidate_ended_at)
    ));
  if (!conversations.length || (requestedIds?.length && conversations.length !== requestedIds.length)) {
    db.prepare(`UPDATE consolidation_runs SET state='failed',error_code='CONSOLIDATION_INPUT_CHANGED',
      completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(runId);
    throw Object.assign(new Error('The reserved conversation set changed before consolidation could start.'), {
      code: 'CONSOLIDATION_INPUT_CHANGED',
      retryable: false,
    });
  }
  db.prepare("UPDATE consolidation_runs SET state='running',started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(runId);
  let aiRequestId = null;
  try {
    const userSettings = settings.get(run.user_id);
    const summaryTargetDate = localDate(conversations.at(-1).endedAt, userSettings.timezone);
    const previous = db.prepare('SELECT * FROM daily_summaries WHERE user_id=? AND local_date=? AND timezone=?')
      .get(run.user_id, summaryTargetDate, userSettings.timezone) || null;
    const response = await ai.consolidate(run.user_id, { conversations, previousDailySummary: previous, timezone: userSettings.timezone });
    aiRequestId = response.requestId;
    persist(run.user_id, runId, response.value, conversations, response.requestId, response.speakerClusters);
    return { runId, memories: response.value.memories.length };
  } catch (error) {
    if (aiRequestId && error.code === 'AI_REFERENCE_INVALID') {
      db.prepare("UPDATE ai_requests SET state='failed',error_code='AI_REFERENCE_INVALID' WHERE id=?").run(aiRequestId);
      error.aiRequestId = aiRequestId;
    }
    db.prepare(`UPDATE consolidation_runs SET state='failed',ai_request_id=?,error_code=?,error_message=?,completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
      .run(error.aiRequestId || null, error.code || 'CONSOLIDATION_FAILED', String(error.message || '').slice(0, 2000), runId);
    if (VALIDATION_FAILURE_CODES.includes(error.code)) {
      recordValidationFailure(run.user_id, conversations.map((conversation) => conversation.id), error.code);
    }
    throw error;
  }
}

function latest(userId) {
  const run = getDatabase().prepare('SELECT * FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT 1').get(userId) || null;
  return { run, eligibility: eligibility(userId) };
}

module.exports = {
  eligibility, request, execute, latest, validateReferences, anchorMemoryRanges, localDate,
  recordValidationFailure, buildCandidates, VALIDATION_FAILURE_CODES,
};
