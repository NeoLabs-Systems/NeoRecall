'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { HttpError } = require('../../middleware/error_handler');
const processingSettings = require('../settings/processing_settings_service');
const vectors = require('../../transcription/speaker_embeddings');
const { shouldReplacePreview } = require('./speaker_preview_service');

function list(userId) {
  const { speakerDisplayMinimumPreviewMs } = getConfig();
  return getDatabase().prepare(`SELECT v.id,v.display_name,v.embedding_model,v.sample_count,v.matching_enabled,v.created_at,v.updated_at,
    (SELECT COUNT(*) FROM speaker_turns st WHERE st.voiceprint_id=v.id) occurrence_count,
    (SELECT SUM(end_ms - start_ms) FROM speaker_turns st WHERE st.voiceprint_id=v.id) total_duration_ms,
    p.duration_ms preview_duration_ms
    FROM voiceprints v
    JOIN speaker_previews p ON p.voiceprint_id=v.id
    WHERE v.user_id=? AND p.duration_ms>=?
    ORDER BY COALESCE(v.display_name,''),v.created_at`).all(userId, speakerDisplayMinimumPreviewMs);
}

function getOwned(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM voiceprints WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Speaker not found.');
  return row;
}

function update(userId, id, changes) {
  getOwned(userId, id);
  getDatabase().prepare(`UPDATE voiceprints SET display_name=?,matching_enabled=COALESCE(?,matching_enabled),
    updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`).run(
    changes.displayName === undefined ? getOwned(userId, id).display_name : changes.displayName,
    changes.matchingEnabled === undefined ? null : Number(changes.matchingEnabled), id, userId);
  return getOwned(userId, id);
}

function floatVector(buffer) { return new Float32Array(buffer.buffer, buffer.byteOffset, buffer.byteLength / 4); }
function mergedCentroid(first, second) {
  const left = floatVector(first.centroid_embedding);
  const right = floatVector(second.centroid_embedding);
  if (left.length !== right.length) throw new HttpError(409, 'MODEL_MISMATCH', 'Speaker profiles use incompatible embedding models.');
  const total = first.sample_count + second.sample_count;
  const output = new Float32Array(left.length);
  for (let i = 0; i < left.length; i += 1) output[i] = (left[i] * first.sample_count + right[i] * second.sample_count) / total;
  return { buffer: Buffer.from(output.buffer), total };
}

function merge(userId, targetId, sourceId) {
  if (targetId === sourceId) throw new HttpError(400, 'INVALID_MERGE', 'A speaker cannot be merged with itself.');
  const target = getOwned(userId, targetId);
  const source = getOwned(userId, sourceId);
  if (target.embedding_model !== source.embedding_model || target.embedding_dimensions !== source.embedding_dimensions) throw new HttpError(409, 'MODEL_MISMATCH', 'Speaker profiles use incompatible embedding models.');
  const centroid = mergedCentroid(target, source);
  const db = getDatabase();
  db.transaction(() => {
    const targetPreview = db.prepare('SELECT * FROM speaker_previews WHERE voiceprint_id=?').get(targetId);
    const sourcePreview = db.prepare('SELECT * FROM speaker_previews WHERE voiceprint_id=?').get(sourceId);
    const sourceSelection = sourcePreview && {
      durationMs: sourcePreview.duration_ms,
      quality: sourcePreview.quality,
    };
    if (sourcePreview && shouldReplacePreview(
      targetPreview,
      sourceSelection,
      getConfig().speakerDisplayMinimumPreviewMs,
    )) {
      db.prepare(`INSERT INTO speaker_previews
        (voiceprint_id,user_id,audio,content_type,duration_ms,quality,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(voiceprint_id) DO UPDATE SET
          audio=excluded.audio,content_type=excluded.content_type,duration_ms=excluded.duration_ms,
          quality=excluded.quality,updated_at=excluded.updated_at`)
        .run(targetId, userId, sourcePreview.audio, sourcePreview.content_type, sourcePreview.duration_ms,
          sourcePreview.quality, sourcePreview.created_at, sourcePreview.updated_at);
    }
    db.prepare('UPDATE speaker_turns SET voiceprint_id=? WHERE voiceprint_id=? AND user_id=?').run(targetId, sourceId, userId);
    db.prepare('UPDATE conversation_speakers SET voiceprint_id=? WHERE voiceprint_id=?').run(targetId, sourceId);
    db.prepare(`UPDATE voiceprints SET centroid_embedding=?,sample_count=?,display_name=COALESCE(display_name,?),
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`).run(centroid.buffer, centroid.total, source.display_name, targetId, userId);
    db.prepare('DELETE FROM voiceprints WHERE id=? AND user_id=?').run(sourceId, userId);
  })();
  return getOwned(userId, targetId);
}

function mergeMany(userId, targetId, sourceIds) {
  const uniqueSources = [...new Set(sourceIds)].filter((id) => id !== targetId);
  if (uniqueSources.length === 0) throw new HttpError(400, 'INVALID_MERGE', 'Select at least one other speaker to combine.');
  let result;
  for (const sourceId of uniqueSources) result = merge(userId, targetId, sourceId);
  return result;
}

function sameExplicitIdentity(first, second) {
  const firstName = first.display_name?.trim();
  const secondName = second.display_name?.trim();
  return !firstName || !secondName || firstName === secondName;
}

function rankedPeers(row, rows) {
  const centroid = vectors.fromBuffer(row.centroid_embedding);
  return rows
    .filter((candidate) => candidate.id !== row.id
      && candidate.embedding_model === row.embedding_model
      && candidate.embedding_dimensions === row.embedding_dimensions)
    .map((candidate) => ({
      row: candidate,
      score: vectors.cosine(centroid, vectors.fromBuffer(candidate.centroid_embedding)),
    }))
    .sort((left, right) => right.score - left.score);
}

function reevaluationPairs(rows, { voiceMatchThreshold, voiceMatchMargin }) {
  const matches = new Map();
  for (const row of rows) {
    const ranked = rankedPeers(row, rows);
    const best = ranked[0];
    const runnerUp = ranked[1];
    if (best && sameExplicitIdentity(row, best.row) && best.score >= voiceMatchThreshold
      && (!runnerUp || best.score - runnerUp.score >= voiceMatchMargin)) {
      matches.set(row.id, best);
    }
  }
  const pairs = [];
  for (const row of rows) {
    const match = matches.get(row.id);
    if (!match || matches.get(match.row.id)?.row.id !== row.id || row.id > match.row.id) continue;
    pairs.push({ first: row, second: match.row, score: match.score });
  }
  return pairs.sort((left, right) => right.score - left.score);
}

function preferredMergeTarget(first, second) {
  const firstNamed = Boolean(first.display_name?.trim());
  const secondNamed = Boolean(second.display_name?.trim());
  if (firstNamed !== secondNamed) return firstNamed ? first : second;
  if (first.sample_count !== second.sample_count) return first.sample_count > second.sample_count ? first : second;
  return first.created_at <= second.created_at ? first : second;
}

function reevaluate(userId) {
  const db = getDatabase();
  const limits = processingSettings.get();
  return db.transaction(() => {
    const merges = [];
    while (true) {
      const rows = db.prepare(`SELECT * FROM voiceprints
        WHERE user_id=? AND matching_enabled=1 AND centroid_embedding IS NOT NULL`).all(userId);
      const pairs = reevaluationPairs(rows, limits);
      if (pairs.length === 0) break;
      for (const pair of pairs) {
        const target = preferredMergeTarget(pair.first, pair.second);
        const source = target.id === pair.first.id ? pair.second : pair.first;
        merge(userId, target.id, source.id);
        merges.push({ targetId: target.id, sourceId: source.id, similarity: pair.score });
      }
    }
    return {
      mergedCount: merges.length,
      remainingCount: db.prepare('SELECT COUNT(*) count FROM voiceprints WHERE user_id=?').get(userId).count,
      merges,
    };
  })();
}

function bulkRemove(userId, ids) {
  const uniqueIds = [...new Set(ids)];
  const db = getDatabase();
  const rows = db.prepare(`SELECT id FROM voiceprints WHERE user_id=? AND id IN (${uniqueIds.map(() => '?').join(',')})`)
    .all(userId, ...uniqueIds);
  if (rows.length !== uniqueIds.length) throw new HttpError(404, 'NOT_FOUND', 'One or more speakers were not found.');
  db.transaction(() => {
    const stmt = db.prepare('DELETE FROM voiceprints WHERE id=? AND user_id=?');
    for (const id of uniqueIds) stmt.run(id, userId);
  })();
  return { action: 'delete', count: uniqueIds.length, ids: uniqueIds };
}

function assign(userId, voiceprintId, turnIds) {
  getOwned(userId, voiceprintId);
  const db = getDatabase();
  let changed = 0;
  db.transaction(() => {
    const updateTurn = db.prepare('UPDATE speaker_turns SET voiceprint_id=? WHERE id=? AND user_id=?');
    for (const turnId of turnIds) changed += updateTurn.run(voiceprintId, turnId, userId).changes;
  })();
  if (changed !== turnIds.length) throw new HttpError(404, 'NOT_FOUND', 'One or more speaker turns were not found.');
  return { assigned: changed };
}

function remove(userId, id) {
  const db = getDatabase();
  const result = db.prepare('DELETE FROM voiceprints WHERE id=? AND user_id=?').run(id, userId);
  if (result.changes === 0) throw new HttpError(404, 'NOT_FOUND', 'Speaker not found.');
  return { success: true };
}

module.exports = {
  list,
  update,
  merge,
  mergeMany,
  reevaluate,
  assign,
  remove,
  bulkRemove,
  reevaluationPairs,
};
