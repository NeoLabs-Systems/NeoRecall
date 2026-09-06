'use strict';

const { getDatabase } = require('../../db/database');
const { getConfig } = require('../../config');

const uuidPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/gi;
const bearerPattern = /Bearer\s+[A-Za-z0-9._~+/\-=]+/gi;

function safePath(value) {
  return String(value || '/').split('?')[0].replace(uuidPattern, ':id').slice(0, 300);
}

function safeMessage(value) {
  if (!value) return null;
  return String(value).replace(bearerPattern, 'Bearer [redacted]').slice(0, 500);
}

function recordRequest({ userId, requestId, method, path, statusCode, durationMs, errorCode }) {
  if (!userId) return;
  const database = getDatabase();
  // The account may have been deleted by the very request being recorded. There
  // is no row to attach a diagnostic to, and nothing to retain for it.
  if (!database.prepare('SELECT 1 FROM users WHERE id=?').get(userId)) return;
  const config = getConfig();
  database.prepare(`INSERT INTO diagnostic_request_events
    (user_id,request_id,method,path,status_code,duration_ms,error_code)
    VALUES (?,?,?,?,?,?,?)`).run(
    userId,
    requestId || null,
    String(method || 'GET').slice(0, 12),
    safePath(path),
    Number(statusCode) || 0,
    Math.max(0, Math.round(Number(durationMs) || 0)),
    errorCode ? String(errorCode).slice(0, 100) : null,
  );
  const cutoff = new Date(Date.now() - config.diagnosticRetentionDays * 86_400_000).toISOString();
  database.prepare('DELETE FROM diagnostic_request_events WHERE user_id=? AND created_at<?').run(userId, cutoff);
  database.prepare(`DELETE FROM diagnostic_request_events
    WHERE user_id=? AND id NOT IN (
      SELECT id FROM diagnostic_request_events WHERE user_id=?
      ORDER BY id DESC LIMIT ?
    )`).run(userId, userId, config.diagnosticMaxEventsPerUser);
}

function exportForUser(userId) {
  const database = getDatabase();
  const config = getConfig();
  const requests = database.prepare(`SELECT method,path,status_code statusCode,duration_ms durationMs,
      error_code errorCode,created_at createdAt
    FROM diagnostic_request_events WHERE user_id=?
    ORDER BY id DESC LIMIT ?`).all(userId, config.diagnosticExportMaxEvents);
  const devices = database.prepare(`SELECT platform,kind,
      CASE WHEN revoked_at IS NULL THEN 0 ELSE 1 END revoked,
      last_heartbeat_at lastHeartbeatAt,created_at createdAt
    FROM devices WHERE user_id=? ORDER BY created_at DESC LIMIT 50`).all(userId);
  const sessions = database.prepare(`SELECT status,COUNT(*) count,MAX(updated_at) latestAt
    FROM recording_sessions WHERE user_id=? GROUP BY status ORDER BY status`).all(userId);
  const chunks = database.prepare(`SELECT state,COUNT(*) count,MAX(updated_at) latestAt
    FROM audio_chunks WHERE user_id=? GROUP BY state ORDER BY state`).all(userId);
  const chunkErrors = database.prepare(`SELECT state,error_code errorCode,
      updated_at updatedAt FROM audio_chunks
    WHERE user_id=? AND error_code IS NOT NULL ORDER BY updated_at DESC LIMIT 30`).all(userId);
  const jobs = database.prepare(`SELECT type,status,attempts,max_attempts maxAttempts,
      last_error_code errorCode,updated_at updatedAt
    FROM jobs WHERE user_id=? ORDER BY updated_at DESC LIMIT 50`).all(userId);
  const imports = database.prepare(`SELECT state,error_code errorCode,updated_at updatedAt
    FROM imports WHERE user_id=? ORDER BY updated_at DESC LIMIT 30`).all(userId);

  return {
    available: true,
    generatedAt: new Date().toISOString(),
    version: require('../../../package.json').version,
    requests,
    accountState: { devices, sessions, chunks, chunkErrors, jobs, imports },
  };
}

module.exports = { recordRequest, exportForUser, safePath, safeMessage };
