'use strict';

const { getDatabase } = require('../../db/database');
const engine = require('../../speakers/identity_engine');
const settings = require('../../services/settings/settings_service');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('speaker-resolution');

// Re-resolves who spoke in one conversation, once it has closed.
//
// The conversation may legitimately be gone by the time this runs: refinement
// re-partitions a whole consolidation batch and deletes the rows it replaced,
// so a queued job can name an id that no longer exists. That is an ordinary
// outcome, not a failure — throwing would burn five attempts and a quarter of
// an hour of backoff to reach the same conclusion.
async function handle(job) {
  const db = getDatabase();
  const conversation = db.prepare('SELECT id,state FROM conversations WHERE id=? AND user_id=?')
    .get(job.resource_id, job.user_id);
  if (!conversation) return { skipped: 'conversation_gone' };
  if (!settings.get(job.user_id).deferredSpeakerResolution) return { skipped: 'disabled' };
  // The engine owns its own transaction boundary, and deliberately keeps the
  // write lock held only for the part that writes.
  const result = engine.resolveConversation(db, job.user_id, conversation.id);
  if (result.mergedClusters || result.assignedTurns) {
    logger.info('Re-resolved conversation speakers', {
      userId: job.user_id, conversationId: conversation.id, ...result,
    });
  }
  return result;
}

module.exports = { handle };
