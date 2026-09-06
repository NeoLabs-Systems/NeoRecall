'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-context-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const contextService = require('../../server/services/context/context_service');
const app = createApp();

test.after(() => {
  closeDatabase();
  fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true });
});

async function accountWithRecording() {
  const suffix = crypto.randomUUID();
  const registered = await request(app).post('/api/v1/auth/register').send({
    username: `context-${suffix}`,
    password: `a long unique password ${suffix}`,
  }).expect(201);
  const auth = { Authorization: `Bearer ${registered.body.session.token}` };
  const deviceId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const sourceId = crypto.randomUUID();
  await request(app).post('/api/v1/devices').set(auth).send({
    id: deviceId,
    clientUuid: deviceId,
    name: 'Context test device',
    platform: 'test',
    kind: 'desktop',
  }).expect(201);
  await request(app).post('/api/v1/ingest/sessions').set(auth).send({
    id: sessionId,
    deviceId,
    clientUuid: sessionId,
    startedAt: '2026-08-26T08:00:00.000Z',
    timezone: 'Europe/Berlin',
    consentAttestedAt: '2026-08-26T07:59:59.000Z',
    sources: [{
      id: sourceId,
      clientUuid: sourceId,
      kind: 'microphone',
      channelLayout: 'mono',
      sampleRate: 16000,
      sampleFormat: 'pcm_s16le',
    }],
  }).expect(201);
  return { registered, auth, deviceId, sessionId, sourceId };
}

test('recording context is idempotent, durable, and accepted after an offline close', async () => {
  const { auth, sessionId, sourceId } = await accountWithRecording();
  const highlightId = crypto.randomUUID();
  const highlight = () => request(app)
    .put(`/api/v1/ingest/sessions/${sessionId}/context/${highlightId}`)
    .set(auth)
    .field('kind', 'highlight')
    .field('capturedOffsetMs', '2500');

  const first = await highlight().expect(201);
  assert.equal(first.body.item.kind, 'highlight');
  assert.equal(first.body.item.capturedOffsetMs, 2500);
  await highlight().expect(201);
  assert.equal(
    getDatabase().prepare('SELECT COUNT(*) count FROM recording_context_items WHERE id=?').get(highlightId).count,
    1,
  );

  await request(app).patch(`/api/v1/ingest/sessions/${sessionId}`).set(auth).send({
    endedAt: '2026-08-26T08:00:10.000Z',
    status: 'ended',
    sources: [{ id: sourceId, finalSequence: -1 }],
  }).expect(200);

  const noteId = crypto.randomUUID();
  await request(app).put(`/api/v1/ingest/sessions/${sessionId}/context/${noteId}`).set(auth)
    .field('kind', 'note')
    .field('capturedOffsetMs', '5000')
    .field('noteText', 'The launch date shown on the slide is September 8.')
    .expect(201);

  const listed = await request(app).get(`/api/v1/ingest/sessions/${sessionId}/context`).set(auth).expect(200);
  assert.deepEqual(listed.body.items.map((item) => item.id), [highlightId, noteId]);
  assert.equal(listed.body.items[1].analysisState, 'ready');

  await request(app).put(`/api/v1/ingest/sessions/${sessionId}/context/${crypto.randomUUID()}`).set(auth)
    .field('kind', 'note')
    .field('capturedOffsetMs', '11000')
    .field('noteText', 'Outside the recording')
    .expect(409);
});

test('uploaded originals expire retroactively without removing extracted context', async () => {
  const { registered, auth, sessionId } = await accountWithRecording();
  const itemId = crypto.randomUUID();
  const upload = await request(app).put(`/api/v1/ingest/sessions/${sessionId}/context/${itemId}`).set(auth)
    .field('kind', 'document')
    .field('capturedOffsetMs', '1000')
    .field('contentType', 'text/plain')
    .attach('file', Buffer.from('Roadmap\nLaunch: September 8\n'), {
      filename: 'roadmap.txt',
      contentType: 'application/octet-stream',
    })
    .expect(201);
  assert.equal(upload.body.item.kind, 'document');
  assert.equal(upload.body.item.originalAvailable, true);
  assert.equal(upload.body.item.analysisState, 'pending');
  assert.equal(
    getDatabase().prepare("SELECT COUNT(*) count FROM jobs WHERE type='analyze_context' AND resource_id=?").get(itemId).count,
    1,
  );

  const original = await request(app).get(`/api/v1/ingest/sessions/${sessionId}/context/${itemId}/original`).set(auth).expect(200);
  assert.match(original.text, /September 8/);

  await request(app).put('/api/v1/settings').set(auth).send({ contextOriginalRetentionDays: 1 }).expect(200);
  const db = getDatabase();
  db.prepare(`UPDATE recording_context_items SET created_at=?,extracted_text=?,analysis_text=?,analysis_state='ready' WHERE id=?`)
    .run('2026-08-20T08:00:00.000Z', 'Launch: September 8', 'The roadmap states a September 8 launch.', itemId);
  assert.equal(contextService.cleanupExpiredOriginals(new Date('2026-08-26T08:00:00.000Z')), 1);
  await request(app).get(`/api/v1/ingest/sessions/${sessionId}/context/${itemId}/original`).set(auth).expect(410);
  const retained = db.prepare('SELECT * FROM recording_context_items WHERE id=? AND user_id=?').get(itemId, registered.body.user.id);
  assert.equal(retained.original_path, null);
  assert.equal(retained.extracted_text, 'Launch: September 8');
  assert.equal(retained.analysis_text, 'The roadmap states a September 8 launch.');
});
