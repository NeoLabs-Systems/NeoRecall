'use strict';

const { getDatabase } = require('../../db/database');
const { pageLimit } = require('../../utils/pagination');
const { SPEAKER_NAME_COLUMNS, SPEAKER_NAME_JOINS } = require('../../db/speaker_resolution_sql');

// Transcripts are read newest first. A timeline asks "what did I just record",
// and a page of the oldest segments an account ever produced can never answer
// that: past the first page, today's recording is invisible no matter how much
// was recorded. Ascending order stays available for anyone walking the whole
// history forward, and passing `after` selects it on its own so existing
// callers keep the cursor they already hold.
function list(userId, query = {}) {
  const limit = pageLimit(query.limit, 1000, 100);
  const requested = String(query.order || '').toLowerCase();
  const ascending = requested === 'asc' || (requested !== 'desc' && Boolean(query.after));
  const cursor = Number((ascending ? query.after : (query.before || query.cursor)) || 0);
  const bound = ascending
    ? 't.id>?'
    : (cursor > 0 ? 't.id<?' : 't.id>?');
  const rows = getDatabase().prepare(`SELECT t.*,${SPEAKER_NAME_COLUMNS}
    FROM transcript_segments t
    ${SPEAKER_NAME_JOINS}
    WHERE t.user_id=? AND ${bound} ORDER BY t.id ${ascending ? 'ASC' : 'DESC'} LIMIT ?`)
    .all(userId, cursor > 0 ? cursor : 0, limit + 1);
  const items = rows.slice(0, limit);
  // The cursor names the last row handed out, so the next page continues from
  // it in the same direction.
  const nextCursor = rows.length > limit && items.length ? String(items[items.length - 1].id) : null;
  return { items, nextCursor, order: ascending ? 'asc' : 'desc' };
}

module.exports = { list };
