'use strict';

const { getConfig } = require('../config');

function rangeMs(startAt, durationMs) {
  const startMs = Date.parse(startAt);
  const length = Number(durationMs);
  if (!Number.isFinite(startMs) || !Number.isFinite(length) || length <= 0) return null;
  return { startMs, endMs: startMs + length };
}

function overlapMs(left, right) {
  return Math.max(0, Math.min(left.endMs, right.endMs) - Math.max(left.startMs, right.startMs));
}

function mergedCoverageMs(target, others) {
  const clips = others
    .map((other) => {
      const overlap = overlapMs(target, other);
      if (overlap <= 0) return null;
      return {
        startMs: Math.max(target.startMs, other.startMs),
        endMs: Math.min(target.endMs, other.endMs),
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.startMs - right.startMs);
  let covered = 0;
  let cursor = target.startMs;
  for (const clip of clips) {
    if (clip.endMs <= cursor) continue;
    covered += clip.endMs - Math.max(cursor, clip.startMs);
    cursor = clip.endMs;
  }
  return covered;
}

const epochMs = (column) => `(julianday(${column})-2440587.5)*86400000`;

function otherChunksOnDevice(database, { userId, deviceId, sourceId, startMs, endMs }) {
  if (!deviceId) return [];
  // Only already-processed copies count. Two in-flight jobs for the same
  // window must both run ASR rather than both skip and drop the transcript.
  return database.prepare(`SELECT c.device_started_at startAt, c.duration_ms durationMs
    FROM audio_chunks c
    JOIN recording_sessions r ON r.id=c.session_id
    WHERE r.user_id=? AND r.device_id=? AND c.source_id<>?
      AND c.state IN ('transcribed','silent','persisted_cleanup_pending')
      AND ${epochMs('c.device_started_at')} < ?
      AND ${epochMs('c.device_started_at')} + c.duration_ms > ?`)
    .all(userId, deviceId, sourceId, endMs, startMs);
}

function coverageRatio(database, chunk, session, { ratio } = {}) {
  const required = Number.isFinite(ratio) ? ratio : getConfig().sameDeviceCoverageRatio;
  const target = rangeMs(chunk.device_started_at, chunk.duration_ms);
  if (!target || !session?.device_id || required <= 0) return 0;
  const others = otherChunksOnDevice(database, {
    userId: chunk.user_id,
    deviceId: session.device_id,
    sourceId: chunk.source_id,
    startMs: target.startMs,
    endMs: target.endMs,
  }).map((row) => rangeMs(row.startAt, row.durationMs)).filter(Boolean);
  return mergedCoverageMs(target, others) / (target.endMs - target.startMs);
}

function isCovered(database, chunk, session, options) {
  const required = Number.isFinite(options?.ratio) ? options.ratio : getConfig().sameDeviceCoverageRatio;
  return coverageRatio(database, chunk, session, { ratio: required }) >= required;
}

module.exports = { rangeMs, overlapMs, mergedCoverageMs, coverageRatio, isCovered };
