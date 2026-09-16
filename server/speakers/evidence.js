'use strict';

const vectors = require('../transcription/speaker_embeddings');

// Everything the resolver needs about one conversation, read once.
//
// The unit here is the session speaker cluster, not the individual turn.
// Diarization already pools a voice's speech into one fingerprint per chunk
// (see poolBySpeaker), and the transcribe worker writes that identical vector
// onto every turn row for that chunk and cluster — so a conversation's turn
// rows hold perhaps twenty copies of each distinct measurement. Clustering
// turns would compare the same vectors against each other over and over and
// weight the result by who talked most, which is not the question being asked.
// One item per cluster, carrying its distinct per-chunk measurements, is both
// the smaller computation and the more honest one.

// A voice heard across two hundred chunks is not two hundred times better
// described than one heard across thirty; the measurements repeat. Comparing
// every one of them against every one of another voice's is what makes a long
// conversation expensive, so each voice contributes an evenly spaced sample of
// what it has. Evenly spaced rather than the first N, because the beginning of a
// conversation is not representative of it — a voice that changes position or
// microphone halfway through would otherwise be described only by where it
// started.
const MAXIMUM_MEASUREMENTS = 32;

function sample(embeddings) {
  if (embeddings.length <= MAXIMUM_MEASUREMENTS) return embeddings;
  const step = embeddings.length / MAXIMUM_MEASUREMENTS;
  const picked = [];
  for (let index = 0; index < MAXIMUM_MEASUREMENTS; index += 1) {
    picked.push(embeddings[Math.min(embeddings.length - 1, Math.floor(index * step))]);
  }
  return picked;
}

// Turn rows are joined to transcript segments rather than read directly,
// because a turn belongs to a chunk and a chunk is not confined to one
// conversation. The segment is what carries conversation membership, and the
// millisecond range is what ties a turn to the speech that was actually
// assigned. The DISTINCT is doing real work: many segments share one turn.
const TURNS_FOR_CONVERSATION = `SELECT DISTINCT st.id,st.cluster_id,st.embedding,st.voiceprint_id,
    st.start_ms,st.end_ms,st.overlapping_speech,
    c.session_id,c.source_id,c.monotonic_offset_ms,
    r.corrected_started_at,
    json_extract(rs.metadata_json,'$.speaker.key') declared_key
  FROM transcript_segments t
  JOIN speaker_turns st ON st.chunk_id=t.chunk_id AND st.cluster_id=t.speaker_cluster_id
    AND st.start_ms<=t.chunk_end_ms AND st.end_ms>=t.chunk_start_ms
  JOIN audio_chunks c ON c.id=t.chunk_id
  JOIN recording_sessions r ON r.id=c.session_id
  JOIN recording_sources rs ON rs.id=c.source_id
  WHERE t.conversation_id=? AND t.user_id=? AND t.speaker_cluster_id IS NOT NULL`;

// Two turns from different recordings are only comparable on one timeline, so
// each turn's chunk-relative milliseconds are lifted onto the session's
// corrected start. This is the same arithmetic transcribe_handler does when it
// persists a segment; it is repeated here rather than stored because the turn
// table deliberately keeps chunk-relative times.
function absoluteRange(row) {
  const base = Date.parse(row.corrected_started_at) + (row.monotonic_offset_ms || 0);
  return { startMs: base + row.start_ms, endMs: base + row.end_ms };
}

function collect(database, userId, conversationId) {
  const rows = database.prepare(TURNS_FOR_CONVERSATION).all(conversationId, userId);
  const byCluster = new Map();
  for (const row of rows) {
    if (!byCluster.has(row.cluster_id)) {
      byCluster.set(row.cluster_id, {
        id: row.cluster_id,
        sessionId: row.session_id,
        embeddings: [],
        spans: [],
        speechMs: 0,
        voiceprintIds: new Set(),
        declaredKeys: new Set(),
      });
    }
    const item = byCluster.get(row.cluster_id);
    const span = absoluteRange(row);
    item.spans.push({ ...span, sourceId: row.source_id });
    item.speechMs += Math.max(0, row.end_ms - row.start_ms);
    if (row.voiceprint_id) item.voiceprintIds.add(row.voiceprint_id);
    if (row.declared_key) item.declaredKeys.add(row.declared_key);
    // Speech the diarizer marked as two people talking at once is a blend of
    // both of them. It still counts as this cluster's speech for labelling, but
    // it must never become evidence about what the voice sounds like.
    if (row.overlapping_speech || !row.embedding) continue;
    const embedding = vectors.fromBuffer(row.embedding);
    // One vector per distinct measurement. Copies of the same pooled chunk
    // fingerprint would otherwise weight the average by talkativeness.
    if (!item.embeddings.some((existing) => vectors.cosine(existing, embedding) > 0.999999)) {
      item.embeddings.push(embedding);
    }
  }
  return [...byCluster.values()].map((item) => ({ ...item, embeddings: sample(item.embeddings) }));
}

// Whether two clusters were heard speaking over each other on the same
// recording, which is the one thing that proves they are different people.
//
// Scoped to a single source deliberately. Two microphones in one room hear the
// same person continuously overlapping themselves, and treating that as proof
// of difference would forbid exactly the merge this pass exists to make.
function overlaps(first, second, minimumMs) {
  for (const left of first.spans) {
    for (const right of second.spans) {
      if (left.sourceId !== right.sourceId) continue;
      const shared = Math.min(left.endMs, right.endMs) - Math.max(left.startMs, right.startMs);
      if (shared > minimumMs) return true;
    }
  }
  return false;
}

// Whether two voices were declared to be different people by the recordings
// that carried them. A source that knows who is speaking outranks any similarity
// score: two named streams are two people even when they sound alike, and one
// stream is one person even when a bad measurement says otherwise.
function declaredDifferently(first, second) {
  if (!first.declaredKeys.size || !second.declaredKeys.size) return false;
  return [...first.declaredKeys].some((key) => !second.declaredKeys.has(key));
}

function declaredSame(first, second) {
  if (first.declaredKeys.size !== 1 || second.declaredKeys.size !== 1) return false;
  return [...first.declaredKeys][0] === [...second.declaredKeys][0];
}

module.exports = {
  collect, overlaps, absoluteRange, declaredDifferently, declaredSame, MAXIMUM_MEASUREMENTS,
};
