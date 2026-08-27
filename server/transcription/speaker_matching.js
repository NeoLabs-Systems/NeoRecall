'use strict';

const crypto = require('node:crypto');
const processingSettings = require('../services/settings/processing_settings_service');
const vectors = require('./speaker_embeddings');

const modelName = 'wespeaker_en_voxceleb_CAM++_LM';

function storeVector(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }
// Voiceprints are sealed at rest; session clusters are not. See voiceprint_storage.js.
const voiceprintStorage = require('./voiceprint_storage');

// The voiceprint a cluster's turns currently stick to, if any.
//
// "Sticky" means most-assigned-and-most-recent, not merely first-seen: a
// cluster can carry a few stray turns from a bad early match, and those must
// not outvote the voiceprint the cluster has actually been resolving to.
// Shared by voice matching (to keep resolving a session's cluster the way it
// already has) and by consolidation's speaker naming (to find the voice a
// newly identified person actually belongs to) — one query, two callers.
function stickyVoiceprintForCluster(database, { userId, clusterId }) {
  return database.prepare(`SELECT v.*,COUNT(*) assignment_count,MAX(st.created_at) last_assignment_at
    FROM speaker_turns st JOIN voiceprints v ON v.id=st.voiceprint_id
    WHERE st.cluster_id=? AND st.user_id=? AND v.matching_enabled=1
    GROUP BY v.id ORDER BY assignment_count DESC,last_assignment_at DESC LIMIT 1`).get(clusterId, userId) || null;
}

// Folds one cluster into another when they turn out to be one voice. Everything
// pointing at the absorbed cluster is repointed first; the row is removed last.
function mergeClusters(database, { userId, target, source }) {
  const affectedConversations = database.prepare(`SELECT DISTINCT conversation_id FROM transcript_segments
    WHERE user_id=? AND conversation_id IS NOT NULL AND speaker_cluster_id IN (?,?)`)
    .all(userId, target.id, source.id).map((row) => row.conversation_id);
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
  const membership = require('../services/conversations/conversation_membership_service');
  for (const conversationId of affectedConversations) membership.rebuildConversationSpeakers(database, userId, conversationId);
  return database.prepare('SELECT * FROM speaker_clusters WHERE id=?').get(target.id);
}

// Session clustering and recurring matching answer the same question at two
// scopes. Once two session clusters have independently resolved to one durable
// voiceprint, keeping both clusters can only create duplicate local labels. Fold
// them together immediately, while retaining every turn and transcript row.
function collapseSessionClustersByVoiceprint(database, { userId, sessionId }) {
  const clusters = database.prepare(`SELECT sc.*,st.voiceprint_id,COUNT(*) assignment_count
    FROM speaker_clusters sc
    JOIN speaker_turns st ON st.cluster_id=sc.id AND st.user_id=sc.user_id
    JOIN voiceprints v ON v.id=st.voiceprint_id AND v.matching_enabled=1
    WHERE sc.user_id=? AND sc.session_id=? AND st.voiceprint_id IS NOT NULL
    GROUP BY sc.id,st.voiceprint_id
    ORDER BY sc.local_ordinal`).all(userId, sessionId);
  const stickyByCluster = new Map();
  for (const row of clusters) {
    const current = stickyByCluster.get(row.id);
    if (!current || row.assignment_count > current.assignment_count) stickyByCluster.set(row.id, row);
  }
  const byVoiceprint = new Map();
  for (const row of stickyByCluster.values()) {
    const group = byVoiceprint.get(row.voiceprint_id) || [];
    group.push(row);
    byVoiceprint.set(row.voiceprint_id, group);
  }
  let merged = 0;
  for (const group of byVoiceprint.values()) {
    if (group.length < 2) continue;
    group.sort((left, right) => left.local_ordinal - right.local_ordinal);
    let target = group[0];
    for (const source of group.slice(1)) {
      const currentSource = database.prepare('SELECT * FROM speaker_clusters WHERE id=? AND user_id=?').get(source.id, userId);
      if (!currentSource) continue;
      target = mergeClusters(database, { userId, target, source: currentSource });
      merged += 1;
    }
  }
  return merged;
}

// Resolves the speaker cluster (a session-scoped voice identity) an embedding
// belongs to, creating one if none matches confidently. `continuity` lets the
// cluster active at the end of the previous chunk win at a relaxed bar, so a
// speaker crossing a chunk boundary isn't split by re-segmentation. The margin
// check only applies against a runner-up below the threshold; two clusters
// that both match strongly are merged instead, since that means one voice was
// split earlier rather than a genuine ambiguity.
function resolveCluster(database, { userId, sessionId, embedding, continuity = null, durationMs = null }) {
  const config = processingSettings.get();
  // Speech too short to fingerprint may join a voice that already exists, but
  // it may not invent one or drag a centroid toward its own noise.
  const reliable = durationMs === null || durationMs >= config.speakerMinimumTurnMs;
  const rows = database.prepare('SELECT * FROM speaker_clusters WHERE user_id=? AND session_id=? AND centroid_embedding IS NOT NULL').all(userId, sessionId);
  const ranked = voiceprintStorage.rankVoiceprints(embedding, rows);
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
    const centroid = vectors.updateCentroid(voiceprintStorage.readCentroid(assigned.centroid_embedding), assigned.sample_count, embedding);
    const sealed = voiceprintStorage.sealCentroid(centroid);
    database.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=sample_count+1,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(sealed, assigned.id);
    return { ...assigned, centroid_embedding: sealed, sample_count: assigned.sample_count + 1 };
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
      .run(id, userId, voiceprintStorage.sealCentroid(embedding), modelName, embedding.length);
    return database.prepare('SELECT * FROM voiceprints WHERE id=?').get(id);
  }
  const centroid = vectors.updateCentroid(voiceprintStorage.readCentroid(voiceprint.centroid_embedding), voiceprint.sample_count, embedding);
  const sealed = voiceprintStorage.sealCentroid(centroid);
  database.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=sample_count+1,
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(sealed, voiceprint.id);
  return { ...voiceprint, centroid_embedding: sealed, sample_count: voiceprint.sample_count + 1 };
}

module.exports = {
  resolveCluster, resolveVoiceprint, stickyVoiceprintForCluster, mergeClusters,
  collapseSessionClustersByVoiceprint, modelName,
};
