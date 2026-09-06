'use strict';

const fs = require('node:fs');
const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');
const ai = require('../../ai/ai_engine');
const analyzer = require('../../services/context/context_analyzer');
const contextService = require('../../services/context/context_service');

async function handle(job) {
  const db = getDatabase();
  const row = db.prepare('SELECT * FROM recording_context_items WHERE id=? AND user_id=?').get(job.resource_id, job.user_id);
  if (!row) return { removed: true };
  if (!row.original_path || !fs.existsSync(row.original_path)) {
    db.prepare("UPDATE recording_context_items SET analysis_state='failed',analysis_error_code='ORIGINAL_MISSING',analysis_error_message='The original file is unavailable.' WHERE id=?").run(row.id);
    return { failed: true };
  }
  db.prepare("UPDATE recording_context_items SET analysis_state='analyzing',analysis_error_code=NULL,analysis_error_message=NULL WHERE id=?").run(row.id);
  try {
    const extracted = await analyzer.extract(row);
    if (extracted.mode === 'skipped') {
      db.prepare("UPDATE recording_context_items SET analysis_state='skipped',analysis_error_code=?,analysis_error_message=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
        .run(extracted.code, extracted.message, row.id);
      return { skipped: true };
    }
    let result;
    if (extracted.mode === 'vision') {
      if (row.byte_size > getConfig().contextImageAnalysisMaxBytes) {
        db.prepare("UPDATE recording_context_items SET analysis_state='skipped',analysis_error_code='IMAGE_TOO_LARGE',analysis_error_message='The image is retained but too large for AI analysis.' WHERE id=?").run(row.id);
        return { skipped: true };
      }
      result = await ai.analyzeContextImage(row.user_id, {
        name: row.original_name, mediaType: row.content_type, data: fs.readFileSync(row.original_path).toString('base64'),
      });
    } else {
      result = await ai.analyzeContextText(row.user_id, { name: row.original_name, content: extracted.extractedText });
    }
    db.prepare(`UPDATE recording_context_items SET analysis_state='ready',extracted_text=?,analysis_text=?,
      analysis_error_code=NULL,analysis_error_message=NULL,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`)
      .run(extracted.extractedText || null, result.description, row.id);
    contextService.enqueueAffectedMemoryRewrites(row, db);
    return { ready: true };
  } catch (error) {
    if (error.code === 'AI_MEDIA_REJECTED') {
      db.prepare("UPDATE recording_context_items SET analysis_state='skipped',analysis_error_code=?,analysis_error_message=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
        .run(error.code, 'The configured model does not accept this image.', row.id);
      return { skipped: true };
    }
    db.prepare("UPDATE recording_context_items SET analysis_state='failed',analysis_error_code=?,analysis_error_message=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?")
      .run(error.code || 'CONTEXT_ANALYSIS_FAILED', String(error.message || error).slice(0, 500), row.id);
    throw error;
  }
}

module.exports = { handle };
