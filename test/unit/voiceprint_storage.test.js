'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-voiceprint-'));

const { migrate } = require('../../server/db/migrate');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const storage = require('../../server/transcription/voiceprint_storage');
const vectors = require('../../server/transcription/speaker_embeddings');

migrate();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

const vector = (values) => Float32Array.from(values);

test('a sealed centroid round-trips and is unreadable at rest', () => {
  const original = vector([0.5, -0.25, 0.125, 1]);
  const sealed = storage.sealCentroid(original);
  const raw = Buffer.from(original.buffer);
  assert.ok(!sealed.equals(raw), 'the stored bytes differ from the vector');
  assert.ok(sealed.indexOf(raw) === -1, 'the plaintext vector does not appear inside the sealed blob');
  assert.deepEqual(Array.from(storage.readCentroid(sealed)), Array.from(original));
});

test('sealed centroids remain comparable, so matching still works', () => {
  const target = vector([1, 0, 0, 0]);
  const near = storage.sealCentroid(vector([0.98, 0.02, 0, 0]));
  const far = storage.sealCentroid(vector([0, 1, 0, 0]));
  const ranked = storage.rankVoiceprints(target, [
    { id: 'far', centroid_embedding: far },
    { id: 'near', centroid_embedding: near },
  ]);
  assert.equal(ranked[0].row.id, 'near');
  assert.ok(ranked[0].score > 0.99 && ranked[1].score < 0.1);
});

test('unsealed legacy rows still read, so a pre-migration backup restores', () => {
  const legacy = vector([0.25, 0.5, 0.75, 1]);
  const asStored = Buffer.from(legacy.buffer);
  assert.deepEqual(Array.from(storage.readCentroid(asStored)), Array.from(legacy));
});

test('reads survive an unaligned decryption buffer', () => {
  // Float32Array construction throws on a byte offset that is not a multiple of
  // four. Force the case rather than trusting the allocator to avoid it.
  const original = vector([1.5, 2.5, 3.5, 4.5]);
  const padded = Buffer.alloc(Buffer.byteLength('x') + original.byteLength);
  Buffer.from(original.buffer).copy(padded, 1);
  const unaligned = padded.subarray(1);
  assert.equal(unaligned.byteOffset % 4, 1, 'the fixture really is unaligned');
  assert.deepEqual(Array.from(storage.readCentroid(unaligned)), Array.from(original));
});

test('preview clips are sealed on the way in and playable on the way out', () => {
  const clip = crypto.randomBytes(4096);
  const sealed = storage.sealPreviewAudio(clip);
  assert.ok(sealed.indexOf(clip) === -1, 'the clip does not appear in the sealed blob');
  assert.ok(storage.readPreviewAudio(sealed).equals(clip));
});

test('migration 025 seals rows written before it and is safe to re-run', () => {
  const db = getDatabase();
  db.prepare("INSERT INTO users (id,username,password_hash) VALUES ('u1','v','x')").run();
  const id = crypto.randomUUID();
  const plaintext = Buffer.from(vector([9, 8, 7, 6]).buffer);
  // Write the way the code did before the seal boundary existed.
  db.prepare(`INSERT INTO voiceprints (id,user_id,display_name,centroid_embedding,embedding_model,embedding_dimensions,sample_count)
    VALUES (?,?,?,?,?,?,?)`).run(id, 'u1', 'Legacy Speaker', plaintext, 'test', 4, 1);
  db.prepare(`INSERT INTO speaker_previews (voiceprint_id,user_id,audio,duration_ms,quality)
    VALUES (?,?,?,?,?)`).run(id, 'u1', Buffer.from('RIFFplaintextaudio'), 2000, 0.9);

  const migration = require('../../server/db/migrations/025_seal_voice_biometrics');
  migration.up(db);
  const afterFirst = db.prepare('SELECT centroid_embedding, (SELECT audio FROM speaker_previews WHERE voiceprint_id=?) audio FROM voiceprints WHERE id=?').get(id, id);
  assert.ok(!afterFirst.centroid_embedding.equals(plaintext), 'the centroid is no longer plaintext');
  assert.equal(afterFirst.audio.indexOf(Buffer.from('RIFFplaintextaudio')), -1, 'the clip is no longer plaintext');
  assert.deepEqual(Array.from(storage.readCentroid(afterFirst.centroid_embedding)), [9, 8, 7, 6]);

  migration.up(db);
  const afterSecond = db.prepare('SELECT centroid_embedding FROM voiceprints WHERE id=?').get(id);
  assert.deepEqual(Array.from(storage.readCentroid(afterSecond.centroid_embedding)), [9, 8, 7, 6], 're-running does not double-seal');
});

test('session clusters are deliberately left unsealed for sqlite-vec and hot-path reads', () => {
  // A guard against someone later "finishing the job" by sealing these too:
  // cluster vectors are anonymous and per-session, and the matching path reads
  // them directly through vectors.fromBuffer.
  const clusterVector = vector([1, 2, 3, 4]);
  const stored = Buffer.from(clusterVector.buffer);
  assert.deepEqual(Array.from(vectors.fromBuffer(stored)), Array.from(clusterVector));
});
