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

function makeVoiceprint(database, userId, { displayName = null, sampleCount = 1 } = {}) {
  const id = crypto.randomUUID();
  database.prepare(`INSERT INTO voiceprints
    (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,'test-model',1,?)`).run(id, userId, displayName, Buffer.alloc(4), sampleCount);
  return id;
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
