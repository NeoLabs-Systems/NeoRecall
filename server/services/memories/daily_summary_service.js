'use strict';

const { getDatabase } = require('../../db/database');

function finalizeCoveredDays(now = new Date()) {
  const rows = getDatabase().prepare("SELECT * FROM daily_summaries WHERE state='provisional'").all();
  let finalized = 0;
  for (const row of rows) {
    const consolidation = require('./consolidation_service');
    const today = consolidation.localDate(now.toISOString(), row.timezone);
    if (row.local_date >= today) continue;
    const pending = getDatabase().prepare("SELECT started_at FROM conversations WHERE user_id=? AND state='closed'").all(row.user_id)
      .some((conversation) => consolidation.localDate(conversation.started_at, row.timezone) <= row.local_date);
    if (!pending) finalized += getDatabase().prepare("UPDATE daily_summaries SET state='final',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(row.id).changes;
  }
  return finalized;
}

module.exports = { finalizeCoveredDays };
