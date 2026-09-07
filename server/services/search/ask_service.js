'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const { localDateTimeToUtc, localDateTimeNow } = require('../../utils/time');
const { createLogger } = require('../../utils/logger');
const searchService = require('./search_service');
const settings = require('../settings/settings_service');
const aiEngine = require('../../ai/ai_engine');

const logger = createLogger('ask');

function reserveAttempt(userId) {
  const db = getDatabase();
  db.transaction(() => {
    const cutoff = new Date(Date.now() - 60 * 60_000).toISOString();
    const count = db.prepare('SELECT COUNT(*) count FROM ask_quota_events WHERE user_id=? AND attempted_at>=?').get(userId, cutoff).count;
    if (count >= getConfig().askMaxPerHour) {
      const first = db.prepare('SELECT attempted_at FROM ask_quota_events WHERE user_id=? AND attempted_at>=? ORDER BY attempted_at LIMIT 1').get(userId, cutoff);
      const retryAfterSeconds = Math.max(1, Math.ceil((Date.parse(first.attempted_at) + 60 * 60_000 - Date.now()) / 1000));
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

// Runs the plan's restatements and keeps each document once, at its best rank.
async function retrieve(userId, plan, window, limit) {
  const queries = plan.searchQueries.slice(0, getConfig().askMaxSearchQueries);
  const best = new Map();
  let weakCount = 0;
  for (const query of queries) {
    const found = await searchService.search(userId, query, {
      limit, kinds: plan.kinds, from: window.from, to: window.to, wholeWindow: plan.wholePeriod,
    });
    weakCount += found.weakCount;
    for (const result of found.results) {
      const current = best.get(result.id);
      if (!current || result.score > current.score) best.set(result.id, result);
    }
  }
  return { results: [...best.values()].sort((left, right) => right.score - left.score).slice(0, limit), weakCount };
}

async function ask(userId, question) {
  const timezone = settings.get(userId).timezone;
  const nowLocal = localDateTimeNow(timezone);
  const plan = await planFor(userId, question, nowLocal, timezone);
  const window = windowFor(plan, timezone);
  const { results, weakCount } = await retrieve(userId, plan, window, 16);

  const context = results.map((result) => ({
    sourceId: `${result.kind}:${result.source_id}`, kind: result.kind, timestamp: result.occurred_at, title: result.title, text: result.body,
  }));
  const allowed = new Map(results.map((result) => [`${result.kind}:${result.source_id}`, result]));
  const frame = { nowLocal, timezone, period: plan.fromLocal || plan.toLocal ? { fromLocal: plan.fromLocal, toLocal: plan.toLocal } : null };
  const response = await aiEngine.answer(userId, question, context, () => reserveAttempt(userId), frame);

  const citations = response.value.citations.filter((citation) => allowed.has(citation.sourceId)).map((citation) => {
    const result = allowed.get(citation.sourceId);
    const sourceKey = citation.sourceId.split(':')[1];
    return {
      ...citation,
      kind: result.kind,
      timestamp: result.occurred_at,
      title: result.title,
      excerpt: String(result.body || '').slice(0, 240),
      relevance: result.relevance,
      link: result.kind === 'segment' ? `/timeline?segment=${sourceKey}` : `/memories/${sourceKey}`,
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
      period: frame.period,
      wholePeriod: plan.wholePeriod,
    },
  };
}

module.exports = { ask, reserveAttempt };
