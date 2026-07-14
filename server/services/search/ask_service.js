'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const searchService = require('./search_service');
const aiEngine = require('../../ai/ai_engine');

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

async function ask(userId, question) {
  const results = await searchService.search(userId, question, { limit: 16 });
  const context = results.map((result) => ({ sourceId: `${result.kind}:${result.source_id}`, kind: result.kind, timestamp: result.occurred_at, title: result.title, text: result.body }));
  const allowed = new Set(context.map((item) => item.sourceId));
  const response = await aiEngine.answer(userId, question, context, () => reserveAttempt(userId));
  const citations = response.value.citations.filter((citation) => allowed.has(citation.sourceId)).map((citation) => {
    const item = context.find((entry) => entry.sourceId === citation.sourceId);
    return { ...citation, kind: item.kind, timestamp: item.timestamp, link: item.kind === 'segment' ? `/timeline?segment=${item.sourceId.split(':')[1]}` : `/memories/${item.sourceId.split(':')[1]}` };
  });
  return { answer: response.value.answer, citations };
}

module.exports = { ask, reserveAttempt };
