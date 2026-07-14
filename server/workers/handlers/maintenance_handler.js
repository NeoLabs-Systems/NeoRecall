'use strict';

const { getDatabase } = require('../../db/database');
const summaries = require('../../services/memories/daily_summary_service');

async function handle(job) {
  const db = getDatabase();
  if (job.type === 'prune_events') {
    const changes = db.prepare('DELETE FROM event_outbox WHERE expires_at<?').run(new Date().toISOString()).changes;
    db.prepare('DELETE FROM ask_quota_events WHERE attempted_at<?').run(new Date(Date.now() - 2 * 60 * 60_000).toISOString());
    return { pruned: changes };
  }
  if (job.type === 'maintenance') {
    const finalized = summaries.finalizeCoveredDays();
    db.prepare(`UPDATE consolidation_runs SET state='failed',error_code='WORKER_INTERRUPTED',completed_at=?
      WHERE state IN ('reserved','running') AND reserved_at<?`).run(new Date().toISOString(), new Date(Date.now() - 30 * 60_000).toISOString());
    const importService = require('../../services/ingest/import_service');
    const importsCompleted = importService.reconcileProcessing();
    const importOrphansRemoved = importService.sweepOrphans();
    for (const expired of db.prepare("SELECT * FROM imports WHERE state='failed' AND expires_at<?").all(new Date().toISOString())) {
      if (expired.temporary_path) { try { require('node:fs').unlinkSync(expired.temporary_path); } catch (_) {} }
      const session = db.prepare('SELECT id FROM recording_sessions WHERE user_id=? AND client_uuid=?').get(expired.user_id, `import-${expired.id}`);
      if (session) {
        for (const chunk of db.prepare('SELECT temporary_path FROM audio_chunks WHERE session_id=? AND temporary_path IS NOT NULL').all(session.id)) {
          try { require('node:fs').unlinkSync(chunk.temporary_path); } catch (_) {}
        }
        db.prepare('DELETE FROM recording_sessions WHERE id=?').run(session.id);
      }
      db.prepare("UPDATE imports SET temporary_path=NULL,state='cancelled',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(expired.id);
    }
    return { finalized, importsCompleted, importOrphansRemoved };
  }
  return { skipped: true };
}

module.exports = { handle };
