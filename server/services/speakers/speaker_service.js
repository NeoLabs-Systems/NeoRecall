'use strict';

const { getDatabase } = require('../../db/database');
const { HttpError } = require('../../middleware/error_handler');

function list(userId) {
  return getDatabase().prepare(`SELECT v.id,v.display_name,v.embedding_model,v.sample_count,v.matching_enabled,v.created_at,v.updated_at,
    (SELECT COUNT(*) FROM speaker_turns st WHERE st.voiceprint_id=v.id) occurrence_count,
    p.duration_ms preview_duration_ms
    FROM voiceprints v
    LEFT JOIN speaker_previews p ON p.voiceprint_id=v.id
    WHERE v.user_id=? ORDER BY COALESCE(v.display_name,''),v.created_at`).all(userId);
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
    if (sourcePreview && (!targetPreview || sourcePreview.quality > targetPreview.quality)) {
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

module.exports = { list, update, merge, assign };
