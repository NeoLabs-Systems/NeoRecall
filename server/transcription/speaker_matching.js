'use strict';

const crypto = require('node:crypto');
const processingSettings = require('../services/settings/processing_settings_service');
const vectors = require('./speaker_embeddings');

const modelName = 'wespeaker_en_voxceleb_CAM++_LM';

function storeVector(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }

/// The voiceprint a cluster's turns currently stick to, if any.
///
/// "Sticky" means most-assigned-and-most-recent, not merely first-seen: a
/// cluster can carry a few stray turns from a bad early match, and those must
/// not outvote the voiceprint the cluster has actually been resolving to.
/// Shared by voice matching (to keep resolving a session's cluster the way it
/// already has) and by consolidation's speaker naming (to find the voice a
/// newly identified person actually belongs to) — one query, two callers.
function stickyVoiceprintForCluster(database, { userId, clusterId }) {
  return database.prepare(`SELECT v.*,COUNT(*) assignment_count,MAX(st.created_at) last_assignment_at
    FROM speaker_turns st JOIN voiceprints v ON v.id=st.voiceprint_id
    WHERE st.cluster_id=? AND st.user_id=? AND v.matching_enabled=1
    GROUP BY v.id ORDER BY assignment_count DESC,last_assignment_at DESC LIMIT 1`).get(clusterId, userId) || null;
}

/// Resolves the speaker cluster (a session-scoped voice identity) an embedding
/// belongs to, creating one if none matches confidently.
///
/// Diarization runs independently on every chunk, so a continuous speaker
/// crossing a chunk boundary is re-segmented from scratch: nothing about the
/// voice changed, but the fresh embedding can drift below the plain matching
/// threshold. `continuity` — the cluster active at the end of the previous
/// chunk for this same audio component, and the gap since it — lets that
/// cluster win at a relaxed bar instead of splintering into a new one. It only
/// ever breaks a near-tie: a continuity candidate is accepted only when no
/// other cluster clearly scores higher, so a real speaker change right at the
/// boundary still resolves on its own merits.
///
/// Outside continuity, a match additionally needs a margin over the runner-up.
/// A single fixed threshold with no margin occasionally lets a distinct new
/// speaker's embedding score just above it against some unrelated existing
/// cluster purely by chance, silently reassigning their speech to someone else;
/// the margin is what closes that gap, mirroring cross-recording voice
/// matching below.
function resolveCluster(database, { userId, sessionId, embedding, continuity = null }) {
  const config = processingSettings.get();
  const rows = database.prepare('SELECT * FROM speaker_clusters WHERE user_id=? AND session_id=? AND centroid_embedding IS NOT NULL').all(userId, sessionId);
  const ranked = vectors.rank(embedding, rows);
  const best = ranked[0];
  let cluster = null;
  if (continuity && continuity.clusterId && continuity.gapMs <= config.speakerContinuityGapMs) {
    const anchor = ranked.find((item) => item.row.id === continuity.clusterId);
    if (anchor && anchor.score >= config.speakerClusterContinuityThreshold
      && (!best || best.row.id === anchor.row.id || best.score - anchor.score <= config.speakerClusterMargin)) {
      cluster = anchor.row;
    }
  }
  if (!cluster) {
    const runnerUp = ranked[1];
    cluster = best && best.score >= config.speakerClusterThreshold
      && (!runnerUp || best.score - runnerUp.score >= config.speakerClusterMargin) ? best.row : null;
  }
  if (!cluster) {
    const ordinal = database.prepare('SELECT COALESCE(MAX(local_ordinal),0)+1 ordinal FROM speaker_clusters WHERE session_id=?').get(sessionId).ordinal;
    const id = crypto.randomUUID();
    database.prepare(`INSERT INTO speaker_clusters
      (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
      VALUES (?,?,?,?,?,?,?,1)`).run(id, userId, sessionId, ordinal, storeVector(embedding), modelName, embedding.length);
    return database.prepare('SELECT * FROM speaker_clusters WHERE id=?').get(id);
  }
  const centroid = vectors.updateCentroid(vectors.fromBuffer(cluster.centroid_embedding), cluster.sample_count, embedding);
  database.prepare(`UPDATE speaker_clusters SET centroid_embedding=?,sample_count=sample_count+1,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(storeVector(centroid), cluster.id);
  return { ...cluster, centroid_embedding: storeVector(centroid), sample_count: cluster.sample_count + 1 };
}

function resolveVoiceprint(database, { userId, clusterId, embedding, enabled }) {
  if (!enabled) return null;
  const assigned = clusterId ? stickyVoiceprintForCluster(database, { userId, clusterId }) : null;
  if (assigned) {
    const centroid = vectors.updateCentroid(vectors.fromBuffer(assigned.centroid_embedding), assigned.sample_count, embedding);
    database.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=sample_count+1,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(storeVector(centroid), assigned.id);
    return { ...assigned, centroid_embedding: storeVector(centroid), sample_count: assigned.sample_count + 1 };
  }
  const rows = database.prepare('SELECT * FROM voiceprints WHERE user_id=? AND matching_enabled=1 AND embedding_model=? AND embedding_dimensions=?')
    .all(userId, modelName, embedding.length);
  const ranked = vectors.rank(embedding, rows);
  const best = ranked[0]; const runnerUp = ranked[1];
  const config = processingSettings.get();
  let voiceprint = best && best.score >= config.voiceMatchThreshold && (!runnerUp || best.score - runnerUp.score >= config.voiceMatchMargin) ? best.row : null;
  if (!voiceprint) {
    const id = crypto.randomUUID();
    database.prepare(`INSERT INTO voiceprints
      (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count) VALUES (?,?,?,?,?,1)`)
      .run(id, userId, storeVector(embedding), modelName, embedding.length);
    return database.prepare('SELECT * FROM voiceprints WHERE id=?').get(id);
  }
  const centroid = vectors.updateCentroid(vectors.fromBuffer(voiceprint.centroid_embedding), voiceprint.sample_count, embedding);
  database.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=sample_count+1,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(storeVector(centroid), voiceprint.id);
  return { ...voiceprint, centroid_embedding: storeVector(centroid), sample_count: voiceprint.sample_count + 1 };
}

module.exports = { resolveCluster, resolveVoiceprint, stickyVoiceprintForCluster, modelName };
