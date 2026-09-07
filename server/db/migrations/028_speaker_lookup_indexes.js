'use strict';

// Indexes for the two questions speaker identity asks constantly and could not
// answer without reading everything.
//
// `speaker_turns` was indexed only by chunk, but almost nothing looks a turn up
// by chunk. Resolving which voice a cluster belongs to, repointing turns when two
// clusters are folded together, counting how often a person was heard, attaching
// turns to a person — every one of those filters on `cluster_id` or
// `voiceprint_id`, and every one of them was a full scan of every turn the user
// had ever recorded. The worst of them, stickyVoiceprintForCluster, runs on the
// transcription path for each chunk of audio, so the cost grew with the size of
// the archive on the one path that has audio waiting to be deleted behind it.
//
// `transcript_segments` had the same shape of gap for `conversation_id`. Reading
// a conversation's segments fell back to the (user_id, started_at) index and
// then discarded most of what it read, which affects rebuilding a conversation's
// speaker labels, gathering its material for the model, and the new per
// conversation resolution pass.
//
// Both are plain covering-ish indexes on existing columns: no data is moved and
// no behaviour changes, so this is safe to apply to a live database.
function up(db) {
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_speaker_turns_cluster ON speaker_turns(user_id, cluster_id);
    CREATE INDEX IF NOT EXISTS idx_speaker_turns_voiceprint ON speaker_turns(voiceprint_id);
    CREATE INDEX IF NOT EXISTS idx_segments_conversation ON transcript_segments(conversation_id, speaker_cluster_id);
  `);
}

module.exports = { up };
