'use strict';

const { getDatabase } = require('../../db/database');
const { pageLimit } = require('../../utils/pagination');
const { SPEAKER_NAME_COLUMNS, SPEAKER_NAME_JOINS } = require('../../db/speaker_resolution_sql');

function list(userId, query = {}) {
  const limit = pageLimit(query.limit, 250, 100);
  const after = Number(query.after || 0);
  const rows = getDatabase().prepare(`SELECT t.*,${SPEAKER_NAME_COLUMNS}
    FROM transcript_segments t
    ${SPEAKER_NAME_JOINS}
    WHERE t.user_id=? AND t.id>? ORDER BY t.id LIMIT ?`).all(userId, after, limit + 1);
  return { items: rows.slice(0, limit), nextCursor: rows.length > limit ? String(rows[limit - 1].id) : null };
}

module.exports = { list };
