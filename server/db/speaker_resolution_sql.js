'use strict';

// Resolves a transcript_segments row `t` to a display-ready speaker name:
// voiceprint_name (cross-recording identity) or local_label (per-conversation label).
const SPEAKER_NAME_COLUMNS = 'v.display_name voiceprint_name,cs.local_label';

const SPEAKER_NAME_JOINS = `LEFT JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id AND st.start_ms<=t.chunk_start_ms AND st.end_ms>=t.chunk_end_ms
    LEFT JOIN voiceprints v ON v.id=st.voiceprint_id
    LEFT JOIN conversation_speakers cs ON cs.conversation_id=t.conversation_id AND cs.cluster_id=t.speaker_cluster_id`;

module.exports = { SPEAKER_NAME_COLUMNS, SPEAKER_NAME_JOINS };
