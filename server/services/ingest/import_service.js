'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { HttpError } = require('../../middleware/error_handler');
const jobs = require('../jobs/job_service');

function get(userId, id) {
  const row = getDatabase().prepare('SELECT * FROM imports WHERE id=? AND user_id=?').get(id, userId);
  if (!row) throw new HttpError(404, 'NOT_FOUND', 'Import not found.');
  const parts = getDatabase().prepare('SELECT part_number,range_start,range_end,byte_size,sha256 FROM import_parts WHERE import_id=? ORDER BY part_number').all(id);
  const expected = Math.ceil(row.total_size / row.part_size);
  const known = new Set(parts.map((part) => part.part_number));
  return { ...row, parts, missingParts: Array.from({ length: expected }, (_, index) => index).filter((index) => !known.has(index)) };
}

function declare(userId, input) {
  const db = getDatabase();
  const configuredPartSize = getConfig().importPartBytes;
  const partSize = input.partSize || configuredPartSize;
  if (partSize > configuredPartSize) throw new HttpError(400, 'IMPORT_PART_TOO_LARGE', `Import parts may not exceed ${configuredPartSize} bytes.`);
  if (input.deviceId && !db.prepare('SELECT 1 FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL').get(input.deviceId, userId)) throw new HttpError(404, 'NOT_FOUND', 'Device not found.');
  const id = input.id || crypto.randomUUID();
  const existing = db.prepare('SELECT * FROM imports WHERE id=? AND user_id=?').get(id, userId);
  if (existing) {
    if (existing.sha256 !== input.sha256 || existing.total_size !== input.totalSize) throw new HttpError(409, 'IDEMPOTENCY_CONFLICT', 'Import ID was already used with different content.');
    return get(userId, id);
  }
  const expiresAt = new Date(Date.now() + getConfig().importFailedTtlHours * 60 * 60_000).toISOString();
  db.prepare(`INSERT INTO imports
    (id,user_id,device_id,original_name,content_type,total_size,sha256,part_size,capture_time,timezone,state,expires_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,'declared',?)`).run(id, userId, input.deviceId || null, path.basename(input.originalName), input.contentType,
    input.totalSize, input.sha256, partSize, input.captureTime || null, input.timezone || null, expiresAt);
  return get(userId, id);
}

function shaFile(filename) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256'); const stream = fs.createReadStream(filename);
    stream.on('data', (chunk) => hash.update(chunk)); stream.on('error', reject); stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function acceptPart(userId, id, partNumber, metadata, uploaded) {
  if (!uploaded) throw new HttpError(400, 'PART_REQUIRED', 'The part field is required.');
  try {
    const record = get(userId, id);
    if (!['declared', 'uploading'].includes(record.state)) throw new HttpError(409, 'IMPORT_NOT_UPLOADABLE', 'Import is not accepting parts.');
    const expectedStart = partNumber * record.part_size;
    const expectedEnd = Math.min(record.total_size - 1, expectedStart + record.part_size - 1);
    if (metadata.rangeStart !== expectedStart || metadata.rangeEnd !== expectedEnd || uploaded.size !== expectedEnd - expectedStart + 1) throw new HttpError(409, 'INVALID_CONTENT_RANGE', 'The uploaded part range is not the expected range.');
    const digest = await shaFile(uploaded.path);
    if (digest !== metadata.sha256) throw new HttpError(422, 'HASH_MISMATCH', 'The import part hash does not match.');
    const db = getDatabase();
    const existing = db.prepare('SELECT * FROM import_parts WHERE import_id=? AND part_number=?').get(id, partNumber);
    if (existing) {
      if (existing.sha256 !== digest || existing.byte_size !== uploaded.size) throw new HttpError(409, 'IDEMPOTENCY_CONFLICT', 'This import part number already contains different data.');
      return get(userId, id);
    }
    const destination = path.join(ensureRuntimeDirs().importTmp, `${id}.${partNumber}.part`);
    fs.renameSync(uploaded.path, destination);
    db.transaction(() => {
      db.prepare(`INSERT INTO import_parts (import_id,part_number,range_start,range_end,byte_size,sha256,temporary_path)
        VALUES (?,?,?,?,?,?,?)`).run(id, partNumber, metadata.rangeStart, metadata.rangeEnd, uploaded.size, digest, destination);
      db.prepare("UPDATE imports SET state='uploading',updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(id);
    })();
    return get(userId, id);
  } finally { if (uploaded.path && fs.existsSync(uploaded.path)) fs.unlinkSync(uploaded.path); }
}

async function complete(userId, id) {
  const record = get(userId, id);
  if (['assembled', 'processing', 'completed'].includes(record.state)) return record;
  if (!['declared', 'uploading'].includes(record.state)) throw new HttpError(409, 'IMPORT_NOT_COMPLETABLE', 'Import is not in a completable state.');
  if (record.missingParts.length) throw new HttpError(409, 'IMPORT_INCOMPLETE', 'One or more import parts are missing.', { missingParts: record.missingParts });
  const destination = path.join(ensureRuntimeDirs().importTmp, `${id}.source`);
  const output = fs.openSync(destination, 'w', 0o600);
  try {
    for (const part of getDatabase().prepare('SELECT * FROM import_parts WHERE import_id=? ORDER BY part_number').all(id)) {
      const bytes = fs.readFileSync(part.temporary_path);
      fs.writeSync(output, bytes);
    }
    fs.fsyncSync(output);
  } finally { fs.closeSync(output); }
  const digest = await shaFile(destination);
  if (digest !== record.sha256) { fs.unlinkSync(destination); throw new HttpError(422, 'HASH_MISMATCH', 'The assembled import hash does not match.'); }
  const db = getDatabase();
  const partFiles = db.prepare('SELECT temporary_path FROM import_parts WHERE import_id=?').all(id).map((part) => part.temporary_path);
  db.transaction(() => {
    db.prepare('DELETE FROM import_parts WHERE import_id=?').run(id);
    db.prepare("UPDATE imports SET state='assembled',temporary_path=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(destination, id);
    jobs.enqueue({ userId, resourceType: 'import', resourceId: id, type: 'process_import', priority: 90 }, db);
  })();
  for (const filename of partFiles) { try { fs.unlinkSync(filename); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
  return get(userId, id);
}

/// Imports a complete audio file that already lives on this server's disk.
///
/// Server-side sources (cloud integrations) receive whole recordings rather than
/// the live chunk stream the capture pipeline expects, so they reuse the very
/// same durable import path a user's manual upload takes: declare -> parts ->
/// complete -> process_import job. Passing a stable [importId] makes the call
/// idempotent — re-polling a source that already imported a recording resolves
/// to the existing import instead of creating a duplicate.
async function importLocalFile(userId, filename, input) {
  const stats = fs.statSync(filename);
  const digest = await shaFile(filename);
  const partSize = getConfig().importPartBytes;
  const record = declare(userId, {
    id: input.importId,
    originalName: input.originalName,
    contentType: input.contentType,
    totalSize: stats.size,
    sha256: digest,
    partSize,
    captureTime: input.captureTime,
    timezone: input.timezone,
  });
  // A prior run already finished this recording; nothing left to do.
  if (['assembled', 'processing', 'completed'].includes(record.state)) return record;

  const handle = fs.openSync(filename, 'r');
  try {
    for (const partNumber of record.missingParts) {
      const rangeStart = partNumber * partSize;
      const rangeEnd = Math.min(stats.size - 1, rangeStart + partSize - 1);
      const length = rangeEnd - rangeStart + 1;
      const buffer = Buffer.alloc(length);
      fs.readSync(handle, buffer, 0, length, rangeStart);
      // acceptPart consumes (renames) the file it is given, so hand it a copy.
      const staged = path.join(ensureRuntimeDirs().importTmp, `${record.id}.${partNumber}.staged`);
      fs.writeFileSync(staged, buffer, { mode: 0o600 });
      await acceptPart(userId, record.id, partNumber, {
        rangeStart,
        rangeEnd,
        total: stats.size,
        sha256: crypto.createHash('sha256').update(buffer).digest('hex'),
      }, { path: staged, size: length });
    }
  } finally {
    fs.closeSync(handle);
  }
  return complete(userId, record.id);
}

function cancel(userId, id) {
  const record = get(userId, id);
  const db = getDatabase();
  for (const part of db.prepare('SELECT temporary_path FROM import_parts WHERE import_id=?').all(id)) { try { fs.unlinkSync(part.temporary_path); } catch (_) {} }
  if (record.temporary_path) { try { fs.unlinkSync(record.temporary_path); } catch (_) {} }
  db.prepare("UPDATE imports SET state='cancelled',temporary_path=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?").run(id, userId);
}

function reconcileProcessing() {
  const db = getDatabase();
  let completed = 0;
  const rows = db.prepare("SELECT * FROM imports WHERE state IN ('processing','failed') AND temporary_path IS NOT NULL").all();
  for (const record of rows) {
    const session = db.prepare('SELECT id FROM recording_sessions WHERE user_id=? AND client_uuid=?').get(record.user_id, `import-${record.id}`);
    if (!session) continue;
    const pending = db.prepare(`SELECT 1 FROM audio_chunks WHERE session_id=?
      AND state NOT IN ('transcribed','silent') LIMIT 1`).get(session.id);
    if (pending) continue;
    try { fs.unlinkSync(record.temporary_path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    db.prepare("UPDATE imports SET state='completed',temporary_path=NULL,expires_at=NULL,error_code=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?").run(record.id);
    completed += 1;
  }
  return completed;
}

function sweepOrphans() {
  const db = getDatabase();
  const directory = ensureRuntimeDirs().importTmp;
  const referenced = new Set([
    ...db.prepare('SELECT temporary_path FROM imports WHERE temporary_path IS NOT NULL').all(),
    ...db.prepare('SELECT temporary_path FROM import_parts WHERE temporary_path IS NOT NULL').all(),
  ].map((row) => path.resolve(row.temporary_path)));
  let removed = 0;
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const filename = path.resolve(directory, entry.name);
    if (!referenced.has(filename) && Date.now() - fs.statSync(filename).mtimeMs > 60_000) {
      fs.unlinkSync(filename);
      removed += 1;
    }
  }
  return removed;
}

module.exports = { declare, get, acceptPart, complete, cancel, shaFile, importLocalFile, reconcileProcessing, sweepOrphans };
