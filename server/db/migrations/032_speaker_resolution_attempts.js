'use strict';

// What the deferred speaker pass concluded about a conversation, so a
// conclusion of "nobody" is not read as "never asked".
//
// The sweep that finds conversations still waiting for the pass read its answer
// from the transcript alone: a turn attached to no durable person meant the pass
// had not run yet. That is only true while every conversation has a resolvable
// answer. Speech too short to enroll anyone, or a voice that matches nothing
// above the bar, resolves to nobody and stays that way — so the sweep queued the
// same conversation on every maintenance tick, forever, and each job completed
// without changing the condition that selected it.
//
// One row per conversation records that the pass ran and what it saw. Sweeping
// skips a conversation whose recorded answer still applies, and picks it up
// again once something that could change the answer has changed: the set of
// enrolled voices, the tunable thresholds, the version of the pass itself, or
// the conversation's own speech.

function up(db) {
  db.exec(`
    CREATE TABLE conversation_speaker_resolutions (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      world_signature TEXT NOT NULL,
      evidence_turns INTEGER NOT NULL,
      unresolved_turns INTEGER NOT NULL,
      outcome TEXT NOT NULL,
      resolved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX idx_speaker_resolutions_user ON conversation_speaker_resolutions(user_id, world_signature);
  `);
}

module.exports = { up };
