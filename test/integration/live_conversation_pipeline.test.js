'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-live-'));
process.env.AI_PROVIDER = 'openai_compatible';
process.env.AI_API_MODEL = 'test/model';
process.env.NEORECALL_CONVERSATION_PREVIEW_MIN_CHARACTERS = '10';
process.env.NEORECALL_CONVERSATION_PREVIEW_REFRESH_CHARACTERS = '10';
process.env.NEORECALL_CONVERSATION_PREVIEW_MIN_INTERVAL_MS = '0';

const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const boundaryHandler = require('../../server/workers/handlers/boundary_handler');
const resolveSpeakersHandler = require('../../server/workers/handlers/resolve_speakers_handler');
const insights = require('../../server/services/conversations/conversation_insight_service');
const consolidation = require('../../server/services/memories/consolidation_service');
const processingSettings = require('../../server/services/settings/processing_settings_service');
const { getConfig } = require('../../server/config');

const app = createApp();
let modelEndpoint;

test.after(() => {
  modelEndpoint?.close();
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

// One clock reading for the whole suite. Reading it per call made a pair of
// offsets 50 seconds apart come out 50001 ms whenever the millisecond ticked
// between the two calls, which failed a release at random.
const SUITE_NOW = Date.now();

function iso(offsetMs) {
  return new Date(SUITE_NOW + offsetMs).toISOString();
}

/// A user with one still-running recording, ready for segments to be appended.
async function recordingUser(username) {
  const registration = await request(app).post('/api/v1/auth/register').send({ username, password: 'a long and unique password' });
  const userId = registration.body.user.id;
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')").run(deviceId, userId, deviceId);
  db.prepare(`INSERT INTO recording_sessions(id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?,'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId, iso(-3_600_000), iso(-3_600_000), iso(-3_600_000));
  db.prepare(`INSERT INTO recording_sources(id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format,contiguous_terminal_sequence)
    VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le',-1)`).run(sourceId, sessionId, sourceId);
  return { userId, sessionId, sourceId };
}

/// Appends one fully transcribed chunk with its segments, as the transcribe
/// handler would once a chunk reaches a terminal state.
// Closing a conversation queues a speaker re-resolution, and consolidation
// deliberately waits for it so the model never reads labels that are about to
// change. A worker drains that queue in a running server; these tests drive the
// pipeline by hand and so have to drain it themselves.
async function settleSpeakerResolution(userId) {
  const db = getDatabase();
  const pending = db.prepare(`SELECT * FROM jobs WHERE type='resolve_speakers' AND user_id=?
    AND status IN ('queued','leased')`).all(userId);
  for (const job of pending) {
    await resolveSpeakersHandler.handle(job);
    db.prepare(`UPDATE jobs SET status='completed',completed_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE id=?`).run(job.id);
  }
}

function appendChunk({ userId, sessionId, sourceId }, sequence, segments) {
  const db = getDatabase();
  const chunkId = crypto.randomUUID();
  db.prepare(`INSERT INTO audio_chunks(id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,
    channel_layout,device_started_at,monotonic_offset_ms,duration_ms,state,transcript_sha256,transcript_segment_count,persisted_at,server_deleted_at)
    VALUES (?,?,?,?,?,?,?,1,'wav','pcm_s16le','mono',?,?,30000,'transcribed',?,?,?,?)`)
    .run(chunkId, userId, sessionId, sourceId, sequence, chunkId, 'a'.repeat(64), iso(-60_000), sequence * 30_000,
      'b'.repeat(64), segments.length, iso(-1_000), iso(-1_000));
  db.prepare('UPDATE recording_sources SET contiguous_terminal_sequence=? WHERE id=?').run(sequence, sourceId);
  for (const segment of segments) {
    db.prepare(`INSERT INTO transcript_segments(public_id,user_id,chunk_id,source_component,started_at,ended_at,chunk_start_ms,chunk_end_ms,text,language)
      VALUES (?,?,?,'combined',?,?,0,30000,?,'de')`).run(crypto.randomUUID(), userId, chunkId, segment.startedAt, segment.endedAt, segment.text);
  }
  return chunkId;
}

test('an open conversation keeps its identity and its live insight while recording continues', async () => {
  const recording = await recordingUser('live-user');
  const db = getDatabase();

  // Past the audio floor, so this exercises the preview rather than the floor.
  appendChunk(recording, 0, [
    { startedAt: iso(-200_000), endedAt: iso(-170_000), text: 'Wir besprechen heute den Zeitplan für das Release.' },
    { startedAt: iso(-165_000), endedAt: iso(-95_000), text: 'Der Termin bleibt wie geplant im September.' },
  ]);
  await boundaryHandler.handle({ user_id: recording.userId });

  const first = db.prepare("SELECT id,state FROM conversations WHERE user_id=?").get(recording.userId);
  assert.equal(first.state, 'open');

  // A preview writes a provisional insight for the conversation as it stands.
  modelEndpoint = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ id: 'preview-1', usage: {}, choices: [{ message: { content: JSON.stringify({
        titleEn: 'Release schedule discussion',
        summaryEn: 'The team confirmed the September release date.',
        memoryWorthy: true,
        topics: ['Release planning'],
      }) } }] }));
    });
  });
  await new Promise((resolve) => modelEndpoint.listen(0, '127.0.0.1', resolve));
  process.env.AI_API_BASE_URL = `http://127.0.0.1:${modelEndpoint.address().port}`;

  const previewed = await insights.execute(recording.userId, first.id);
  assert.equal(previewed.superseded, false);
  const provisional = db.prepare('SELECT title_en,summary_en,topics_json,insight_state,memory_worthy,insight_characters FROM conversations WHERE id=?').get(first.id);
  assert.equal(provisional.insight_state, 'provisional');
  assert.equal(provisional.title_en, 'Release schedule discussion');
  assert.equal(provisional.memory_worthy, 1);
  assert.deepEqual(JSON.parse(provisional.topics_json), ['Release planning']);
  assert.ok(provisional.insight_characters > 0);

  // Recording continues. Re-detecting boundaries must extend the very same
  // conversation rather than replace it, or the live insight would vanish and
  // every client reference to it would break mid-recording.
  appendChunk(recording, 1, [
    { startedAt: iso(-60_000), endedAt: iso(-50_000), text: 'Bis dahin brauchen wir noch die Freigabe vom Marketing.' },
  ]);
  const rerun = await boundaryHandler.handle({ user_id: recording.userId });
  assert.equal(rerun.continued, 1);
  assert.equal(rerun.created, 0);

  const rows = db.prepare('SELECT id,state,title_en,insight_state FROM conversations WHERE user_id=?').all(recording.userId);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].id, first.id);
  assert.equal(rows[0].state, 'open');
  assert.equal(rows[0].title_en, 'Release schedule discussion');
  assert.equal(rows[0].insight_state, 'provisional');
  assert.equal(db.prepare('SELECT COUNT(*) count FROM transcript_segments WHERE conversation_id=?').get(first.id).count, 3);
});

test('a provisional insight never overwrites the final one consolidation wrote', async () => {
  const recording = await recordingUser('final-user');
  const db = getDatabase();
  appendChunk(recording, 0, [{ startedAt: iso(-120_000), endedAt: iso(-110_000), text: 'Kurze Notiz zum Projektstand.' }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  const conversationId = db.prepare('SELECT id FROM conversations WHERE user_id=?').get(recording.userId).id;

  db.prepare(`UPDATE conversations SET title_en='Final title',summary_en='Final summary',insight_state='final',
    state='consolidated' WHERE id=?`).run(conversationId);

  const result = insights.persist(recording.userId, conversationId, {
    titleEn: 'Stale preview', summaryEn: 'Stale summary', memoryWorthy: false, topics: [],
  }, { characters: 10, coveredThrough: iso(-110_000), aiRequestId: null });
  assert.equal(result.superseded, true);
  const row = db.prepare('SELECT title_en,insight_state FROM conversations WHERE id=?').get(conversationId);
  assert.equal(row.title_en, 'Final title');
  assert.equal(row.insight_state, 'final');
});

test('a long conversation refreshes from its own summary instead of its whole history', async () => {
  const recording = await recordingUser('rolling-user');
  const db = getDatabase();
  // Two chunks of speech, the first far larger than the full-read threshold.
  appendChunk(recording, 0, [{ startedAt: iso(-240_000), endedAt: iso(-200_000), text: 'A'.repeat(30_000) }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  const conversationId = db.prepare('SELECT id FROM conversations WHERE user_id=?').get(recording.userId).id;

  const beforeRolling = insights.previewInput(recording.userId, db.prepare('SELECT c.*,NULL session_id FROM conversations c WHERE id=?').get(conversationId), insights.thresholds());
  assert.equal(beforeRolling.previousInsight, null, 'The first preview has nothing to roll forward and must read everything.');
  assert.equal(beforeRolling.conversation.segments.length, 1);

  const coveredThrough = beforeRolling.conversation.segments.at(-1).ended_at;
  insights.persist(recording.userId, conversationId, {
    titleEn: 'Long session', summaryEn: 'The first stretch of the session.', memoryWorthy: true, topics: ['Session'],
  }, { characters: beforeRolling.characters, coveredThrough, aiRequestId: null });

  // Close enough in time to stay one conversation rather than open a new one.
  appendChunk(recording, 1, [{ startedAt: iso(-195_000), endedAt: iso(-160_000), text: 'B'.repeat(5_000) }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  assert.equal(db.prepare('SELECT COUNT(*) count FROM conversations WHERE user_id=?').get(recording.userId).count, 1);

  const rolling = insights.previewInput(recording.userId, db.prepare('SELECT c.*,NULL session_id FROM conversations c WHERE id=?').get(conversationId), insights.thresholds());
  assert.equal(rolling.previousInsight.titleEn, 'Long session');
  // Only the new speech is re-sent, so a conversation that never ends costs the
  // same per refresh instead of re-paying for its entire history.
  assert.equal(rolling.conversation.segments.length, 1);
  assert.equal(rolling.conversation.segments[0].text.length, 5_000);
  assert.equal(rolling.characters, 35_000, 'Growth is still measured against the whole transcript.');
});

test('one sitting broken by pauses becomes one consolidation run, not one per fragment', async () => {
  const recording = await recordingUser('occasion-user');
  const db = getDatabase();
  // One meeting with two ordinary pauses in it. Each pause clears the hard
  // boundary gap, so speech grouping cuts the sitting into three conversations —
  // which is what used to produce three memory cards minutes apart.
  appendChunk(recording, 0, [{ startedAt: iso(-1_200_000), endedAt: iso(-1_140_000), text: 'Wir fangen mit dem Zeitplan an und gehen die offenen Punkte durch.' }]);
  appendChunk(recording, 1, [{ startedAt: iso(-900_000), endedAt: iso(-840_000), text: 'Weiter beim Zeitplan, der Termin im September bleibt bestehen.' }]);
  appendChunk(recording, 2, [{ startedAt: iso(-360_000), endedAt: iso(-60_000), text: 'Zum Schluss noch die Verteilung der Aufgaben im Team.' }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  db.prepare("UPDATE conversations SET state='closed' WHERE user_id=?").run(recording.userId);
  await settleSpeakerResolution(recording.userId);
  const fragments = db.prepare('SELECT id FROM conversations WHERE user_id=? ORDER BY started_at').all(recording.userId).map((row) => row.id);
  assert.equal(fragments.length, 3, 'The pauses do cut the sitting into three conversations.');

  // All three are read as one occasion, so one run carries the whole sitting.
  assert.deepEqual(consolidation.buildCandidates(recording.userId).conversations.map((item) => item.id), fragments);

  // And while the recording is still running and the last fragment is fresh,
  // nothing is written up at all: more of this sitting may still be coming.
  const waiting = consolidation.eligibility(recording.userId);
  assert.equal(waiting.eligible, false);
  assert.equal(waiting.reason, 'occasion_unsettled');
  assert.ok(Date.parse(waiting.consolidateAfter) > SUITE_NOW, 'It says when it will stop waiting.');
  assert.equal(consolidation.request(recording.userId).queued, undefined);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM consolidation_runs WHERE user_id=?').get(recording.userId).count, 0);

  // Asking by hand is a decision to take what exists now, and skips the wait.
  assert.equal(consolidation.eligibility(recording.userId, { manual: true }).eligible, true);

  // Once the recording stops, the whole sitting is written up in one run.
  db.prepare('UPDATE audio_chunks SET uploaded_at=? WHERE user_id=?').run(iso(-1_200_000), recording.userId);
  const ready = consolidation.eligibility(recording.userId);
  assert.equal(ready.eligible, true);
  assert.equal(ready.conversations.length, 3);
  assert.equal(consolidation.request(recording.userId).queued, true);
  const runs = db.prepare('SELECT id FROM consolidation_runs WHERE user_id=?').all(recording.userId);
  assert.equal(runs.length, 1, 'One sitting, one run — not one run per fragment.');
  const job = db.prepare("SELECT payload_json FROM jobs WHERE type='consolidate_memories' AND resource_id=?").get(runs[0].id);
  assert.deepEqual(JSON.parse(job.payload_json).conversationIds, fragments);
});

test('a separate occasion later the same day stays its own run', async () => {
  const recording = await recordingUser('two-occasion-user');
  const db = getDatabase();
  // Two sittings an hour apart on one recording. The gap is far beyond the
  // occasion gap, so nothing joins them and each keeps its own card.
  appendChunk(recording, 0, [{ startedAt: iso(-7_200_000), endedAt: iso(-7_140_000), text: 'Das Morgenmeeting zum Zeitplan mit dem ganzen Team.' }]);
  appendChunk(recording, 1, [{ startedAt: iso(-3_600_000), endedAt: iso(-3_540_000), text: 'Später ein eigenes Gespräch über den Zeitplan mit der Werkstatt.' }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  db.prepare("UPDATE conversations SET state='closed' WHERE user_id=?").run(recording.userId);
  await settleSpeakerResolution(recording.userId);
  const [morning] = db.prepare('SELECT id FROM conversations WHERE user_id=? ORDER BY started_at').all(recording.userId).map((row) => row.id);
  assert.deepEqual(consolidation.buildCandidates(recording.userId).conversations.map((item) => item.id), [morning]);
});

test('a conversation the model cannot partition is isolated and then quarantined', async () => {
  const recording = await recordingUser('quarantine-user');
  const db = getDatabase();
  // Two conversations of one sitting: the pause between them clears the hard
  // boundary gap, so speech grouping cuts them apart, but it stays well inside
  // the occasion gap, so consolidation reads them as one occasion.
  appendChunk(recording, 0, [{ startedAt: iso(-7_200_000), endedAt: iso(-7_100_000), text: 'Erste abgeschlossene Konversation mit genug Inhalt.' }]);
  appendChunk(recording, 1, [{ startedAt: iso(-6_900_000), endedAt: iso(-6_800_000), text: 'Zweite abgeschlossene Konversation mit genug Inhalt.' }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  db.prepare("UPDATE conversations SET state='closed' WHERE user_id=?").run(recording.userId);
  await settleSpeakerResolution(recording.userId);
  const [older, newer] = db.prepare('SELECT id FROM conversations WHERE user_id=? ORDER BY started_at').all(recording.userId).map((row) => row.id);
  assert.ok(older && newer && older !== newer);
  assert.deepEqual(consolidation.buildCandidates(recording.userId).conversations.map((item) => item.id), [older, newer]);

  // After a validation failure the next run carries a single conversation, so
  // the failure can be attributed instead of blamed on the whole batch.
  db.prepare(`INSERT INTO consolidation_runs(id,user_id,state,reserved_at,error_code)
    VALUES (?,?,'failed',?, 'AI_REFERENCE_INVALID')`).run(crypto.randomUUID(), recording.userId, new Date().toISOString());
  const narrowed = consolidation.buildCandidates(recording.userId);
  assert.equal(narrowed.narrowed, true);
  assert.deepEqual(narrowed.conversations.map((item) => item.id), [older]);

  for (let attempt = 0; attempt < 3; attempt += 1) {
    consolidation.recordValidationFailure(recording.userId, [older], 'AI_REFERENCE_INVALID');
  }
  const quarantined = db.prepare('SELECT consolidation_failures,quarantined_at,quarantine_reason FROM conversations WHERE id=?').get(older);
  assert.equal(quarantined.consolidation_failures, 3);
  assert.ok(quarantined.quarantined_at);
  assert.equal(quarantined.quarantine_reason, 'AI_REFERENCE_INVALID');

  // Memory generation continues with the conversations that are still valid.
  assert.deepEqual(consolidation.buildCandidates(recording.userId).conversations.map((item) => item.id), [newer]);
});

test('the audio floor is off by default and still enforced when an operator sets one', async () => {
  const recording = await recordingUser('short-user');
  const db = getDatabase();
  // Fifty seconds of dense speech. This used to be refused outright, because a
  // hosted model charged per request and a short recording could not justify
  // one. The model now runs on this machine, so the recording is worth
  // describing as soon as it ends — what keeps it off the timeline as a memory
  // card is the separate evidence floor, not a floor on reaching the model.
  appendChunk(recording, 0, [{ startedAt: iso(-3_650_000), endedAt: iso(-3_600_000), text: 'Kurze Notiz. '.repeat(400) }]);
  await boundaryHandler.handle({ user_id: recording.userId });
  db.prepare("UPDATE conversations SET state='closed' WHERE user_id=?").run(recording.userId);
  await settleSpeakerResolution(recording.userId);

  const conversation = db.prepare('SELECT * FROM conversations WHERE user_id=?').get(recording.userId);
  assert.equal(Date.parse(conversation.ended_at) - Date.parse(conversation.started_at), 50_000);
  assert.equal(getConfig().minAiAudioMs, 0, 'The shipped default no longer withholds short material from the model.');

  const allowed = consolidation.eligibility(recording.userId);
  assert.equal(allowed.eligible, true);
  assert.equal(allowed.conversations.length, 1);

  // The floor is still a hard gate, not a heuristic, for an operator whose
  // machine cannot keep up with its own recordings.
  processingSettings.update({ minAiAudioMs: 60_000 });
  try {
    const blocked = consolidation.eligibility(recording.userId);
    assert.equal(blocked.eligible, false);
    assert.equal(blocked.reason, 'insufficient_audio');
    assert.equal(blocked.requiredAudioMs, 60_000);
    // Even asking directly queues nothing.
    assert.equal(consolidation.request(recording.userId, { manual: true }).queued, undefined);
    assert.equal(db.prepare('SELECT COUNT(*) count FROM consolidation_runs WHERE user_id=?').get(recording.userId).count, 0);
    // And it is never previewed either, however much text it holds.
    assert.equal(insights.due(recording.userId).length, 0);
  } finally {
    processingSettings.update({ minAiAudioMs: getConfig().minAiAudioMs });
  }
});
