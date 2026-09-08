'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-coverage-'));
process.env.NEORECALL_SAME_DEVICE_COVERAGE_RATIO = '0.5';

const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const coverage = require('../../server/transcription/same_device_coverage');

migrate(getDatabase());

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('merged coverage does not double-count overlapping copies', () => {
  const target = { startMs: 0, endMs: 30_000 };
  assert.equal(coverage.mergedCoverageMs(target, [
    { startMs: 0, endMs: 20_000 },
    { startMs: 10_000, endMs: 25_000 },
  ]), 25_000);
});

test('an import chunk that overlaps a live take on the same device is covered', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const liveSession = crypto.randomUUID();
  const importSession = crypto.randomUUID();
  const liveSource = crypto.randomUUID();
  const importSource = crypto.randomUUID();
  const startedAt = '2026-09-07T10:00:00.000Z';
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'x')").run(userId, `cov-${userId.slice(0, 8)}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Phone','android','mobile')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'ended')`).run(liveSession, userId, deviceId, liveSession, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'ended')`).run(importSession, userId, deviceId, importSession, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'wearable','mono',16000,'pcm_s16le')`).run(liveSource, liveSession, liveSource);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'import','mono',16000,'pcm_s16le')`).run(importSource, importSession, importSource);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_segment_count)
    VALUES (?,?,?,?,0,'live-0','${'a'.repeat(64)}',1,'wav','pcm_s16le','mono',?,0,30000,'transcribed',4)`)
    .run(crypto.randomUUID(), userId, liveSession, liveSource, startedAt);
  const importChunk = {
    user_id: userId,
    source_id: importSource,
    device_started_at: startedAt,
    duration_ms: 30000,
  };
  const session = { device_id: deviceId };
  assert.ok(coverage.isCovered(db, importChunk, session));
  assert.ok(coverage.coverageRatio(db, importChunk, session) >= 0.99);
});

// Skipping deletes the skipped recording on the server and on the device that
// made it. A copy that produced no transcript therefore cannot stand in for
// one that might have caught the conversation — otherwise a live stream that
// heard nothing quietly destroys the wearable's copy of the same minutes.
test('a copy that produced no transcript never covers another source', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const liveSession = crypto.randomUUID();
  const importSession = crypto.randomUUID();
  const liveSource = crypto.randomUUID();
  const importSource = crypto.randomUUID();
  const startedAt = '2026-09-07T11:00:00.000Z';
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'x')").run(userId, `cov2-${userId.slice(0, 8)}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Phone','android','mobile')")
    .run(deviceId, userId, deviceId);
  for (const id of [liveSession, importSession]) {
    db.prepare(`INSERT INTO recording_sessions
      (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
      VALUES (?,?,?,?,?,?,'UTC',?,'ended')`).run(id, userId, deviceId, id, startedAt, startedAt, startedAt);
  }
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'wearable','mono',16000,'pcm_s16le')`).run(liveSource, liveSession, liveSource);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'import','mono',16000,'pcm_s16le')`).run(importSource, importSession, importSource);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_segment_count)
    VALUES (?,?,?,?,0,'silent-0','${'b'.repeat(64)}',1,'wav','pcm_s16le','mono',?,0,30000,'silent',0)`)
    .run(crypto.randomUUID(), userId, liveSession, liveSource, startedAt);
  const importChunk = {
    user_id: userId,
    source_id: importSource,
    device_started_at: startedAt,
    duration_ms: 30000,
  };
  const session = { device_id: deviceId };
  assert.equal(coverage.coverageRatio(db, importChunk, session), 0);
  assert.ok(!coverage.isCovered(db, importChunk, session));
});

test('an overlapping chunk that is still uploading does not cover another source', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const liveSource = crypto.randomUUID();
  const importSource = crypto.randomUUID();
  const startedAt = '2026-09-07T13:00:00.000Z';
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'x')").run(userId, `cov3-${userId.slice(0, 8)}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Phone','android','mobile')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'wearable','mono',16000,'pcm_s16le')`).run(liveSource, sessionId, liveSource);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'import','mono',16000,'pcm_s16le')`).run(importSource, sessionId, importSource);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,'pending-0','${'c'.repeat(64)}',1,'wav','pcm_s16le','mono',?,0,30000,'uploaded')`)
    .run(crypto.randomUUID(), userId, sessionId, liveSource, startedAt);
  const importChunk = {
    user_id: userId,
    source_id: importSource,
    device_started_at: startedAt,
    duration_ms: 30000,
  };
  assert.equal(coverage.isCovered(db, importChunk, { device_id: deviceId }), false);
});

test('a later stretch of the same device is not treated as a duplicate', () => {
  const db = getDatabase();
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const firstSource = crypto.randomUUID();
  const secondSource = crypto.randomUUID();
  const startedAt = '2026-09-07T12:00:00.000Z';
  const laterAt = '2026-09-07T12:00:45.000Z';
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'x')").run(userId, `cov2-${userId.slice(0, 8)}`);
  db.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Phone','android','mobile')")
    .run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'ended')`).run(sessionId, userId, deviceId, sessionId, startedAt, startedAt, startedAt);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'import','mono',16000,'pcm_s16le')`).run(firstSource, sessionId, firstSource);
  db.prepare(`INSERT INTO recording_sources
    (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format)
    VALUES (?,?,?,'import','mono',16000,'pcm_s16le')`).run(secondSource, sessionId, secondSource);
  db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,0,'first-0','${'b'.repeat(64)}',1,'wav','pcm_s16le','mono',?,0,30000,'transcribed')`)
    .run(crypto.randomUUID(), userId, sessionId, firstSource, startedAt);
  const laterChunk = {
    user_id: userId,
    source_id: secondSource,
    device_started_at: laterAt,
    duration_ms: 30000,
  };
  assert.equal(coverage.isCovered(db, laterChunk, { device_id: deviceId }), false);
});
