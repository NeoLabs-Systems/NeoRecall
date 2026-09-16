'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { localDateTimeToUtc, localDateTimeNow } = require('../../utils/time');
const { createLogger } = require('../../utils/logger');
const searchService = require('./search_service');
const settings = require('../settings/settings_service');
const aiEngine = require('../../ai/ai_engine');
const usageLimits = require('../usage/usage_limit_service');

const logger = createLogger('ask');

function reserveAttempt(userId) {
  const db = getDatabase();
  const windowMs = getConfig().askQuotaWindowMs;
  db.transaction(() => {
    const cutoff = new Date(Date.now() - windowMs).toISOString();
    const count = db.prepare('SELECT COUNT(*) count FROM ask_quota_events WHERE user_id=? AND attempted_at>=?').get(userId, cutoff).count;
    if (count >= getConfig().askMaxPerHour) {
      const first = db.prepare('SELECT attempted_at FROM ask_quota_events WHERE user_id=? AND attempted_at>=? ORDER BY attempted_at LIMIT 1').get(userId, cutoff);
      const retryAfterSeconds = Math.max(1, Math.ceil((Date.parse(first.attempted_at) + windowMs - Date.now()) / 1000));
      throw new HttpError(429, 'ASK_RATE_LIMITED', 'The hourly Ask limit has been reached.', { retryAfterSeconds });
    }
    db.prepare('INSERT INTO ask_quota_events (user_id) VALUES (?)').run(userId);
  })();
}

// The plan is an optimisation, not a precondition: when the model cannot produce
// one the question is still retrievable as it was typed, which is exactly the
// behaviour Ask had before planning existed.
async function planFor(userId, question, nowLocal, timezone) {
  try {
    const plan = await aiEngine.planQuery(userId, { question, nowLocal, timezone });
    return plan.value;
  } catch (error) {
    logger.warn('Query planning failed; retrieving the question as written.', { code: error.code || 'AI_REQUEST_FAILED' });
    return { searchQueries: [question], fromLocal: null, toLocal: null, kinds: [], wholePeriod: false };
  }
}

// A local range the model resolved becomes two instants, or nothing at all: a
// range that does not convert is a range the archive cannot be filtered by, and
// dropping it retrieves too much rather than the wrong period.
function windowFor(plan, timezone) {
  if (!plan.fromLocal && !plan.toLocal) return { from: null, to: null };
  try {
    return {
      from: plan.fromLocal ? localDateTimeToUtc(plan.fromLocal, timezone) : null,
      to: plan.toLocal ? localDateTimeToUtc(plan.toLocal, timezone) : null,
    };
  } catch (error) {
    logger.warn('Query plan produced an unusable time range.', { fromLocal: plan.fromLocal, toLocal: plan.toLocal });
    return { from: null, to: null };
  }
}

// The record consolidation already wrote, and the raw speech underneath it.
const WRITTEN_KINDS = Object.freeze(['memory', 'mini_memory', 'daily_summary']);
const TRANSCRIPT_KINDS = Object.freeze(['segment']);

// Runs the plan's restatements over one layer of the archive and keeps each
// document once, at its best rank.
async function retrieveLayer(userId, plan, window, kinds, limit) {
  if (limit <= 0) return { results: [], weakCount: 0 };
  const queries = plan.searchQueries.slice(0, getConfig().askMaxSearchQueries);
  const best = new Map();
  let weakCount = 0;
  for (const query of queries) {
    const found = await searchService.search(userId, query, {
      limit, kinds, from: window.from, to: window.to, wholeWindow: plan.wholePeriod,
    });
    // The same neighbours are re-read by every restatement, so the largest
    // single count is how many were filtered — a sum would report the same
    // dropped rows once per query.
    weakCount = Math.max(weakCount, found.weakCount);
    for (const result of found.results) {
      const current = best.get(result.id);
      if (!current || result.score > current.score) best.set(result.id, result);
    }
  }
  return { results: [...best.values()].sort((left, right) => right.score - left.score).slice(0, limit), weakCount };
}

/**
 * Written-record kinds first, then a smaller transcript share.
 * A question that named kinds is honoured; an empty restriction is widened.
 */
async function retrieve(userId, plan, window) {
  const config = getConfig();
  const total = config.askMemoryContextLimit + config.askTranscriptContextLimit;
  if (plan.kinds.length) {
    const chosen = await retrieveLayer(userId, plan, window, plan.kinds, total);
    if (chosen.results.length) return chosen;
    const unrestricted = await retrieveLayer(userId, plan, window, [], total);
    return { ...unrestricted, widened: true };
  }
  const written = await retrieveLayer(userId, plan, window, WRITTEN_KINDS, config.askMemoryContextLimit);
  const spoken = await retrieveLayer(userId, plan, window, TRANSCRIPT_KINDS, config.askTranscriptContextLimit);
  return {
    results: [...written.results, ...spoken.results],
    weakCount: Math.max(written.weakCount, spoken.weakCount),
  };
}

function internalId(sourceId) {
  const text = String(sourceId || '');
  const separator = text.indexOf(':');
  return separator === -1 ? text : text.slice(separator + 1);
}

function citationHref(userId, kind, sourceId) {
  const db = getDatabase();
  const id = internalId(sourceId);
  if (kind === 'memory') {
    const row = db.prepare('SELECT public_id FROM memories WHERE id=? AND user_id=?').get(Number(id), userId);
    return row ? `/memories/${row.public_id}` : `/memories/${id}`;
  }
  if (kind === 'mini_memory') {
    const row = db.prepare(`SELECT m.public_id
      FROM mini_memories mm JOIN memories m ON m.id=mm.memory_id
      WHERE mm.id=? AND mm.user_id=?`).get(Number(id), userId);
    return row ? `/memories/${row.public_id}` : `/memories/${id}`;
  }
  if (kind === 'daily_summary') return `/daily-summaries/${id}`;
  if (kind === 'segment') {
    const row = db.prepare('SELECT public_id FROM transcript_segments WHERE id=? AND user_id=?').get(Number(id), userId);
    return row ? `/timeline?segment=${row.public_id}` : `/timeline?segment=${id}`;
  }
  return `/memories/${id}`;
}

async function ask(userId, question) {
  usageLimits.rejectIfReached(userId, 'ai');
  const timezone = settings.get(userId).timezone;
  const nowLocal = localDateTimeNow(timezone);
  const planned = await planFor(userId, question, nowLocal, timezone);
  const window = windowFor(planned, timezone);
  // A period the plan could not put a range on is not a period. Retrieving the
  // "whole window" of an unbounded archive would return its newest rows for any
  // question at all.
  const plan = { ...planned, wholePeriod: Boolean(planned.wholePeriod && (window.from || window.to)) };
  const { results, weakCount } = await retrieve(userId, plan, window);

  const context = results.map((result) => ({
    sourceId: `${result.kind}:${result.source_id}`, kind: result.kind, timestamp: result.occurred_at, title: result.title, text: result.body,
  }));
  const allowed = new Map(results.map((result) => [`${result.kind}:${result.source_id}`, result]));
  const period = plan.fromLocal || plan.toLocal ? { fromLocal: plan.fromLocal, toLocal: plan.toLocal } : null;
  const frame = { nowLocal, timezone, period };
  // Nothing found is a finding. Told when the archive last holds anything, the
  // answer can say why the period looks empty — a day not yet consolidated, a
  // gap in recording, an account whose timezone is not the one being lived in —
  // instead of reporting that nothing happened.
  if (!results.length) {
    const latest = searchService.latestActivity(userId);
    frame.archive = latest
      ? { holdsNothingForThePeriod: true, latestActivityAt: latest.occurred_at, latestActivityTitle: latest.title }
      : { holdsNothingForThePeriod: true, empty: true };
  }
  const response = await aiEngine.answer(userId, question, context, () => reserveAttempt(userId), frame);
  const excerptChars = getConfig().askCitationExcerptChars;

  const citations = response.value.citations.filter((citation) => allowed.has(citation.sourceId)).map((citation) => {
    const result = allowed.get(citation.sourceId);
    return {
      ...citation,
      kind: result.kind,
      timestamp: result.occurred_at,
      title: result.title,
      excerpt: String(result.body || '').slice(0, excerptChars),
      relevance: result.relevance,
      link: citationHref(userId, result.kind, citation.sourceId),
    };
  });
  return {
    answer: response.value.answer,
    citations,
    // What retrieval did, so the client can say "3 of 17" rather than implying
    // the archive holds nothing else.
    retrieval: {
      considered: results.length,
      weakCount,
      period,
      timezone,
      wholePeriod: plan.wholePeriod,
    },
  };
}

module.exports = { ask, reserveAttempt, citationHref };
