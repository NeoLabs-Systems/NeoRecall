'use strict';

const crypto = require('node:crypto');
const processingSettings = require('../services/settings/processing_settings_service');
const vectors = require('./speaker_embeddings');

const modelName = 'wespeaker_en_voxceleb_CAM++_LM';

function storeVector(value) { return Buffer.from(value.buffer, value.byteOffset, value.byteLength); }

function resolveCluster(database, { userId, sessionId, embedding }) {
  const config = processingSettings.get();
  const rows = database.prepare('SELECT * FROM speaker_clusters WHERE user_id=? AND session_id=? AND centroid_embedding IS NOT NULL').all(userId, sessionId);
  const ranked = vectors.rank(embedding, rows);
  let cluster = ranked[0]?.score >= config.speakerClusterThreshold ? ranked[0].row : null;
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
  let assigned = null;
  if (clusterId) {
    assigned = database.prepare(`SELECT v.*,COUNT(*) assignment_count,MAX(st.created_at) last_assignment_at
      FROM speaker_turns st JOIN voiceprints v ON v.id=st.voiceprint_id
      WHERE st.cluster_id=? AND st.user_id=? AND v.matching_enabled=1
      GROUP BY v.id ORDER BY assignment_count DESC,last_assignment_at DESC LIMIT 1`).get(clusterId, userId) || null;
  }
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

module.exports = { resolveCluster, resolveVoiceprint, modelName };
