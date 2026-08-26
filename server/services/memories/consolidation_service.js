'use strict';

const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const settings = require('../settings/settings_service');
const processingSettings = require('../settings/processing_settings_service');
const jobs = require('../jobs/job_service');
const ai = require('../../ai/ai_engine');
const aiProviders = require('../../ai/provider_registry');
const searchIndex = require('../../embeddings/search_index_service');
const memoryContinuity = require('./memory_continuity_service');
const refinement = require('../conversations/conversation_refinement_service');
const material = require('../conversations/conversation_material_service');
const contextMaterial = require('../context/context_material_service');
const speakerIdentity = require('../speakers/speaker_identity_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('memories');

// Failures that mean the model could not produce a valid answer for this exact
// input. Resending the same conversations reproduces them, so they drive the
// narrowing and quarantine policy below; transport failures never do.
//
// A truncated completion belongs here even though nothing was wrong with the
// model's reasoning: it means the answer this input demands did not fit in the
// budget, and carrying fewer conversations next time is exactly the right
// response. If a single conversation still cannot fit, quarantine eventually
// stops the bleeding and the operator raises AI_CONSOLIDATION_MAX_OUTPUT_TOKENS.
//
// A request that overran the context belongs here for the same reason. Windowing
// keeps ordinary input inside it, so reaching this means one indivisible piece of
// evidence — a single recognized utterance — is larger than the whole window, and
// resending it reproduces the failure exactly.
const VALIDATION_FAILURE_CODES = Object.freeze([
  'AI_REFERENCE_INVALID', 'AI_SCHEMA_INVALID', 'AI_TEMPORAL_INVALID', 'AI_OUTPUT_TRUNCATED', 'AI_CONTEXT_EXCEEDED',
]);

function localDate(iso, timezone) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date(iso));
  const byType = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${byType.year}-${byType.month}-${byType.day}`;
}

function lastOutbound(userId) {
  return getDatabase().prepare("SELECT sent_at FROM ai_requests WHERE user_id=? AND purpose='consolidation' AND sent_at IS NOT NULL ORDER BY sent_at DESC LIMIT 1").get(userId);
}

// How long to wait after a run that failed, growing with each failure in a row.
//
// Without this, a consolidation that fails for a reason nothing about the input
// can fix — an endpoint that is down, a model name that does not exist, a
// context set larger than the server allows — is attempted again on the very
// next scheduler tick, and the one after that. Observed on a real installation:
// three language-model requests a minute, every minute, all failing, for hours.
// It produces nothing, fills the request log so the actual first failure cannot
// be found, and hammers an endpoint that is already unwell.
//
// It backs off rather than giving up, because most of these causes are
// temporary and the recording is still waiting to become a memory. One minute,
// then two, four, eight, up to half an hour — so an outage costs a handful of
// attempts instead of hundreds, and recovery still happens on its own within
// half an hour of the cause being fixed. Asking by hand ignores it entirely.
const FAILURE_BACKOFF_BASE_MS = 60_000;
const FAILURE_BACKOFF_MAX_MS = 30 * 60_000;

function failureBackoff(userId) {
  const rows = getDatabase().prepare(`SELECT state,error_code,error_message,completed_at
    FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT 16`).all(userId);
  let consecutive = 0;
  let latest = null;
  for (const row of rows) {
    if (row.state !== 'failed') break;
    if (!latest) latest = row;
    consecutive += 1;
  }
  if (!consecutive || !latest?.completed_at) return null;
  const delay = Math.min(FAILURE_BACKOFF_MAX_MS, FAILURE_BACKOFF_BASE_MS * 2 ** (consecutive - 1));
  const retryAt = Date.parse(latest.completed_at) + delay;
  if (Date.now() >= retryAt) return null;
  return {
    consecutiveFailures: consecutive,
    retryAt: new Date(retryAt).toISOString(),
    errorCode: latest.error_code || null,
    errorMessage: latest.error_message || null,
  };
}

function candidateConversations(userId) {
  return material.listByState(userId, ['closed'])
    .filter((conversation) => material.isComplete(userId, conversation.id))
    .filter((conversation) => contextMaterial.sessionComplete(userId, conversation.session_id));
}

// True when the most recent consolidation could not be validated.
//
// Candidates are always taken oldest-first, so a conversation the model cannot
// partition would otherwise reappear in every later run and stop memory
// generation for good. After such a failure the next run carries a single
// conversation, which both isolates the cause and stops a whole batch from
// being blamed for one bad member.
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
  contextMaterial.attach(userId, output);
  return { conversations: output, characters, audioMs, narrowed };
}

function eligibility(userId, { ignoreBackoff = false } = {}) {
  const config = getConfig();
  const processingConfig = processingSettings.get();
  if (!aiProviders.ready()) return { eligible: false, reason: 'ai_not_configured' };
  const active = getDatabase().prepare("SELECT id FROM consolidation_runs WHERE user_id=? AND state IN ('reserved','running')").get(userId);
  if (active) return { eligible: false, reason: 'already_running', runId: active.id };
  const interval = Math.max(settings.get(userId).consolidationIntervalMs, config.minConsolidationIntervalMs);
  const previous = lastOutbound(userId);
  const nextEligibleAt = previous ? new Date(Date.parse(previous.sent_at) + interval).toISOString() : new Date(0).toISOString();
  if (Date.parse(nextEligibleAt) > Date.now()) return { eligible: false, reason: 'interval', nextEligibleAt };
  const backoff = ignoreBackoff ? null : failureBackoff(userId);
  if (backoff) return { eligible: false, reason: 'recent_failure', ...backoff };
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

// Records that a consolidation could not be validated.
//
// Only the conversations the run actually carried are charged, and a
// conversation that reaches the configured limit is quarantined: it keeps its
// transcript and stays readable, but it no longer enters candidate sets, so one
// unpartitionable conversation cannot stop every later memory.
function recordValidationFailure(userId, conversationIds, errorCode) {
  if (!conversationIds.length) return { quarantined: [] };
  const db = getDatabase();
  const limit = processingSettings.get().consolidationMaxFailures;
  db.transaction(() => {
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
  let state = eligibility(userId);
  // Someone who presses the button has decided to try now, and is watching the
  // result — the backoff exists to stop unattended retries, not to refuse them.
  if (!state.eligible && state.reason === 'recent_failure' && manual) {
    state = eligibility(userId, { ignoreBackoff: true });
  }
  if (!state.eligible) {
    if (manual && state.reason === 'interval') {
      const retryAfterSeconds = Math.max(1, Math.ceil((Date.parse(state.nextEligibleAt) - Date.now()) / 1000));
      throw new HttpError(429, 'CONSOLIDATION_INTERVAL', 'The consolidation interval has not elapsed.', { retryAfterSeconds, nextEligibleAt: state.nextEligibleAt });
    }
    if (manual && state.reason === 'ai_not_configured') throw new HttpError(503, 'AI_NOT_CONFIGURED', 'The external language-model provider is not configured. Choose a provider and model in the admin dashboard or `.env`.');
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

function segmentEvidenceStats(conversations) {
  const stats = new Map();
  for (const conversation of conversations) {
    for (const segment of conversation.segments) {
      stats.set(segment.id, {
        durationMs: Math.max(0, Date.parse(segment.ended_at) - Date.parse(segment.started_at)),
        characters: String(segment.text || '').length,
      });
    }
  }
  return stats;
}

function evidenceForSegmentIds(segmentIds, stats) {
  let durationMs = 0;
  let characters = 0;
  for (const id of segmentIds) {
    const row = stats.get(id);
    if (!row) continue;
    durationMs += row.durationMs;
    characters += row.characters;
  }
  return { durationMs, characters };
}

// Demote thin conversation sections the model over-promoted to memory-worthy.
//
// Brief exchanges still get a title and summary on the timeline; they must not
// become episodic memory cards. Atomic facts from short speech are what
// mini-memories are for — and those only attach under a worthy parent memory.
function applyMemoryWorthinessFloors(output, conversations, floors = processingSettings.get()) {
  const minMs = Number(floors.minMemoryEvidenceMs ?? 0);
  const minChars = Number(floors.minMemoryEvidenceChars ?? 0);
  if (minMs <= 0 && minChars <= 0) return output;

  const stats = segmentEvidenceStats(conversations);
  const continuationSegmentIds = new Set((output.memories || [])
    .filter((memory) => memory.continuesMemoryIds?.length)
    .flatMap((memory) => memory.sourceSegmentIds));
  for (const section of output.conversationSections) {
    if (!section.memoryWorthy) continue;
    // Extending a substantial existing occasion does not create the thin
    // standalone card these floors are meant to prevent.
    if (section.sourceSegmentIds.some((id) => continuationSegmentIds.has(id))) continue;
    const evidence = evidenceForSegmentIds(section.sourceSegmentIds, stats);
    if (evidence.durationMs < minMs || evidence.characters < minChars) {
      section.memoryWorthy = false;
    }
  }

  const worthySegmentIds = new Set(output.conversationSections
    .filter((section) => section.memoryWorthy)
    .flatMap((section) => section.sourceSegmentIds));

  output.memories = (output.memories || []).filter((memory) => (
    memory.sourceSegmentIds.length > 0
    && memory.sourceSegmentIds.every((id) => worthySegmentIds.has(id))
  )).map((memory) => ({
    ...memory,
    miniMemories: (memory.miniMemories || []).filter((mini) => (
      mini.sourceSegmentIds.length > 0
      && mini.sourceSegmentIds.every((id) => worthySegmentIds.has(id))
    )),
  }));

  if (!output.conversationSections.some((section) => section.memoryWorthy)) {
    output.dailySummary = null;
  }
  return output;
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

function persistMemory(database, { userId, runId, memory, refined, entityIds }) {
  const continuity = memoryContinuity.absorbClaimed(database, userId, memory.continuesMemoryIds);
  const startedAt = continuity && Date.parse(continuity.startedAt) < Date.parse(memory.startedAt)
    ? continuity.startedAt : memory.startedAt;
  const endedAt = continuity && Date.parse(continuity.endedAt) > Date.parse(memory.endedAt)
    ? continuity.endedAt : memory.endedAt;
  let memoryId;
  if (continuity) {
    memoryId = continuity.target.id;
    // The summary always describes the whole occasion, including what the new
    // material added. Wording the reader chose by hand is theirs and stays, and
    // so does whether the card is pinned or put away: extending an occasion is
    // not a reason to undo a decision someone made about it.
    const edited = Boolean(continuity.target.prose_edited_at);
    database.prepare(`UPDATE memories SET type=?,title_en=?,summary_en=?,emoji=?,importance=?,
      started_at=?,ended_at=?,pinned=?,archived=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE id=? AND user_id=?`).run(
      edited ? continuity.target.type : memory.type,
      edited ? continuity.target.title_en : memory.titleEn,
      memory.summaryEn,
      edited ? continuity.target.emoji : memory.emoji,
      memory.importance,
      startedAt, endedAt, continuity.pinned, continuity.archived, memoryId, userId,
    );
  } else {
    const result = database.prepare(`INSERT INTO memories
      (public_id,user_id,type,title_en,summary_en,emoji,importance,started_at,ended_at,consolidation_run_id)
      VALUES (?,?,?,?,?,?,?,?,?,?)`).run(crypto.randomUUID(), userId, memory.type, memory.titleEn, memory.summaryEn,
      memory.emoji, memory.importance, memory.startedAt, memory.endedAt, runId);
    memoryId = Number(result.lastInsertRowid);
  }

  // A card that is extended already carries evidence, and memory_sources leaves
  // one of its reference columns NULL — which a UNIQUE index does not treat as
  // a duplicate. Attaching the same line twice would show it twice.
  const sourceInsert = database.prepare(`INSERT INTO memory_sources (memory_id,conversation_id,segment_id)
    SELECT ?,?,? WHERE NOT EXISTS (SELECT 1 FROM memory_sources
      WHERE memory_id=? AND conversation_id IS ? AND segment_id IS ?)`);
  const attachSource = (memoryIdValue, conversationId, segmentIdValue) => sourceInsert.run(
    memoryIdValue, conversationId, segmentIdValue, memoryIdValue, conversationId, segmentIdValue,
  );
  const sourceConversationIds = [...new Set(memory.sourceSegmentIds.map(
    (segmentPublicId) => refined.segmentConversationIds.get(segmentPublicId),
  ))];
  for (const conversationId of sourceConversationIds) attachSource(memoryId, conversationId, null);
  const segmentId = database.prepare('SELECT id FROM transcript_segments WHERE public_id=? AND user_id=?');
  for (const segmentPublicId of memory.sourceSegmentIds) {
    attachSource(memoryId, null, segmentId.get(segmentPublicId, userId).id);
  }
  const sourceIds = new Set(memory.sourceSegmentIds);
  const contextIds = refined.inputConversations
    .filter((conversation) => conversation.segments.some((segment) => sourceIds.has(segment.id)))
    .flatMap((conversation) => (conversation.contextItems || [])
      .filter((item) => !item.sourceSegmentId || sourceIds.has(item.sourceSegmentId))
      .map((item) => item.id));
  const contextInsert = database.prepare(`INSERT INTO memory_context_sources (memory_id,context_item_id,used_by_ai)
    VALUES (?,?,1) ON CONFLICT(memory_id,context_item_id) DO UPDATE SET used_by_ai=1`);
  for (const contextId of new Set(contextIds)) contextInsert.run(memoryId, contextId);
  const topicInsert = database.prepare('INSERT OR IGNORE INTO memory_topics (memory_id,topic) VALUES (?,?)');
  for (const topic of memory.topics) topicInsert.run(memoryId, topic.trim());
  const memoryEntityInsert = database.prepare('INSERT OR IGNORE INTO memory_entities (memory_id,entity_id,role) VALUES (?,?,?)');
  for (const item of memory.entities) memoryEntityInsert.run(memoryId, entityIds.get(item.ref), item.role);
  for (const mini of memory.miniMemories) {
    const miniResult = database.prepare(`INSERT INTO mini_memories
      (public_id,user_id,memory_id,kind,text_en,importance,confidence,due_at,occurred_at,status)
      VALUES (?,?,?,?,?,?,?,?,?,?)`).run(crypto.randomUUID(), userId, memoryId, mini.kind, mini.textEn, mini.importance, mini.confidence,
      mini.dueAt || null, mini.occurredAt || null, mini.status || (['task', 'promise'].includes(mini.kind) ? 'open' : null));
    const miniId = Number(miniResult.lastInsertRowid);
    const miniSourceInsert = database.prepare('INSERT INTO mini_memory_sources (mini_memory_id,segment_id) VALUES (?,?)');
    for (const segmentPublicId of mini.sourceSegmentIds) miniSourceInsert.run(miniId, segmentId.get(segmentPublicId, userId).id);
    const miniEntityInsert = database.prepare('INSERT OR IGNORE INTO mini_memory_entities (mini_memory_id,entity_id,role) VALUES (?,?,?)');
    for (const item of mini.entities) miniEntityInsert.run(miniId, entityIds.get(item.ref), item.role);
    searchIndex.upsertDocument({ userId, kind: 'mini_memory', sourceId: miniId, body: mini.textEn,
      occurredAt: mini.occurredAt || memory.startedAt, importance: mini.importance }, database);
  }
  const indexed = database.prepare('SELECT title_en,importance,importance_override FROM memories WHERE id=?').get(memoryId);
  searchIndex.upsertDocument({ userId, kind: 'memory', sourceId: memoryId, title: indexed.title_en,
    body: memory.summaryEn, occurredAt: startedAt,
    importance: Number(indexed.importance_override ?? indexed.importance) }, database);
  return { continued: Boolean(continuity), absorbed: continuity?.absorbed.length || 0 };
}

function persist(userId, runId, output, conversations, aiRequestId, speakerClusters = new Map(), continuationCandidates = []) {
  // Claims are settled first: the evidence floors waive themselves for material
  // that extends an existing occasion, and a claim that cannot be acted on must
  // not buy that waiver.
  const droppedClaims = memoryContinuity.resolveClaims(output.memories, continuationCandidates);
  if (droppedClaims.unknown || droppedClaims.duplicate) {
    logger.warn('Ignored continuation claims that could not be acted on', {
      userId, runId, ...droppedClaims,
    });
  }
  applyMemoryWorthinessFloors(output, conversations);
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
  return db.transaction(() => {
    const refined = refinement.applyConversationSections(
      db,
      userId,
      runId,
      output.conversationSections,
      conversations,
    );
    refined.inputConversations = conversations;
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
    let continuedMemories = 0;
    let absorbedMemories = 0;
    for (const memory of output.memories) {
      const result = persistMemory(db, { userId, runId, memory, refined, entityIds });
      if (result.continued) {
        continuedMemories += 1;
        // Why this occasion was treated as one that was already under way. The
        // sentence can quote the recording, so it stays at debug level with the
        // rest of the detail an operator turns on deliberately.
        logger.debug('Extended an occasion already written up', {
          runId, userId, absorbed: result.absorbed, reason: memory.continuationReasoning || null,
        });
      }
      absorbedMemories += result.absorbed;
    }
    if (output.dailySummary) {
      // Which day this covers, and in which timezone, are derived from the
      // evidence rather than read back from the model. The server already knows
      // both from the conversations it selected, so asking a model to restate
      // them only created a way for the answer to disagree with the input — and
      // that disagreement used to fail an otherwise correct consolidation.
      const newestWorthyConversation = worthyConversations.reduce((latest, conversation) => !latest || Date.parse(conversation.endedAt) > Date.parse(latest.endedAt) ? conversation : latest, null);
      const expectedDate = localDate(newestWorthyConversation.endedAt, userSettings.timezone);
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
      continuedMemories,
      absorbedMemories,
      conversations: refined.conversations.length,
    }), new Date(Date.now() + 24 * 60 * 60_000).toISOString());
    return { continuedMemories, absorbedMemories };
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
    logger.info('Writing up recordings', {
      runId, userId: run.user_id, conversations: conversations.length,
      characters: conversations.reduce((sum, conversation) => sum + conversation.segments.reduce((n, segment) => n + String(segment.text || '').length, 0), 0),
    });
    const startedAt = Date.now();
    const continuationCandidates = memoryContinuity.findCandidates(run.user_id, conversations, db);
    const response = await ai.consolidate(run.user_id, {
      conversations,
      continuationCandidates,
      previousDailySummary: previous,
      timezone: userSettings.timezone,
    });
    aiRequestId = response.requestId;
    const persisted = persist(run.user_id, runId, response.value, conversations, response.requestId,
      response.speakerClusters, continuationCandidates);
    logger.info('Recordings written up', {
      runId, userId: run.user_id, seconds: Number(((Date.now() - startedAt) / 1000).toFixed(1)),
      windows: response.windows, memories: response.value.memories.length,
      continuedMemories: persisted.continuedMemories,
      absorbedMemories: persisted.absorbedMemories,
      sections: response.value.conversationSections.length,
    });
    return { runId, memories: response.value.memories.length };
  } catch (error) {
    if (aiRequestId && error.code === 'AI_REFERENCE_INVALID') {
      db.prepare("UPDATE ai_requests SET state='failed',error_code='AI_REFERENCE_INVALID' WHERE id=?").run(aiRequestId);
      error.aiRequestId = aiRequestId;
    }
    db.prepare(`UPDATE consolidation_runs SET state='failed',ai_request_id=?,error_code=?,error_message=?,completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
      .run(error.aiRequestId || null, error.code || 'CONSOLIDATION_FAILED', String(error.message || '').slice(0, 2000), runId);
    if (VALIDATION_FAILURE_CODES.includes(error.code)) {
      const { quarantined } = recordValidationFailure(run.user_id, conversations.map((conversation) => conversation.id), error.code);
      if (quarantined.length) {
        // Set aside deliberately, and worth saying loudly: these conversations
        // stop becoming memories until someone intervenes.
        logger.warn('Conversations set aside after repeated failures', {
          userId: run.user_id, conversations: quarantined.length, errorCode: error.code,
        });
      }
    }
    logger.warn('Writing up recordings failed', {
      runId, userId: run.user_id, errorCode: error.code || 'CONSOLIDATION_FAILED',
      conversations: conversations.length,
      // Whether it will be retried on its own, which is the first thing anyone
      // reading this wants to know.
      retriedAutomatically: !VALIDATION_FAILURE_CODES.includes(error.code),
      reason: String(error.message || '').slice(0, 400),
    });
    throw error;
  }
}

function latest(userId) {
  const run = getDatabase().prepare('SELECT * FROM consolidation_runs WHERE user_id=? ORDER BY reserved_at DESC LIMIT 1').get(userId) || null;
  return { run, eligibility: eligibility(userId) };
}

module.exports = {
  eligibility, request, execute, latest, failureBackoff, validateReferences, applyMemoryWorthinessFloors,
  anchorMemoryRanges, localDate,
  recordValidationFailure, buildCandidates, persist, VALIDATION_FAILURE_CODES,
};
