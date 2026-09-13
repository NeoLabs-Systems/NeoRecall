'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

function pollAfter(userId, lastId, { limit } = {}) {
  const cap = Math.min(
    Math.max(1, Number(limit) || getConfig().eventOutboxPollLimit),
    getConfig().eventOutboxPollLimit,
  );
  const after = Number.isSafeInteger(lastId) && lastId > 0 ? lastId : 0;
  return getDatabase().prepare(`SELECT * FROM event_outbox WHERE user_id=? AND id>? AND expires_at>?
    ORDER BY id LIMIT ?`).all(userId, after, new Date().toISOString(), cap);
}

module.exports = { pollAfter };
