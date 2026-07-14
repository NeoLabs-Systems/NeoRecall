'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { ensureRuntimeDirs } = require('../../../runtime/paths');
const { getDatabase } = require('../../db/database');
const { createLogger } = require('../../utils/logger');

const logger = createLogger('temp-audio');

function incomingPath() {
  return path.join(ensureRuntimeDirs().audioTmp, `incoming-${crypto.randomUUID()}.part`);
}

function chunkPath(chunkId, extension = 'bin') {
  return path.join(ensureRuntimeDirs().audioTmp, `${chunkId}.${extension.replace(/[^a-z0-9]/gi, '').toLowerCase() || 'bin'}`);
}

function unlinkStrict(file) {
  if (!file) return;
  try { fs.unlinkSync(file); } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

function sweep() {
  const db = getDatabase();
  const { audioTmp } = ensureRuntimeDirs();
  const referenced = new Set(db.prepare('SELECT temporary_path FROM audio_chunks WHERE temporary_path IS NOT NULL').all().map((row) => path.resolve(row.temporary_path)));
  let removed = 0;
  for (const entry of fs.readdirSync(audioTmp, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const file = path.resolve(audioTmp, entry.name);
    const stats = fs.statSync(file);
    if (!referenced.has(file) && Date.now() - stats.mtimeMs > 60_000) {
      unlinkStrict(file);
      removed += 1;
    }
  }
  const pending = db.prepare("SELECT id,temporary_path FROM audio_chunks WHERE state='persisted_cleanup_pending'").all();
  for (const chunk of pending) {
    const fullChunk = db.prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunk.id);
    const result = require('../../workers/handlers/transcribe_handler').finishCleanup(fullChunk, fullChunk.transcript_segment_count || 0);
    if (result.state === 'transcribed' || result.state === 'silent') removed += 1;
  }
  removed += require('./import_service').reconcileProcessing();
  logger.info('Temporary audio sweep completed', { removed });
  return removed;
}

module.exports = { incomingPath, chunkPath, unlinkStrict, sweep };
