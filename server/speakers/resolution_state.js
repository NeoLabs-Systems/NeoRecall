'use strict';

const crypto = require('node:crypto');
const processingSettings = require('../services/settings/processing_settings_service');
const settings = require('../services/settings/settings_service');

// Whether the deferred speaker pass still has anything new to say about a
// conversation.
//
// The pass may legitimately end with speech attached to nobody: a fingerprint
// pooled from too little speech cannot enroll a person, and a voice that
// resembles an enrolled one without clearing the bar is deliberately left
// alone rather than guessed at. That is a finished answer, not an unfinished
// one, and it does not change on its own — so re-running the pass against the
// same evidence and the same enrolled voices can only reach it again.
//
// What may change the answer is recorded here as two comparable facts: the
// world the pass matches against, and the speech it matches. Either moving is
// what earns a conversation another look.

// Bumped when the pass itself changes what it would conclude from unchanged
// input — new grouping rules, a different enrollment policy. A deploy that
// changes the answer must be able to invalidate answers recorded before it,
// and the schema cannot see code.
const RESOLUTION_VERSION = 1;

// The tunables the pass actually reads. Listed rather than hashed wholesale:
// the settings table also carries transcription and memory limits, and folding
// those in would re-queue every unresolved conversation whenever an unrelated
// knob moved.
const TUNABLES = Object.freeze([
  'speakerMinimumTurnMs',
  'speakerClusterMergeThreshold',
  'speakerClusterMargin',
  'voiceMatchThreshold',
  'voiceMatchMargin',
  'voiceEnrollFloor',
  'voiceEnrollMinimumMs',
]);

// The turns a conversation's speech consists of, counted the same way the sweep
// looks for unresolved ones. Kept next to the signature so both the sweep's SQL
// and the recording path measure the same thing.
const EVIDENCE_TURNS_SQL = `SELECT COUNT(*) FROM transcript_segments t JOIN speaker_turns st
  ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
  WHERE t.conversation_id=%s`;
const UNRESOLVED_TURNS_SQL = `SELECT COUNT(*) FROM transcript_segments t JOIN speaker_turns st
  ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
  WHERE t.conversation_id=%s AND st.voiceprint_id IS NULL`;

function evidenceTurnsSql(conversationRef) { return EVIDENCE_TURNS_SQL.replace('%s', conversationRef); }
function unresolvedTurnsSql(conversationRef) { return UNRESOLVED_TURNS_SQL.replace('%s', conversationRef); }

function evidenceCounts(database, conversationId) {
  const row = database.prepare(`SELECT (${evidenceTurnsSql('?')}) turns, (${unresolvedTurnsSql('?')}) unresolved`)
    .get(conversationId, conversationId);
  return { turns: row.turns, unresolved: row.unresolved };
}

// Everything outside the conversation that the pass matches against.
//
// The enrolled voices are read as identity and eligibility only — which people
// exist, what the user called them, whether they may be matched at all. What a
// voiceprint's centroid has drifted to is deliberately left out, even though it
// does affect matching: reinforcement is an effect of resolution passes, so
// letting it invalidate recorded answers would have two conversations queue each
// other forever, which is the failure this exists to end. A voice genuinely
// enrolled, deleted, merged, renamed or re-enabled still moves this.
function worldSignature(database, userId) {
  const voiceprints = database.prepare(`SELECT id,display_name,display_name_source,entity_id,matching_enabled,
    embedding_model,embedding_dimensions FROM voiceprints WHERE user_id=? ORDER BY id`).all(userId);
  const limits = processingSettings.get();
  const user = settings.get(userId);
  const material = JSON.stringify({
    version: RESOLUTION_VERSION,
    recurringSpeakerMatching: Boolean(user.recurringSpeakerMatching),
    tunables: TUNABLES.map((key) => limits[key]),
    voiceprints: voiceprints.map((row) => [
      row.id, row.display_name, row.display_name_source, row.entity_id,
      row.matching_enabled, row.embedding_model, row.embedding_dimensions,
    ]),
  });
  return crypto.createHash('sha256').update(material).digest('hex');
}

// Records what one pass concluded. Overwrites the previous answer: only the
// most recent one can still apply.
function record(database, userId, conversationId, outcome) {
  const counts = evidenceCounts(database, conversationId);
  database.prepare(`INSERT INTO conversation_speaker_resolutions
    (conversation_id,user_id,world_signature,evidence_turns,unresolved_turns,outcome)
    VALUES (?,?,?,?,?,?)
    ON CONFLICT(conversation_id) DO UPDATE SET user_id=excluded.user_id,world_signature=excluded.world_signature,
      evidence_turns=excluded.evidence_turns,unresolved_turns=excluded.unresolved_turns,outcome=excluded.outcome,
      resolved_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`)
    .run(conversationId, userId, worldSignature(database, userId), counts.turns, counts.unresolved, outcome);
}

module.exports = {
  worldSignature, evidenceCounts, record, evidenceTurnsSql, unresolvedTurnsSql, RESOLUTION_VERSION, TUNABLES,
};
