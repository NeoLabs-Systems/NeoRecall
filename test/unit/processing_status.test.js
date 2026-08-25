'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

// A whole day of recording that produces an empty timeline has to be explainable
// without reading a log. Every case below is one a user actually hits.
process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-status-'));
process.env.NEORECALL_MIN_MEMORY_EVIDENCE_MS = '0';

const { migrate } = require('../../server/db/migrate');
migrate();
test.after(() => {
  require('../../server/db/database').closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

const { getDatabase } = require('../../server/db/database');
const status = require('../../server/services/status/processing_status_service');

const db = getDatabase();
const userId = crypto.randomUUID();
db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(userId, 'recorder', 'hash');

function issue(result, code) {
  return result.issues.find((item) => item.code === code);
}

test('nothing configured is reported as a blocked pipeline, not as an empty timeline', async () => {
  const result = await status.forUser(userId);
  const transcription = issue(result, 'TRANSCRIPTION_NOT_CONFIGURED');
  assert.ok(transcription, 'the user is told transcription is not set up');
  assert.equal(transcription.severity, 'blocked');
  // The sentence a person reads first has to reassure them about the audio.
  assert.match(transcription.detail, /safe|nothing has been deleted/i);
  assert.ok(transcription.action, 'and say what changes it');
  assert.equal(result.healthy, false);
  assert.ok(result.summary.length > 0);
});

test('every issue is written for the person who recorded, not the operator', async () => {
  // No error codes, table names or settings jargon in anything the user reads.
  const result = await status.forUser(userId);
  for (const item of result.issues) {
    const prose = `${item.title} ${item.detail} ${item.action}`;
    assert.equal(/[A-Z_]{6,}/.test(prose), false, `${item.code} leaks an identifier: ${prose}`);
    assert.equal(/\b(chunk|job|SQL|null|worker_heartbeats|audio_chunks)\b/i.test(prose), false,
      `${item.code} leaks an internal term: ${prose}`);
    assert.ok(item.title && item.detail && item.action, `${item.code} must say what, why and what to do`);
  }
});

test('audio held back is reported as still on the device rather than missing', async () => {
  const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'D','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'ended')`).run(sessionId, userId, deviceId, sessionId, '2026-08-01T10:00:00.000Z', '2026-08-01T10:00:00.000Z', '2026-08-01T09:59:00.000Z');
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,final_sequence,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',0,-1)`).run(sourceId, sessionId, sourceId);
  const insertChunk = db.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state)
    VALUES (?,?,?,?,?,?,?,1,'wav','pcm_s16le','mono','2026-08-01T10:00:00.000Z',0,30000,?)`);
  let sequence = 0;
  for (const state of ['uploaded', 'processing', 'retryable_failed', 'reupload_required']) {
    const id = crypto.randomUUID();
    insertChunk.run(id, userId, sessionId, sourceId, sequence, id, 'a'.repeat(64), state);
    sequence += 1;
  }

  const result = await status.forUser(userId);
  assert.equal(result.audio.stillOnYourDevice, 4, 'nothing unproved is counted as gone');
  assert.equal(result.audio.needsResending, 1);
  assert.equal(result.audio.failing, 1);
  assert.ok(issue(result, 'AUDIO_NEEDS_RESENDING'), 'and resending is asked for explicitly');
});

test('a stopped worker is named rather than left looking like an idle day', async () => {
  // No heartbeat has ever been written in this database.
  const result = await status.forUser(userId);
  assert.equal(result.processingRunning, false);
  const stopped = issue(result, 'PROCESSING_STOPPED');
  assert.ok(stopped);
  assert.equal(stopped.severity, 'blocked');
  assert.match(stopped.detail, /safe/i, 'and it still reassures about the audio');
});

test('memory writing that keeps failing says so, with when it will try again', async () => {
  const eligibility = { eligible: false, reason: 'recent_failure', consecutiveFailures: 4,
    retryAt: '2026-08-01T10:08:00.000Z', errorMessage: 'The AI endpoint returned HTTP 404.' };
  const issues = status.issuesFor(status.counts(userId), eligibility,
    { transcription: true, languageModel: true }, true);
  const failing = issues.find((item) => item.code === 'MEMORY_WRITING_FAILING');
  assert.ok(failing);
  assert.match(failing.detail, /4 attempts/, 'the number of failures is concrete');
  assert.match(failing.detail, /404/, 'and the service\'s own words are passed through');
  assert.match(failing.action, /Nothing is lost/i);
  assert.equal(failing.retryAt, '2026-08-01T10:08:00.000Z');
});

test('a healthy installation says so plainly instead of staying silent', async () => {
  const issues = status.issuesFor(
    { inFlight: 0, failing: 0, needsReupload: 0, transcribed: 12, quarantined: 0, failedJobs: [], oldestQueuedAt: null },
    { eligible: true }, { transcription: true, languageModel: true }, true,
  );
  assert.deepEqual(issues, []);
  assert.match(status.summarize({ inFlight: 0, transcribed: 12 }, issues), /processed/i);
});

test('a run that keeps failing backs off instead of retrying every minute forever', () => {
  // Observed on a real installation: three language-model requests a minute,
  // every minute, all failing, for hours. Nothing about the input could fix it,
  // so every attempt was identical — it produced no memories, buried the first
  // real failure under thousands of identical rows, and hammered an endpoint
  // that was already unwell.
  const consolidation = require('../../server/services/memories/consolidation_service');
  const backoffUser = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(backoffUser, `b-${backoffUser.slice(0, 8)}`, 'hash');
  const insertRun = db.prepare(`INSERT INTO consolidation_runs
    (id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at,completed_at,error_code,error_message)
    VALUES (?,?,?,?,0,1,'failed',?,?,?,?)`);

  const now = Date.now();
  // Four failures in a row, the newest a few seconds ago.
  for (let index = 4; index >= 1; index -= 1) {
    insertRun.run(crypto.randomUUID(), backoffUser, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z',
      new Date(now - index * 20_000).toISOString(), new Date(now - index * 20_000).toISOString(),
      'AI_HTTP_ERROR', 'The AI endpoint returned HTTP 404.');
  }

  const backoff = consolidation.failureBackoff(backoffUser);
  assert.ok(backoff, 'a run this recently failed is not attempted again immediately');
  assert.equal(backoff.consecutiveFailures, 4);
  // Four in a row means eight minutes, not one.
  const waitMs = Date.parse(backoff.retryAt) - (now - 20_000);
  assert.ok(waitMs >= 7 * 60_000 && waitMs <= 9 * 60_000, `expected roughly eight minutes, got ${Math.round(waitMs / 1000)}s`);
  assert.equal(backoff.errorMessage, 'The AI endpoint returned HTTP 404.',
    'and the reason travels with it, so the user can be told');

  // It backs off rather than giving up: a success clears it entirely.
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at,completed_at)
    VALUES (?,?,?,?,0,1,'succeeded',?,?)`).run(crypto.randomUUID(), backoffUser, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z',
    new Date(now).toISOString(), new Date(now).toISOString());
  assert.equal(consolidation.failureBackoff(backoffUser), null, 'one success and it is trying at full speed again');
});

test('asking by hand ignores the backoff, because someone is watching the answer', () => {
  const consolidation = require('../../server/services/memories/consolidation_service');
  const handUser = crypto.randomUUID();
  db.prepare('INSERT INTO users (id,username,password_hash) VALUES (?,?,?)').run(handUser, `h-${handUser.slice(0, 8)}`, 'hash');
  // Eligibility stops at the first thing that is wrong, so a configured model is
  // the precondition for the backoff being what it reports.
  require('../../server/services/settings/provider_settings_service').update({
    llm: { provider: 'openai_compatible', model: 'test-model', baseUrl: 'http://model.internal/v1' },
  });
  db.prepare(`INSERT INTO consolidation_runs (id,user_id,candidate_started_at,candidate_ended_at,material_characters,material_conversations,state,reserved_at,completed_at,error_code)
    VALUES (?,?,?,?,0,1,'failed',?,?,'AI_HTTP_ERROR')`).run(crypto.randomUUID(), handUser, '2026-08-01T10:00:00.000Z', '2026-08-01T10:05:00.000Z',
    new Date().toISOString(), new Date().toISOString());
  assert.equal(consolidation.eligibility(handUser).reason, 'recent_failure', 'unattended, it waits');
  assert.notEqual(consolidation.eligibility(handUser, { ignoreBackoff: true }).reason, 'recent_failure',
    'asked directly, it does not');
});
