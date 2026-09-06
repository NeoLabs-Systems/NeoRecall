'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-preview-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const previews = require('../../server/services/speakers/speaker_preview_service');

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

test('speaker preview selection contains only clean turns and stays within five to ten seconds', () => {
  const selection = previews.selectTurns([
    { start_ms: 0, end_ms: 8_000, quality: 1, overlapping_speech: 1 },
    { start_ms: 8_000, end_ms: 12_000, quality: 0.8, overlapping_speech: 0 },
    { start_ms: 14_000, end_ms: 22_000, quality: 0.9, overlapping_speech: 0 },
  ]);
  assert.ok(selection);
  assert.equal(selection.durationMs, 10_000);
  assert.deepEqual(selection.turns.map((turn) => [turn.start_ms, turn.end_ms]), [
    [8_000, 10_000],
    [14_000, 22_000],
  ]);
  assert.ok(selection.turns.every((turn) => !turn.overlapping_speech));
});

test('speaker preview extraction emits a finite mono WAV', () => {
  const fixture = path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav');
  const audio = previews.extractPreview(fixture, 'mono', {
    durationMs: 5_000,
    quality: 1,
    turns: [{ start_ms: 0, end_ms: 5_000, source_component: 'combined' }],
  });
  assert.equal(audio.toString('ascii', 0, 4), 'RIFF');
  assert.equal(audio.toString('ascii', 8, 12), 'WAVE');
  assert.equal(audio.readUInt32LE(4), audio.length - 8);
  assert.ok(audio.length > 150_000);
  assert.ok(audio.length < 170_000);
});

test('a full preview replaces a cleaner but incomplete preview', () => {
  assert.equal(previews.shouldReplacePreview(
    { duration_ms: 5_000, quality: 1 },
    { durationMs: 10_000, quality: 0.8 },
    10_000,
  ), true);
  assert.equal(previews.shouldReplacePreview(
    { duration_ms: 10_000, quality: 0.9 },
    { durationMs: 10_000, quality: 0.8 },
    10_000,
  ), false);
});

test('two short WAV excerpts concatenate into one longer preview clip', () => {
  const fixture = path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav');
  const first = previews.extractPreview(fixture, 'mono', {
    durationMs: 2_000, quality: 1, turns: [{ start_ms: 0, end_ms: 2_000, source_component: 'combined' }],
  });
  const second = previews.extractPreview(fixture, 'mono', {
    durationMs: 2_000, quality: 1, turns: [{ start_ms: 8_000, end_ms: 10_000, source_component: 'combined' }],
  });
  const combined = previews.concatPreviewAudio(first, second, 10_000);
  assert.equal(combined.toString('ascii', 0, 4), 'RIFF');
  assert.equal(combined.toString('ascii', 8, 12), 'WAVE');
  const duration = previews.wavDurationMs(combined);
  assert.ok(duration >= 3_900 && duration <= 4_100, `expected ~4s, got ${duration}ms`);
});

test('incomplete previews accumulate across chunks until they reach the maximum', () => {
  const database = getDatabase();
  migrate(database);
  const fixture = path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav');
  const userId = crypto.randomUUID();
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  const voiceprintId = crypto.randomUUID();
  const clusterId = crypto.randomUUID();
  const firstChunk = crypto.randomUUID();
  const secondChunk = crypto.randomUUID();
  const sample = Buffer.from(new Float32Array([1, 0, 0, 0]).buffer);
  database.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `preview-acc-${userId}`);
  database.prepare("INSERT INTO devices (id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Test','test','desktop')")
    .run(deviceId, userId, deviceId);
  database.prepare(`INSERT INTO recording_sessions
    (id,user_id,device_id,client_uuid,device_started_at,corrected_started_at,timezone,consent_attested_at,status)
    VALUES (?,?,?,?,?,?, 'UTC',?,'active')`).run(sessionId, userId, deviceId, sessionId,
    '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z', '2026-07-14T10:00:00.000Z');
  database.prepare("INSERT INTO recording_sources (id,session_id,client_uuid,kind,channel_layout,sample_rate,sample_format) VALUES (?,?,?,'microphone','mono',16000,'pcm_s16le')")
    .run(sourceId, sessionId, sourceId);
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,'test-model',4,1)`).run(voiceprintId, userId, sample);
  database.prepare(`INSERT INTO speaker_clusters
    (id,user_id,session_id,local_ordinal,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,1,?,'test-model',4,1)`).run(clusterId, userId, sessionId, sample);
  const insertChunk = database.prepare(`INSERT INTO audio_chunks
    (id,user_id,session_id,source_id,sequence,idempotency_key,sha256,byte_size,container,codec,channel_layout,
     device_started_at,monotonic_offset_ms,duration_ms,state,temporary_path)
    VALUES (?,?,?,?,?,?,'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'wav','pcm_s16le','mono',
     '2026-07-14T10:00:00.000Z',?,6000,'processing',?)`);
  insertChunk.run(firstChunk, userId, sessionId, sourceId, 0, firstChunk, 0, fixture);
  insertChunk.run(secondChunk, userId, sessionId, sourceId, 1, secondChunk, 6000, fixture);
  database.prepare(`INSERT INTO speaker_turns
    (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions,quality,overlapping_speech)
    VALUES (?,?,?,?,?,?,?,?,'test-model',4,1,0)`).run(crypto.randomUUID(), userId, firstChunk, clusterId, voiceprintId, 0, 6000, sample);
  database.prepare(`INSERT INTO speaker_turns
    (id,user_id,chunk_id,cluster_id,voiceprint_id,start_ms,end_ms,embedding,embedding_model,embedding_dimensions,quality,overlapping_speech)
    VALUES (?,?,?,?,?,?,?,?,'test-model',4,1,0)`).run(crypto.randomUUID(), userId, secondChunk, clusterId, voiceprintId, 8000, 14000, sample);

  assert.equal(previews.captureFromChunk({
    id: firstChunk, user_id: userId, temporary_path: fixture, channel_layout: 'mono',
  }), 1);
  const afterFirst = database.prepare('SELECT duration_ms FROM speaker_previews WHERE voiceprint_id=?').get(voiceprintId);
  assert.ok(afterFirst.duration_ms >= 5_000 && afterFirst.duration_ms < 10_000, `first clip should be incomplete, got ${afterFirst.duration_ms}ms`);

  assert.equal(previews.captureFromChunk({
    id: secondChunk, user_id: userId, temporary_path: fixture, channel_layout: 'mono',
  }), 1);
  const afterSecond = database.prepare('SELECT duration_ms FROM speaker_previews WHERE voiceprint_id=?').get(voiceprintId);
  assert.equal(afterSecond.duration_ms, 10_000, 'equal-quality short clips accumulate up to the maximum instead of replacing each other');
  const playable = previews.get(userId, voiceprintId);
  assert.equal(playable.audio.toString('ascii', 0, 4), 'RIFF');
  assert.ok(previews.wavDurationMs(playable.audio) >= 9_500);
});

test('stored previews remain account-scoped', () => {
  const database = getDatabase();
  migrate(database);
  const firstUser = crypto.randomUUID();
  const secondUser = crypto.randomUUID();
  const voiceprint = crypto.randomUUID();
  database.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(firstUser, `preview-${firstUser}`);
  database.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(secondUser, `preview-${secondUser}`);
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,'test-model',1,1)`).run(voiceprint, firstUser, Buffer.alloc(4));
  database.prepare(`INSERT INTO speaker_previews
    (voiceprint_id,user_id,audio,duration_ms,quality) VALUES (?,?,?,5000,1)`)
    .run(voiceprint, firstUser, Buffer.from('preview'));

  assert.equal(previews.get(firstUser, voiceprint).audio.toString(), 'preview');
  assert.equal(previews.get(secondUser, voiceprint), undefined);
});
