'use strict';

const { getDatabase } = require('../../db/database');
const processingSettings = require('../../services/settings/processing_settings_service');
const boundary = require('../../services/conversations/boundary_service');
const jobs = require('../../services/jobs/job_service');
const membership = require('../../services/conversations/conversation_membership_service');
const vectors = require('../../transcription/speaker_embeddings');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('conversations');

function blocksForSegments(database, segments) {
  return segments.map((segment) => {
    const embedded = database.prepare(`SELECT se.embedding FROM search_embeddings se JOIN search_documents d ON d.id=se.document_id
      WHERE d.kind='segment' AND d.source_id=? AND d.user_id=?`).get(String(segment.id), segment.user_id);
    return {
      id: segment.id, segmentIds: [segment.id], startedAt: segment.started_at, endedAt: segment.ended_at,
      speakerId: segment.speaker_cluster_id, embedding: embedded ? vectors.fromBuffer(embedded.embedding) : null,
      characterCount: segment.text.length,
    };
  });
}

// Asks for a conversation's speakers to be re-resolved now that it is finished.
//
// Enqueued inside the same transaction that closes the conversation, because
// consolidation decides what to work on from a scheduler tick and would
// otherwise be free to pick the conversation up in the gap between the two
// writes — reading provisional speaker labels that were about to be corrected.
// The unique index on (type, resource_id) collapses repeats, so re-detection
// running again over the same conversation costs nothing.
//
// Derived work must never be the reason a conversation fails to close, so a
// queue that refuses the job is logged and forgotten; the next boundary pass
// over the same conversation will try again.
function requestSpeakerResolution(database, userId, conversationId) {
  try {
    jobs.enqueue({
      userId, resourceType: 'conversation', resourceId: conversationId, type: 'resolve_speakers', priority: 30,
    }, database);
  } catch (error) {
    logger.warn('Could not queue speaker resolution for a closed conversation', {
      userId, conversationId, errorCode: error.code || 'SPEAKER_RESOLUTION_ENQUEUE_FAILED', error,
    });
  }
}

const BOUNDARY_METHOD = 'time-context-embedding';
const BOUNDARY_VERSION = '2';

// Writes one detected group as a conversation.
//
// A group that continues an existing conversation keeps that conversation's id
// rather than replacing it. Boundary detection re-runs every time new speech
// lands, and a still-open conversation is re-detected each time; minting a new
// id would discard its live insight and break every reference a client holds
// while the recording is still going.
function persistGroup(database, userId, group, state, { inheritId = null, characters = 0 } = {}) {
  const id = inheritId || group.id;
  if (inheritId) {
    database.prepare(`UPDATE conversations SET started_at=?,ended_at=?,state=?,boundary_method=?,boundary_score=?,
      boundary_version=?,insight_characters=MIN(insight_characters,?),updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE id=? AND user_id=?`).run(group.startedAt, group.endedAt, state, BOUNDARY_METHOD,
      group.boundaryScore ?? null, BOUNDARY_VERSION, characters, id, userId);
  } else {
    database.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_score,boundary_version)
      VALUES (?,?,?,?,?,?,?,?)`).run(id, userId, group.startedAt, group.endedAt, state, BOUNDARY_METHOD,
      group.boundaryScore ?? null, BOUNDARY_VERSION);
  }
  membership.assignSegments(database, userId, id, group.segmentIds);
  membership.rebuildConversationSpeakers(database, userId, id);
  if (state === 'closed') requestSpeakerResolution(database, userId, id);
  return id;
}

async function handle(job) {
  const db = getDatabase();
  const config = processingSettings.get();
  const sessions = db.prepare(`SELECT DISTINCT c.session_id FROM audio_chunks c JOIN transcript_segments t ON t.chunk_id=c.id
    WHERE t.user_id=? AND t.conversation_id IS NULL`).all(job.user_id);
  let created = 0;
  let continued = 0;
  let closed = 0;
  db.transaction(() => {
    for (const { session_id: sessionId } of sessions) {
      const open = db.prepare(`SELECT c.* FROM conversations c WHERE c.user_id=? AND c.state='open'
        AND EXISTS (SELECT 1 FROM transcript_segments t JOIN audio_chunks ac ON ac.id=t.chunk_id WHERE t.conversation_id=c.id AND ac.session_id=?)
        ORDER BY c.ended_at DESC LIMIT 1`).get(job.user_id, sessionId);
      let existing = [];
      if (open) {
        existing = db.prepare('SELECT * FROM transcript_segments WHERE conversation_id=? AND user_id=? ORDER BY started_at').all(open.id, job.user_id);
      }
      const unassigned = db.prepare(`SELECT t.* FROM transcript_segments t JOIN audio_chunks c ON c.id=t.chunk_id
        WHERE t.user_id=? AND t.conversation_id IS NULL AND c.session_id=? ORDER BY t.started_at`).all(job.user_id, sessionId);
      const segments = [...existing, ...unassigned].sort((a, b) => Date.parse(a.started_at) - Date.parse(b.started_at));
      if (!segments.length) continue;
      const characterCounts = new Map(segments.map((segment) => [segment.id, segment.text.length]));
      // The group that still contains the open conversation's earliest segment
      // is its continuation and keeps its identity; any further group is new.
      const anchorSegmentId = existing.length ? existing[0].id : null;
      let anchorClaimed = false;
      const groups = boundary.detectBoundaries(blocksForSegments(db, segments), {
        hardGapMs: config.conversationHardGapMs, softGapMs: config.conversationSoftGapMs,
        minimumDurationMs: config.conversationMinimumMs, valleyQuantile: config.conversationValleyQuantile,
        semanticSimilarityThreshold: config.conversationSemanticSimilarityThreshold,
        semanticValleyProminence: config.conversationSemanticValleyProminence,
        semanticContextSegments: config.conversationSemanticContextSegments,
        maximumDurationMs: config.conversationMaximumMs,
        maximumCharacters: config.conversationMaximumCharacters,
      });
      groups.forEach((group, index) => {
        const quiet = Date.now() - Date.parse(group.endedAt) >= config.conversationQuietCloseMs;
        const inherits = !anchorClaimed && anchorSegmentId !== null && group.segmentIds.includes(anchorSegmentId);
        if (inherits) anchorClaimed = true;
        persistGroup(db, job.user_id, group, index < groups.length - 1 || quiet ? 'closed' : 'open', {
          inheritId: inherits ? open.id : null,
          characters: group.segmentIds.reduce((sum, segmentId) => sum + (characterCounts.get(segmentId) || 0), 0),
        });
        if (inherits) continued += 1; else created += 1;
      });
      // Detection dropped the conversation's anchor segment into no group at
      // all, which can only mean its segments are gone. Nothing references it
      // any more, so remove the empty shell rather than leave it open forever.
      if (open && !anchorClaimed) db.prepare('DELETE FROM conversations WHERE id=? AND user_id=?').run(open.id, job.user_id);
    }
    // The sweep that closes a conversation nothing is feeding any more. Its ids
    // are selected before the update rather than after, because once the state
    // has changed there is no longer anything that distinguishes the rows this
    // pass closed from those closed earlier — and each one needs its speakers
    // re-resolved.
    const quietBefore = new Date(Date.now() - config.conversationQuietCloseMs).toISOString();
    const stale = db.prepare(`SELECT id FROM conversations
      WHERE user_id=? AND state='open' AND ended_at<=?`).all(job.user_id, quietBefore).map((row) => row.id);
    for (const conversationId of stale) {
      db.prepare(`UPDATE conversations SET state='closed',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
        WHERE id=? AND user_id=?`).run(conversationId, job.user_id);
      requestSpeakerResolution(db, job.user_id, conversationId);
    }
    closed = stale.length;
  })();
  // Only when something moved. Boundary detection runs whenever new speech
  // arrives and usually has nothing to do, so an unconditional line would say
  // "nothing happened" all day and drown out the times it did.
  if (created || continued || closed) {
    logger.info('Grouped speech into conversations', { userId: job.user_id, started: created, extended: continued, finished: closed });
  }
  return { created, continued, closed };
}

module.exports = { handle, blocksForSegments, persistGroup };
