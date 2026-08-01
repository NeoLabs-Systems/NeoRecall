'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-import-'));
process.env.NEORECALL_IMPORT_PART_BYTES = '65536';
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const handler = require('../../server/workers/handlers/import_handler');
const imports = require('../../server/services/ingest/import_service');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

test('import source remains until every derived chunk has a terminal deletion receipt', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'import-user', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id; const db = getDatabase(); const id = crypto.randomUUID();
  const original = path.join(process.env.NEORECALL_HOME, 'import_tmp', `${id}.source`);
  fs.copyFileSync(path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav'), original);
  const bytes = fs.readFileSync(original); const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  db.prepare(`INSERT INTO imports (id,user_id,original_name,content_type,total_size,sha256,part_size,capture_time,timezone,state,temporary_path)
    VALUES (?,?,?,'audio/wav',?,?,8388608,'2026-07-13T10:00:00.000Z','UTC','assembled',?)`)
    .run(id, userId, 'fixture.wav', bytes.length, digest, original);
  await handler.handle({ resource_id: id, user_id: userId });
  let record = db.prepare('SELECT * FROM imports WHERE id=?').get(id);
  assert.equal(record.state, 'processing');
  assert.equal(record.temporary_path, original);
  assert.equal(fs.existsSync(original), true);
  const chunks = db.prepare('SELECT * FROM audio_chunks WHERE user_id=?').all(userId);
  assert.ok(chunks.length > 0);
  for (const chunk of chunks) {
    fs.unlinkSync(chunk.temporary_path);
    db.prepare(`UPDATE audio_chunks SET state='silent',temporary_path=NULL,transcript_sha256=?,transcript_segment_count=0,
      persisted_at=?,server_deleted_at=? WHERE id=?`).run(crypto.createHash('sha256').update('[]').digest('hex'), new Date().toISOString(), new Date().toISOString(), chunk.id);
  }
  assert.equal(imports.reconcileProcessing(), 1);
  record = db.prepare('SELECT * FROM imports WHERE id=?').get(id);
  assert.equal(record.state, 'completed');
  assert.equal(record.temporary_path, null);
  assert.equal(fs.existsSync(original), false);
});

test('the advertised maximum import part is uploadable and larger declarations are rejected', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'part-limit-user', password: 'another long unique password' }).expect(201);
  const auth = { Authorization: `Bearer ${registration.body.session.token}` };
  const meta = await request(app).get('/api/v1/meta').set(auth).expect(200);
  assert.equal(meta.body.limits.importPartBytes, 65536);
  const bytes = Buffer.alloc(65536, 7);
  const digest = crypto.createHash('sha256').update(bytes).digest('hex');
  const id = crypto.randomUUID();
  await request(app).post('/api/v1/imports').set(auth).send({ id, originalName: 'limit.raw', contentType: 'application/octet-stream',
    totalSize: bytes.length, sha256: digest, partSize: bytes.length, timezone: 'UTC' }).expect(201);
  await request(app).put(`/api/v1/imports/${id}/parts/0`).set(auth).set('Content-Range', `bytes 0-${bytes.length - 1}/${bytes.length}`)
    .set('X-Part-Sha256', digest).attach('part', bytes, { filename: 'limit.part', contentType: 'application/octet-stream' }).expect(200);
  await request(app).post('/api/v1/imports').set(auth).send({ originalName: 'too-large.raw', contentType: 'application/octet-stream',
    totalSize: 65537, sha256: digest, partSize: 65537, timezone: 'UTC' }).expect(400).expect((response) => {
    assert.equal(response.body.error.code, 'IMPORT_PART_TOO_LARGE');
  });
});

/// Registers an assembled import as if its bytes had already been uploaded.
async function stageImport(userId, { deviceId = null, captureTime = null, suffix }) {
  const db = getDatabase();
  const id = crypto.randomUUID();
  const original = path.join(process.env.NEORECALL_HOME, 'import_tmp', `${id}.source`);
  fs.copyFileSync(path.join(__dirname, '..', 'fixtures', 'de_en_two_speakers.wav'), original);
  const bytes = fs.readFileSync(original);
  db.prepare(`INSERT INTO imports (id,user_id,device_id,original_name,content_type,total_size,sha256,part_size,capture_time,timezone,state,temporary_path)
    VALUES (?,?,?,?,'audio/wav',?,?,8388608,?,'UTC','assembled',?)`)
    .run(id, userId, deviceId, `sweep-${suffix}.wav`, bytes.length,
      crypto.createHash('sha256').update(bytes).digest('hex'), captureTime, original);
  return handler.handle({ resource_id: id, user_id: userId });
}

test('consecutive drains of one device stay a single recording stream', async () => {
  // A wearable with on-board storage is drained every few seconds, and each
  // sweep arrives as its own file. Given a session each, every sweep would
  // become its own conversation stream that nothing may merge across, and one
  // meeting would end up as one memory per sweep.
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'drain-user', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Pendant','test','wearable')").run(deviceId, userId, deviceId);

  const first = await stageImport(userId, { deviceId, suffix: '1' });
  const second = await stageImport(userId, { deviceId, suffix: '2' });
  assert.equal(second.sessionId, first.sessionId, 'A follow-up drain started a new recording stream.');
  assert.notEqual(second.sourceId, first.sourceId, 'Each drained file must keep its own sequence numbering.');

  const session = db.prepare('SELECT * FROM recording_sessions WHERE id=?').get(first.sessionId);
  const firstChunks = db.prepare('SELECT monotonic_offset_ms,duration_ms FROM audio_chunks WHERE source_id=? ORDER BY sequence').all(first.sourceId);
  const secondChunks = db.prepare('SELECT monotonic_offset_ms,duration_ms FROM audio_chunks WHERE source_id=? ORDER BY sequence').all(second.sourceId);
  assert.equal(firstChunks[0].monotonic_offset_ms, 0);
  // The follow-up continues on the same timeline instead of restarting at zero,
  // which is what keeps its transcript adjacent to the earlier one.
  const firstEnd = firstChunks.at(-1).monotonic_offset_ms + firstChunks.at(-1).duration_ms;
  assert.equal(secondChunks[0].monotonic_offset_ms, firstEnd);
  assert.equal(
    Date.parse(session.corrected_ended_at),
    Date.parse(session.corrected_started_at) + secondChunks.at(-1).monotonic_offset_ms + secondChunks.at(-1).duration_ms,
  );

  // Each import still completes on its own audio, not on the whole stream.
  for (const chunk of db.prepare('SELECT * FROM audio_chunks WHERE source_id=?').all(first.sourceId)) {
    fs.unlinkSync(chunk.temporary_path);
    db.prepare(`UPDATE audio_chunks SET state='silent',temporary_path=NULL,transcript_sha256=?,transcript_segment_count=0,
      persisted_at=?,server_deleted_at=? WHERE id=?`).run(crypto.createHash('sha256').update('[]').digest('hex'), new Date().toISOString(), new Date().toISOString(), chunk.id);
  }
  assert.equal(imports.reconcileProcessing(), 1, 'The finished drain did not complete while a later one was still processing.');
});

test('a drain separated by a long gap starts its own recording stream', async () => {
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'gap-user', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const db = getDatabase();
  const deviceId = crypto.randomUUID();
  db.prepare("INSERT INTO devices(id,user_id,client_uuid,name,platform,kind) VALUES (?,?,?,'Pendant','test','wearable')").run(deviceId, userId, deviceId);

  const morning = await stageImport(userId, { deviceId, captureTime: '2026-07-13T08:00:00.000Z', suffix: 'am' });
  const evening = await stageImport(userId, { deviceId, captureTime: '2026-07-13T20:00:00.000Z', suffix: 'pm' });
  assert.notEqual(evening.sessionId, morning.sessionId, 'Recordings twelve hours apart were fused into one stream.');
});

test('hand-uploaded files never splice onto a device sweep', async () => {
  // Imports that name no device all share one synthetic device. Continuing a
  // stream there would attach a file the user just uploaded to whatever a
  // wearable happened to sync moments earlier.
  const registration = await request(app).post('/api/v1/auth/register').send({ username: 'upload-user', password: 'a long and unique password' }).expect(201);
  const userId = registration.body.user.id;
  const first = await stageImport(userId, { suffix: 'a' });
  const second = await stageImport(userId, { suffix: 'b' });
  assert.notEqual(second.sessionId, first.sessionId);
});
