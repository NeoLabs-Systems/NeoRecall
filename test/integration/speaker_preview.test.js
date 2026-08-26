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
