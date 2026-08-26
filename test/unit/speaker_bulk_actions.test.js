'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-speaker-bulk-'));
const { getDatabase, closeDatabase } = require('../../server/db/database');
const { migrate } = require('../../server/db/migrate');
const service = require('../../server/services/speakers/speaker_service');

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

function makeUser(database) {
  const userId = crypto.randomUUID();
  database.prepare("INSERT INTO users (id,username,password_hash) VALUES (?,?,'test')").run(userId, `bulk-${userId}`);
  return userId;
}

function vectorBuffer(values) {
  return Buffer.from(new Float32Array(values).buffer);
}

function makeVoiceprint(database, userId, {
  displayName = null,
  sampleCount = 1,
  id = crypto.randomUUID(),
  embedding = [1, 0],
  matchingEnabled = true,
} = {}) {
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count,matching_enabled)
    VALUES (?,?,?,?,'test-model',?,?,?)`).run(
    id, userId, displayName, vectorBuffer(embedding), embedding.length, sampleCount, Number(matchingEnabled),
  );
  return id;
}

function addPreview(database, userId, voiceprintId, durationMs, quality = 1) {
  database.prepare(`INSERT INTO speaker_previews
    (voiceprint_id,user_id,audio,duration_ms,quality) VALUES (?,?,?,?,?)`)
    .run(voiceprintId, userId, Buffer.from('preview'), durationMs, quality);
}

test('mergeMany folds several source speakers into one target in turn', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const target = makeVoiceprint(database, userId, { displayName: 'Alex' });
  const sourceA = makeVoiceprint(database, userId);
  const sourceB = makeVoiceprint(database, userId);

  const result = service.mergeMany(userId, target, [sourceA, sourceB, target]);

  assert.equal(result.id, target);
  assert.equal(result.sample_count, 3);
  assert.equal(database.prepare('SELECT COUNT(*) c FROM voiceprints WHERE user_id=?').get(userId).c, 1);
});

test('mergeMany rejects a merge with no other speakers selected', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const target = makeVoiceprint(database, userId);
  assert.throws(() => service.mergeMany(userId, target, [target]), /Select at least one/);
});

test('bulkRemove deletes every requested speaker in one transaction and is account-scoped', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const otherUserId = makeUser(database);
  const first = makeVoiceprint(database, userId);
  const second = makeVoiceprint(database, userId);
  const othersSpeaker = makeVoiceprint(database, otherUserId);

  const result = service.bulkRemove(userId, [first, second]);
  assert.equal(result.count, 2);
  assert.equal(database.prepare('SELECT COUNT(*) c FROM voiceprints WHERE id IN (?,?)').get(first, second).c, 0);
  assert.equal(database.prepare('SELECT COUNT(*) c FROM voiceprints WHERE id=?').get(othersSpeaker).c, 1);
});

test('bulkRemove refuses to delete a speaker owned by another user', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const otherUserId = makeUser(database);
  const mine = makeVoiceprint(database, userId);
  const theirs = makeVoiceprint(database, otherUserId);

  assert.throws(() => service.bulkRemove(userId, [mine, theirs]), /not found/i);
  assert.equal(database.prepare('SELECT COUNT(*) c FROM voiceprints WHERE id=?').get(mine).c, 1);
});

test('list only returns speakers with a full clean preview', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const short = makeVoiceprint(database, userId);
  const full = makeVoiceprint(database, userId);
  const missing = makeVoiceprint(database, userId);
  addPreview(database, userId, short, 9_999);
  addPreview(database, userId, full, 10_000);

  assert.deepEqual(service.list(userId).map((speaker) => speaker.id), [full]);
  assert.equal(database.prepare('SELECT COUNT(*) count FROM voiceprints WHERE id=?').get(missing).count, 1);
});

test('reevaluate merges mutually confident matching profiles and preserves a named target', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  const named = makeVoiceprint(database, userId, {
    displayName: 'Alex', sampleCount: 2, embedding: [1, 0],
  });
  const duplicate = makeVoiceprint(database, userId, {
    sampleCount: 1, embedding: [0.99, 0.01],
  });
  addPreview(database, userId, named, 10_000, 0.5);
  addPreview(database, userId, duplicate, 5_000, 1);
  makeVoiceprint(database, userId, { embedding: [0, 1] });

  const result = service.reevaluate(userId);

  assert.equal(result.mergedCount, 1);
  assert.equal(result.merges[0].targetId, named);
  assert.equal(result.merges[0].sourceId, duplicate);
  assert.equal(database.prepare('SELECT sample_count FROM voiceprints WHERE id=?').get(named).sample_count, 3);
  assert.equal(database.prepare('SELECT duration_ms FROM speaker_previews WHERE voiceprint_id=?').get(named).duration_ms, 10_000);
});

test('reevaluate does not merge explicitly distinct or disabled profiles', () => {
  const database = getDatabase();
  migrate(database);
  const userId = makeUser(database);
  makeVoiceprint(database, userId, { displayName: 'Alex', embedding: [1, 0] });
  makeVoiceprint(database, userId, { displayName: 'Morgan', embedding: [0.99, 0.01] });
  makeVoiceprint(database, userId, { embedding: [1, 0], matchingEnabled: false });

  const result = service.reevaluate(userId);

  assert.equal(result.mergedCount, 0);
  assert.equal(result.remainingCount, 3);
});
