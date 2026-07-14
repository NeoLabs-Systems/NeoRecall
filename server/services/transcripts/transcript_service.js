'use strict';

const { getDatabase } = require('../../db/database');
const { pageLimit } = require('../../utils/pagination');

function list(userId, query = {}) {
  const limit = pageLimit(query.limit, 250, 100);
  const after = Number(query.after || 0);
  const rows = getDatabase().prepare(`SELECT * FROM transcript_segments WHERE user_id=? AND id>? ORDER BY id LIMIT ?`).all(userId, after, limit + 1);
  return { items: rows.slice(0, limit), nextCursor: rows.length > limit ? String(rows[limit - 1].id) : null };
}

module.exports = { list };
