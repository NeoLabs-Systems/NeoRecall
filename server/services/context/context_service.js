'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { HttpError } = require('../../middleware/error_handler');
const settings = require('../settings/settings_service');
const jobs = require('../jobs/job_service');
const analyzer = require('./context_analyzer');

function memoryRow(userId, publicId) {
  const row = getDatabase().prepare('SELECT * FROM memories WHERE public_id=? AND user_id=?').get(publicId, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Memory not found.');
  return row;
}

function sessionRow(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM recording_sessions WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Recording session not found.');
  return row;
}

function owned(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM recording_context_items WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Context item not found.');
  return row;
}

function assertTarget(userId, row, target) {
  if (!target) return row;
  if (target.sessionId && row.session_id !== target.sessionId) {
    throw new HttpError(404, 'NOT_FOUND', 'Context item not found.');
  }
  if (target.memoryId) {
    const memory = memoryRow(userId, target.memoryId);
    const linked = row.memory_id === memory.id || getDatabase().prepare(
      'SELECT 1 FROM memory_context_sources WHERE memory_id=? AND context_item_id=?',
    ).get(memory.id, row.id);
    if (!linked) throw new HttpError(404, 'NOT_FOUND', 'Context item not found.');
  }
  return row;
}

function affectedMemoryIds(row, db = getDatabase()) {
  const ids = new Set();
  if (row.memory_id) ids.add(Number(row.memory_id));
  for (const linked of db.prepare('SELECT memory_id FROM memory_context_sources WHERE context_item_id=?').all(row.id)) {
    ids.add(Number(linked.memory_id));
  }
  return [...ids];
}

function enqueueAffectedMemoryRewrites(row, db = getDatabase()) {
  for (const memoryId of affectedMemoryIds(row, db)) {
    jobs.enqueue({ userId: row.user_id, resourceType: 'memory', resourceId: String(memoryId), type: 'rewrite_memory_context', priority: 60 }, db);
  }
}

function present(row) {
  return {
    id: row.id,
    kind: row.kind,
    sessionId: row.session_id,
    memoryId: row.memory_public_id || null,
    capturedOffsetMs: row.captured_offset_ms,
    capturedAt: row.captured_at,
    noteText: row.note_text,
    originalName: row.original_name,
    contentType: row.content_type,
    byteSize: row.byte_size,
    originalAvailable: Boolean(row.original_path),
    originalDeletedAt: row.original_deleted_at,
    extractedText: row.extracted_text,
    analysisText: row.analysis_text,
    analysisState: row.analysis_state,
    analysisErrorCode: row.analysis_error_code,
    analysisErrorMessage: row.analysis_error_message,
    usedByAi: Boolean(row.used_by_ai),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const SELECT = `SELECT ci.*,m.public_id memory_public_id,
  COALESCE((SELECT MAX(used_by_ai) FROM memory_context_sources mcs WHERE mcs.context_item_id=ci.id),0) used_by_ai
  FROM recording_context_items ci LEFT JOIN memories m ON m.id=ci.memory_id`;

function listForSession(userId, sessionId) {
  sessionRow(userId, sessionId);
  return getDatabase().prepare(`${SELECT} WHERE ci.user_id=? AND ci.session_id=? ORDER BY ci.captured_offset_ms,ci.created_at`)
    .all(userId, sessionId).map(present);
}

function listForMemory(userId, publicId) {
  const memory = memoryRow(userId, publicId);
  return getDatabase().prepare(`${SELECT} WHERE ci.user_id=? AND (ci.memory_id=? OR EXISTS (
    SELECT 1 FROM memory_context_sources mcs WHERE mcs.context_item_id=ci.id AND mcs.memory_id=?
  )) ORDER BY ci.captured_at,ci.created_at`).all(userId, memory.id, memory.id).map(present);
}

function validateInput(input, file) {
  const config = getConfig();
  if (!['highlight', 'note', 'image', 'document', 'file'].includes(input.kind)) {
    throw new HttpError(400, 'INVALID_CONTEXT_KIND', 'Context kind is invalid.');
  }
  const note = input.kind === 'note' ? String(input.noteText || '').trim() : null;
  if (input.kind === 'note' && !note) throw new HttpError(400, 'NOTE_REQUIRED', 'A note cannot be empty.');
  if (note && note.length > config.contextNoteMaxCharacters) {
    throw new HttpError(413, 'NOTE_TOO_LARGE', `Notes may contain at most ${config.contextNoteMaxCharacters} characters.`);
  }
  if (['image', 'document', 'file'].includes(input.kind) && !file) {
    throw new HttpError(400, 'FILE_REQUIRED', 'A file is required for this context item.');
  }
  if (file && !['image', 'document', 'file'].includes(input.kind)) {
    throw new HttpError(400, 'UNEXPECTED_FILE', 'This context kind does not accept a file.');
  }
  return note;
}

function destination(id, originalName) {
  const extension = path.extname(String(originalName || '')).replace(/[^.a-z0-9]/gi, '').slice(0, 12);
  return path.join(ensureRuntimeDirs().context, `${id}${extension || '.bin'}`);
}

function create(userId, target, id, input, file) {
  if (!/^[0-9a-f-]{36}$/i.test(id)) throw new HttpError(400, 'INVALID_CONTEXT_ID', 'Context id must be a UUID.');
  const db = getDatabase();
  const session = target.sessionId ? sessionRow(userId, target.sessionId) : null;
  const memory = target.memoryId ? memoryRow(userId, target.memoryId) : null;
  const note = validateInput(input, file);
  const uploadedType = analyzer.normalizeType(file?.mimetype);
  const contentType = uploadedType && uploadedType !== 'application/octet-stream'
    ? uploadedType
    : analyzer.normalizeType(input.contentType) || uploadedType || null;
  const actualKind = file ? analyzer.fileKind(contentType) : input.kind;
  const digest = file ? crypto.createHash('sha256').update(fs.readFileSync(file.path)).digest('hex') : null;
  const existing = db.prepare('SELECT * FROM recording_context_items WHERE id=?').get(id);
  if (existing) {
    const sameTarget = existing.session_id === (session?.id || null) && existing.memory_id === (memory?.id || null);
    const sameContent = existing.user_id === userId && existing.kind === actualKind && existing.sha256 === digest
      && existing.note_text === note && existing.content_type === contentType
      && existing.original_name === (file?.originalname || null);
    if (!sameTarget || !sameContent) {
      throw new HttpError(409, 'IDEMPOTENCY_CONFLICT', 'That context id already represents different content.');
    }
    if (file?.path && fs.existsSync(file.path)) fs.unlinkSync(file.path);
    return present({ ...existing, memory_public_id: memory?.public_id || null, used_by_ai: 0 });
  }
  const count = session
    ? db.prepare('SELECT COUNT(*) count FROM recording_context_items WHERE user_id=? AND session_id=?').get(userId, session.id).count
    : db.prepare(`SELECT COUNT(*) count FROM recording_context_items ci WHERE ci.user_id=? AND
      (ci.memory_id=? OR EXISTS (SELECT 1 FROM memory_context_sources mcs WHERE mcs.context_item_id=ci.id AND mcs.memory_id=?))`)
      .get(userId, memory.id, memory.id).count;
  if (count >= getConfig().contextMaxItems) throw new HttpError(409, 'CONTEXT_LIMIT_REACHED', 'This recording or memory has reached its context-item limit.');
  const offset = session ? Number(input.capturedOffsetMs) : null;
  if (session && (!Number.isInteger(offset) || offset < 0)) throw new HttpError(400, 'INVALID_CAPTURE_OFFSET', 'Recording context requires a non-negative capture offset.');
  if (session?.corrected_ended_at) {
    const recordedDuration = Date.parse(session.corrected_ended_at) - Date.parse(session.corrected_started_at);
    if (offset > recordedDuration) {
      throw new HttpError(409, 'OUTSIDE_RECORDING', 'This context item was not captured during the recording.');
    }
  }
  const capturedAt = session ? new Date(Date.parse(session.corrected_started_at) + offset).toISOString() : new Date().toISOString();
  let storedPath = null;
  try {
    if (file) {
      storedPath = destination(id, file.originalname);
      fs.renameSync(file.path, storedPath);
    }
    const analysisState = file ? 'pending' : 'ready';
    db.prepare(`INSERT INTO recording_context_items
      (id,user_id,session_id,memory_id,kind,captured_offset_ms,captured_at,note_text,original_name,content_type,
       byte_size,sha256,original_path,analysis_state)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(id, userId, session?.id || null, memory?.id || null,
      file ? actualKind : input.kind, offset, capturedAt, note, file?.originalname || null, contentType,
      file?.size || null, digest, storedPath, analysisState);
    if (memory) db.prepare('INSERT OR IGNORE INTO memory_context_sources (memory_id,context_item_id) VALUES (?,?)').run(memory.id, id);
    if (file) jobs.enqueue({ userId, resourceType: 'recording_context', resourceId: id, type: 'analyze_context', priority: 50 }, db);
    else if (memory) jobs.enqueue({ userId, resourceType: 'memory', resourceId: String(memory.id), type: 'rewrite_memory_context', priority: 60 }, db);
    return present({ ...owned(userId, id), memory_public_id: memory?.public_id || null, used_by_ai: 0 });
  } catch (error) {
    if (storedPath && fs.existsSync(storedPath)) fs.unlinkSync(storedPath);
    if (file?.path && fs.existsSync(file.path)) fs.unlinkSync(file.path);
    throw error;
  }
}

function update(userId, id, input, target = null) {
  const row = assertTarget(userId, owned(userId, id), target);
  if (row.kind !== 'note') throw new HttpError(409, 'NOT_EDITABLE', 'Only typed notes can be edited.');
  const text = String(input.noteText || '').trim();
  if (!text || text.length > getConfig().contextNoteMaxCharacters) throw new HttpError(400, 'INVALID_NOTE', 'The note is empty or too long.');
  const db = getDatabase();
  db.prepare(`UPDATE recording_context_items SET note_text=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(text, id);
  enqueueAffectedMemoryRewrites(row, db);
  return present({ ...owned(userId, id), memory_public_id: null, used_by_ai: 0 });
}

function remove(userId, id, target = null) {
  const row = assertTarget(userId, owned(userId, id), target);
  const db = getDatabase();
  const memoryIds = affectedMemoryIds(row, db);
  if (row.original_path && fs.existsSync(row.original_path)) fs.unlinkSync(row.original_path);
  db.prepare('DELETE FROM recording_context_items WHERE id=? AND user_id=?').run(id, userId);
  for (const memoryId of memoryIds) {
    jobs.enqueue({ userId, resourceType: 'memory', resourceId: String(memoryId), type: 'rewrite_memory_context', priority: 60 }, db);
  }
}

function original(userId, id, target = null) {
  const row = assertTarget(userId, owned(userId, id), target);
  if (!row.original_path || !fs.existsSync(row.original_path)) throw new HttpError(410, 'ORIGINAL_EXPIRED', 'The original file is no longer retained.');
  return row;
}

function retry(userId, id, target = null) {
  const row = assertTarget(userId, owned(userId, id), target);
  if (!row.original_path) throw new HttpError(410, 'ORIGINAL_EXPIRED', 'The original file is no longer available for analysis.');
  getDatabase().prepare("UPDATE recording_context_items SET analysis_state='pending',analysis_error_code=NULL,analysis_error_message=NULL WHERE id=?").run(id);
  jobs.enqueue({ userId, resourceType: 'recording_context', resourceId: id, type: 'analyze_context', priority: 50 });
  return present({ ...owned(userId, id), memory_public_id: null, used_by_ai: 0 });
}

function cleanupExpiredOriginals(now = new Date()) {
  const db = getDatabase();
  let removed = 0;
  for (const row of db.prepare('SELECT * FROM recording_context_items WHERE original_path IS NOT NULL').all()) {
    const days = settings.get(row.user_id).contextOriginalRetentionDays;
    if (Date.parse(row.created_at) + days * 24 * 60 * 60_000 > now.getTime()) continue;
    try { if (fs.existsSync(row.original_path)) fs.unlinkSync(row.original_path); } catch (_) { continue; }
    db.prepare(`UPDATE recording_context_items SET original_path=NULL,original_deleted_at=?,
      updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`).run(now.toISOString(), row.id);
    removed += 1;
  }
  return removed;
}

module.exports = {
  create, update, remove, original, retry, listForSession, listForMemory, cleanupExpiredOriginals,
  owned, present, enqueueAffectedMemoryRewrites,
};
