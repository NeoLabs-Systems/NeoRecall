'use strict';

const { getDatabase } = require('../../db/database');
const processingSettings = require('../settings/processing_settings_service');

// Which finished conversations belong to one real-world occasion, and when that
// occasion is over.
//
// Conversation boundaries are provisional groupings of speech, not occasions. A
// three-minute pause cuts the stream mid-meeting, so one sitting routinely
// arrives as several conversations. Consolidating each on its own produced what
// it had to produce: several memory cards, minutes apart, describing one thing.
//
// Two questions decide that, and both are arithmetic over timestamps rather than
// anything a model should be asked: which conversations form the chain, and
// whether the chain can still grow. Nothing here reads transcripts or merges
// anything — it only decides what is shown to consolidation as one input.

function gapMs(earlier, later) {
  return Date.parse(later.startedAt ?? later.started_at) - Date.parse(earlier.endedAt ?? earlier.ended_at);
}

// The consecutive run of candidates that belong to one occasion.
//
// Candidates arrive oldest-first. The chain starts at the oldest — the backlog
// has to drain in order — and takes each following conversation while it comes
// from the same recording and follows closely enough to be the same sitting.
// The caller's own limits still apply: they bound what one request may carry,
// and a chain cut by them is finished by the continuation mechanism instead.
function chain(conversations, limits) {
  const { occasionGapMs, maxConversations, maxCharacters, maxSpanMs } = limits;
  const chained = [];
  let characters = 0;
  for (const conversation of conversations) {
    const previous = chained.at(-1);
    if (previous) {
      if (chained.length >= maxConversations) break;
      if (conversation.sessionId !== previous.sessionId) break;
      if (gapMs(previous, conversation) > occasionGapMs) break;
      if (characters + conversation.characters > maxCharacters) break;
      if (Date.parse(conversation.endedAt) - Date.parse(chained[0].startedAt) > maxSpanMs) break;
    }
    chained.push(conversation);
    characters += conversation.characters;
  }
  return { conversations: chained, characters };
}

// The first conversation of the same recording that starts after the chain ends.
//
// A chain member that is still open, still being transcribed or still waiting
// for speaker resolution is not a candidate yet, so it cannot appear in the
// chain — but it may still be part of the occasion, and writing the chain up
// without it is exactly how one sitting became several cards. Quarantined
// conversations are excluded: they will never become candidates, so waiting for
// one would hold the occasion back forever.
function nextInSession(userId, sessionId, endedAt, database = getDatabase()) {
  if (!sessionId) return null;
  return database.prepare(`SELECT c.id,c.started_at startedAt,c.ended_at endedAt,c.state
    FROM conversations c
    WHERE c.user_id=? AND c.quarantined_at IS NULL AND c.started_at>?
      AND (SELECT ac.session_id FROM transcript_segments ts JOIN audio_chunks ac ON ac.id=ts.chunk_id
        WHERE ts.conversation_id=c.id ORDER BY ts.started_at LIMIT 1)=?
    ORDER BY c.started_at LIMIT 1`).get(userId, endedAt, sessionId) || null;
}

// Whether the recording is still running, and could still add to this occasion.
//
// A stopped recording is proof the occasion is over, and nothing waits then: a
// conversation that just ended is exactly the one someone is about to look for.
// While audio is still arriving there is no such proof, so the occasion has to
// go quiet first. Upload time is the right clock here rather than speech time —
// it says when the server last heard from the device, which is what "still
// recording" means.
function receivingAudio(userId, sessionId, since, database = getDatabase()) {
  if (!sessionId) return false;
  return Boolean(database.prepare(`SELECT 1 FROM audio_chunks
    WHERE user_id=? AND session_id=? AND uploaded_at>? LIMIT 1`).get(userId, sessionId, since));
}

// Whether a chain may be written up now.
//
// `waited` is the escape hatch and it is unconditional: an always-on recording
// never stops and an occasion can outlast any patience, so a chain that has been
// held this long is written up with what it has. Later fragments then reach the
// existing continuation mechanism, which folds them into that same card.
function readiness(userId, chained, options = processingSettings.get(), database = getDatabase(), now = Date.now()) {
  const last = chained.at(-1);
  const sessionId = last.sessionId;
  const heldSince = Date.parse(chained[0].endedAt);
  if (now - heldSince >= options.memoryOccasionMaxWaitMs) return { ready: true, reason: 'waited' };

  const successor = nextInSession(userId, sessionId, last.endedAt, database);
  if (successor) {
    // A successor beyond the occasion gap proves the occasion ended; one inside
    // it is still part of this sitting and has to be waited for.
    if (gapMs(last, successor) > options.memoryOccasionGapMs) return { ready: true, reason: 'occasion_ended' };
    return {
      ready: false,
      reason: 'occasion_unsettled',
      consolidateAfter: new Date(heldSince + options.memoryOccasionMaxWaitMs).toISOString(),
    };
  }

  const quietSince = new Date(now - options.memorySettleMs).toISOString();
  if (!receivingAudio(userId, sessionId, quietSince, database)) return { ready: true, reason: 'recording_stopped' };
  const settledAt = Date.parse(last.endedAt) + options.memorySettleMs;
  if (now >= settledAt) return { ready: true, reason: 'settled' };
  return {
    ready: false,
    reason: 'occasion_unsettled',
    consolidateAfter: new Date(Math.min(settledAt, heldSince + options.memoryOccasionMaxWaitMs)).toISOString(),
  };
}

module.exports = { chain, readiness, nextInSession, receivingAudio };
