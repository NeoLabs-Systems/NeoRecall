'use strict';

const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');
const { createLogger } = require('../../utils/logger');
const aiProviders = require('../../ai/provider_registry');
const searchIndex = require('../../embeddings/search_index_service');
const consolidation = require('../memories/consolidation_service');

const logger = createLogger('memories');

// Writing one conversation up again, on request.
//
// The transcript is the record and is never touched here. What is rebuilt is
// everything the model derived from it: the conversation's own title and
// summary, and the memory it produced.

// Memories that came from this conversation alone.
//
// A memory built from several conversations is left in place: this
// conversation is the only one being written up again, and deleting a memory
// that also describes conversations nobody asked to redo would lose material
// that will never be regenerated.
function memoriesOwnedBy(database, userId, conversationId) {
  return database.prepare(`SELECT m.id, m.public_id FROM memories m
    WHERE m.user_id=? AND EXISTS (
      SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id AND s.conversation_id=?
    ) AND NOT EXISTS (
      SELECT 1 FROM memory_sources s WHERE s.memory_id=m.id
        AND s.conversation_id IS NOT NULL AND s.conversation_id<>?
    )`).all(userId, conversationId, conversationId);
}

function reprocess(userId, conversationId) {
  const db = getDatabase();
  const conversation = db.prepare('SELECT * FROM conversations WHERE id=? AND user_id=?')
    .get(conversationId, userId);
  if (!conversation) throw new HttpError(404, 'NOT_FOUND', 'Conversation not found.');
  if (conversation.state === 'open') {
    throw new HttpError(409, 'CONVERSATION_OPEN', 'This conversation is still being recorded.');
  }
  // Refusing early matters: the old write-up is removed as part of this, and
  // removing it with nothing able to replace it would be a plain loss.
  if (!aiProviders.ready()) {
    throw new HttpError(409, 'AI_NOT_CONFIGURED', 'No language model is configured.');
  }

  const removed = db.transaction(() => {
    const owned = memoriesOwnedBy(db, userId, conversationId);
    for (const memory of owned) {
      const miniIds = db.prepare('SELECT id FROM mini_memories WHERE memory_id=? AND user_id=?')
        .all(memory.id, userId);
      searchIndex.removeBySources(db, userId, [
        { kind: 'memory', sourceId: memory.id },
        ...miniIds.map((row) => ({ kind: 'mini_memory', sourceId: row.id })),
      ]);
      db.prepare('DELETE FROM memories WHERE id=? AND user_id=?').run(memory.id, userId);
    }
    // Back to the state a finished conversation waits in. The failure count and
    // any quarantine go with it, so a conversation that failed before gets a
    // full set of attempts rather than being refused on the old tally. The
    // title and summary stay: they are what is on screen right now, and
    // blanking them would leave the moment worse off until the model answers.
    db.prepare(`UPDATE conversations SET state='closed', refined_at=NULL, refinement_run_id=NULL,
      memory_worthy=NULL, insight_state=CASE WHEN insight_state IS NULL THEN NULL ELSE 'provisional' END,
      consolidation_failures=0, quarantined_at=NULL, quarantine_reason=NULL,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`)
      .run(conversationId, userId);
    return owned.length;
  })();

  const queued = consolidation.request(userId, { manual: true });
  logger.info('Writing one conversation up again', {
    userId, conversationId, replacedMemories: removed, queued: Boolean(queued.queued),
  });
  // Not queueing right now is not a failure: the conversation is back in the
  // waiting state, so the next scheduled run picks it up either way.
  return { conversationId, replacedMemories: removed, queued: Boolean(queued.queued), runId: queued.runId || null };
}

module.exports = { reprocess };
