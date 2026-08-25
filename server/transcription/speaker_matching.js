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

/// Folds one cluster into another, because they turned out to be one voice.
///
/// The matcher can split a person in two — a noisy turn misses the threshold and
/// starts a second identity for someone already present. Left alone that
/// compounds: every later turn now resembles both halves, so no single match
/// stands out, and a third identity appears. Merging on discovery is what stops
/// the split from breeding, and it repairs recordings already fragmented as
/// their later chunks arrive.
///
/// Everything pointing at the absorbed cluster is repointed first; the row is
/// only removed once nothing references it.
function mergeClusters(database, { userId, target, source }) {
  const targetCentroid = vectors.fromBuffer(target.centroid_embedding);
  const sourceCentroid = vectors.fromBuffer(source.centroid_embedding);
  const total = target.sample_count + source.sample_count;
  const centroid = new Float32Array(targetCentroid.length);
  for (let i = 0; i < centroid.length; i += 1) {
    centroid[i] = (targetCentroid[i] * target.sample_count + sourceCentroid[i] * source.sample_count) / total;
  }
  database.prepare('UPDATE transcript_segments SET speaker_cluster_id=? WHERE speaker_cluster_id=? AND user_id=?').run(target.id, source.id, userId);
  database.prepare('UPDATE speaker_turns SET cluster_id=? WHERE cluster_id=? AND user_id=?').run(target.id, source.id, userId);
  // A conversation may already list both halves; the primary key forbids a
  // duplicate row, so the redundant one is dropped rather than repointed.
  database.prepare(`UPDATE OR REPLACE conversation_speakers SET cluster_id=? WHERE cluster_id=?`).run(target.id, source.id);
  database.prepare(`UPDATE speaker_clusters SET centroid_embedding=?,sample_count=?,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(storeVector(centroid), total, target.id);
  database.prepare('DELETE FROM speaker_clusters WHERE id=? AND user_id=?').run(source.id, userId);
  return database.prepare('SELECT * FROM speaker_clusters WHERE id=?').get(target.id);
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
/// Outside continuity, a match may additionally need a margin over the runner-up
/// — but only when that runner-up is itself below the threshold.
///
/// The margin exists for one situation: a genuinely new speaker whose embedding
/// grazes the threshold against some unrelated cluster by chance. There the
/// runner-up sits just below the bar, the two readings are equally weak, and
/// refusing both is right.
///
/// Applying it to a runner-up that is *above* the threshold inverts its purpose.
/// Two clusters that both match strongly are not an ambiguity to refuse; they
/// are almost always one person the matcher split earlier, and refusing the
/// match creates a third copy. That is a loop which accelerates: the more times a
/// voice has been split, the more strong near-ties it produces, and the faster it
/// splits again. It is why a familiar voice could accumulate a dozen entries in
/// one recording. Above the threshold the best match simply wins, and the two are
/// merged.
function resolveCluster(database, { userId, sessionId, embedding, continuity = null, durationMs = null }) {
  const config = processingSettings.get();
  // Speech too short to fingerprint may join a voice that already exists, but it
  // may not invent one, and it may not drag a centroid toward its own noise.
  const reliable = durationMs === null || durationMs >= config.speakerMinimumTurnMs;
  const rows = database.prepare('SELECT * FROM speaker_clusters WHERE user_id=? AND session_id=? AND centroid_embedding IS NOT NULL').all(userId, sessionId);
  const ranked = vectors.rank(embedding, rows);
  const best = ranked[0];
  const runnerUp = ranked[1];
  let cluster = null;
  if (continuity && continuity.clusterId && continuity.gapMs <= config.speakerContinuityGapMs) {
    const anchor = ranked.find((item) => item.row.id === continuity.clusterId);
    if (anchor && anchor.score >= config.speakerClusterContinuityThreshold
      && (!best || best.row.id === anchor.row.id || best.score - anchor.score <= config.speakerClusterMargin)) {
      cluster = anchor.row;
    }
  }
  if (!cluster && best && best.score >= config.speakerClusterThreshold) {
    const contested = runnerUp && runnerUp.score < config.speakerClusterThreshold
      && best.score - runnerUp.score < config.speakerClusterMargin;
    if (!contested) cluster = best.row;
  }
  if (cluster && runnerUp && runnerUp.score >= config.speakerClusterThreshold && runnerUp.row.id !== cluster.id) {
    const alike = vectors.cosine(vectors.fromBuffer(cluster.centroid_embedding), vectors.fromBuffer(runnerUp.row.centroid_embedding));
    if (alike >= config.speakerClusterMergeThreshold) {
      cluster = mergeClusters(database, { userId, target: cluster, source: runnerUp.row });
    }
  }
  if (!cluster) {
    if (!reliable) return null;
    const ordinal = database.prepare('SELECT COALESCE(MAX(local_ordinal),0)+1 ordinal FROM speaker_clusters WHERE session_id=?').get(sessionId).ordinal;
    const id = crypto.randomUUID();
    database.prepare(`INSERT INTO speaker_clusters
      (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
      VALUES (?,?,?,?,?,?,?,1)`).run(id, userId, sessionId, ordinal, storeVector(embedding), modelName, embedding.length);
    return database.prepare('SELECT * FROM speaker_clusters WHERE id=?').get(id);
  }
  if (!reliable) return cluster;
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

module.exports = { resolveCluster, resolveVoiceprint, stickyVoiceprintForCluster, mergeClusters, modelName };
