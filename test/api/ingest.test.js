'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const request = require('supertest');

process.env.NEORECALL_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'neorecall-ingest-'));
const { createApp } = require('../../server/app');
const { getDatabase, closeDatabase } = require('../../server/db/database');
const transcribe = require('../../server/workers/handlers/transcribe_handler');
const app = createApp();
test.after(() => { closeDatabase(); fs.rmSync(process.env.NEORECALL_HOME, { recursive: true, force: true }); });

function wav(seconds = 16) {
  const frames = 16000 * seconds; const output = Buffer.alloc(44 + frames * 2);
  output.write('RIFF', 0); output.writeUInt32LE(output.length - 8, 4); output.write('WAVEfmt ', 8); output.writeUInt32LE(16, 16);
  output.writeUInt16LE(1, 20); output.writeUInt16LE(1, 22); output.writeUInt32LE(16000, 24); output.writeUInt32LE(32000, 28); output.writeUInt16LE(2, 32); output.writeUInt16LE(16, 34); output.write('data', 36); output.writeUInt32LE(frames * 2, 40);
  return output;
}

test('idempotent upload becomes terminal only after transcript commit and audio unlink', async () => {
  const registered = await request(app).post('/api/v1/auth/register').send({ username: 'ingest-user', password: 'a long and unique password' }).expect(201);
  const token = registered.body.session.token; const auth = { Authorization: `Bearer ${token}` };
  const deviceId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const sourceId = crypto.randomUUID();
  await request(app).post('/api/v1/devices').set(auth).send({ id: deviceId, clientUuid: deviceId, name: 'Test', platform: 'test', kind: 'desktop' }).expect(201);
  await request(app).post('/api/v1/ingest/sessions').set(auth).send({ id: sessionId, deviceId, clientUuid: sessionId, startedAt: '2026-07-13T10:00:00.000Z', timezone: 'UTC', consentAttestedAt: '2026-07-13T09:59:59.000Z', sources: [{ id: sourceId, clientUuid: sourceId, kind: 'microphone', channelLayout: 'mono', sampleRate: 16000, sampleFormat: 'pcm_s16le' }] }).expect(201);
  const audio = wav(); const digest = crypto.createHash('sha256').update(audio).digest('hex'); const idempotencyKey = crypto.randomUUID();
  const upload = () => request(app).put(`/api/v1/ingest/sessions/${sessionId}/sources/${sourceId}/chunks/0`).set(auth)
    .set('Idempotency-Key', idempotencyKey).set('X-Chunk-Sha256', digest).set('X-Chunk-Duration-Ms', '16000').set('X-Chunk-Overlap-Ms', '0')
    .set('X-Channel-Layout', 'mono').set('X-Monotonic-Offset-Ms', '0').set('X-Device-Started-At', '2026-07-13T10:00:00.000Z').set('X-Audio-Container', 'wav')
    .set('X-Audio-Content-Encoding', 'gzip').attach('audio', zlib.gzipSync(audio), 'chunk.wav.gz');
  const first = await upload().expect(202); const chunkId = first.body.receipt.chunkId;
  const duplicate = await upload().expect(200); assert.equal(duplicate.body.receipt.chunkId, chunkId);
  const chunk = getDatabase().prepare('SELECT * FROM audio_chunks WHERE id=?').get(chunkId); assert.ok(fs.existsSync(chunk.temporary_path));
  const count = transcribe.persistSegments(chunk, [{ text: 'Wir discuss the project tomorrow.', language: 'de', startMs: 500, endMs: 2500, sourceComponent: 'combined', asrConfidence: 0.9, speakerEmbedding: null, overlappingSpeech: false }]);
  const receipt = transcribe.finishCleanup(chunk, count);
  assert.equal(receipt.state, 'transcribed'); assert.ok(receipt.persistedAt); assert.ok(receipt.serverAudioDeletedAt); assert.equal(fs.existsSync(chunk.temporary_path), false);
  const status = await request(app).post('/api/v1/ingest/chunks/status').set(auth).send({ chunkIds: [chunkId] }).expect(200);
  assert.equal(status.body.receipts[0].transcriptSegmentCount, 1);
  await request(app).post('/api/v1/ingest/chunks/released').set(auth).send({ chunkIds: [chunkId] }).expect(200);
  assert.ok(getDatabase().prepare('SELECT client_released_at FROM audio_chunks WHERE id=?').get(chunkId).client_released_at);

  const db = getDatabase();
  const userId = registered.body.user.id;
  const segment = db.prepare('SELECT * FROM transcript_segments WHERE chunk_id=?').get(chunkId);
  const conversationId = crypto.randomUUID();
  const runId = crypto.randomUUID();
  db.transaction(() => {
    db.prepare(`INSERT INTO conversations (id,user_id,started_at,ended_at,state,boundary_method,boundary_version)
      VALUES (?,?,?,?,?,'test','1')`).run(conversationId, userId, segment.started_at, segment.ended_at, 'consolidated');
    db.prepare('UPDATE transcript_segments SET conversation_id=? WHERE id=?').run(conversationId, segment.id);
    db.prepare(`INSERT INTO consolidation_runs (id,user_id,state,reserved_at,started_at,completed_at)
      VALUES (?,?,'succeeded',?,?,?)`).run(runId, userId, segment.started_at, segment.started_at, segment.ended_at);
    const memory = db.prepare(`INSERT INTO memories
      (public_id,user_id,type,title_en,summary_en,importance,started_at,ended_at,consolidation_run_id)
      VALUES (?,?,'conversation','Project discussion','A project was discussed.',5,?,?,?)`)
      .run(crypto.randomUUID(), userId, segment.started_at, segment.ended_at, runId);
    const memoryId = Number(memory.lastInsertRowid);
    db.prepare('INSERT INTO memory_sources (memory_id,conversation_id,segment_id) VALUES (?,?,?)').run(memoryId, conversationId, segment.id);
    const mini = db.prepare(`INSERT INTO mini_memories
      (public_id,user_id,memory_id,kind,text_en,importance,confidence)
      VALUES (?,?,?,'fact','A project exists.',4,0.9)`).run(crypto.randomUUID(), userId, memoryId);
    const miniId = Number(mini.lastInsertRowid);
    db.prepare('INSERT INTO mini_memory_sources (mini_memory_id,segment_id) VALUES (?,?)').run(miniId, segment.id);
    const summaryId = crypto.randomUUID();
    db.prepare(`INSERT INTO daily_summaries
      (id,user_id,local_date,timezone,summary_en,coverage_started_at,coverage_ended_at,state,source_count,consolidation_run_id)
      VALUES (?,?,'2026-07-13','UTC','A project was discussed.',?,?,'provisional',1,?)`)
      .run(summaryId, userId, segment.started_at, segment.ended_at, runId);
    const insertSearch = db.prepare(`INSERT INTO search_documents
      (user_id,kind,source_id,title,body,occurred_at,importance,text_hash) VALUES (?,?,?,?,?,?,?,?)`);
    insertSearch.run(userId, 'memory', String(memoryId), 'Project discussion', 'A project was discussed.', segment.started_at, 5, crypto.randomUUID());
    insertSearch.run(userId, 'mini_memory', String(miniId), null, 'A project exists.', segment.started_at, 4, crypto.randomUUID());
    insertSearch.run(userId, 'daily_summary', summaryId, '2026-07-13', 'A project was discussed.', segment.started_at, 5, crypto.randomUUID());
  })();
  const contextId = crypto.randomUUID();
  const contextPath = path.join(process.env.NEORECALL_HOME, `${contextId}.txt`);
  const contextBytes = Buffer.from('Attached recording context');
  fs.writeFileSync(contextPath, contextBytes);
  db.prepare(`INSERT INTO recording_context_items
    (id,user_id,session_id,kind,captured_offset_ms,captured_at,original_name,content_type,byte_size,sha256,original_path,analysis_state)
    VALUES (?,?,?,'document',0,?,'context.txt','text/plain',?,?,?,'pending')`)
    .run(contextId, userId, sessionId, segment.started_at, contextBytes.length,
      crypto.createHash('sha256').update(contextBytes).digest('hex'), contextPath);
  await request(app).delete(`/api/v1/recordings/${sessionId}`).set(auth).expect(204);
  assert.equal(fs.existsSync(contextPath), false);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM recording_context_items WHERE id=?').get(contextId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM recording_sessions WHERE id=?').get(sessionId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM memories WHERE user_id=?').get(userId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM mini_memories WHERE user_id=?').get(userId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) count FROM daily_summaries WHERE user_id=?').get(userId).count, 0);
  assert.equal(db.prepare("SELECT COUNT(*) count FROM search_documents WHERE user_id=? AND kind IN ('segment','memory','mini_memory','daily_summary')").get(userId).count, 0);
});
